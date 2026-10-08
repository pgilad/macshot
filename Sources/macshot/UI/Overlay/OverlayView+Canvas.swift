import Cocoa

/// Editor image transforms, zoom, the canvas coordinate transforms and output rendering.
extension OverlayView {

    // MARK: - Editor Image Transforms

    func flipImageHorizontally() {
        guard let original = screenshotImage,
            let cgImage = original.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return }

        // Save state for undo
        guard let prevImage = original.copy() as? NSImage else { return }
        undoStack.append(.imageTransform(previousImage: prevImage, previousSnappedWindowImage: nil, annotationOffsets: []))
        redoStack.removeAll()

        let w = cgImage.width
        let h = cgImage.height
        // Preserve the source image's color space so colors stay correct.
        let cs = cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard
            let ctx = CGContext(
                data: nil, width: w, height: h,
                bitsPerComponent: 8,
                bytesPerRow: 0, space: cs,
                bitmapInfo: bitmapInfo)
        else { return }
        ctx.translateBy(x: CGFloat(w), y: 0)
        ctx.scaleBy(x: -1, y: 1)
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let flipped = ctx.makeImage() else { return }

        screenshotImage = NSImage(cgImage: flipped, size: original.size)

        // Mirror annotation X coordinates around the image center
        for ann in annotations {
            ann.startPoint.x = selectionRect.minX + (selectionRect.maxX - ann.startPoint.x)
            ann.endPoint.x = selectionRect.minX + (selectionRect.maxX - ann.endPoint.x)
            if let cp = ann.controlPoint {
                ann.controlPoint = NSPoint(
                    x: selectionRect.minX + (selectionRect.maxX - cp.x), y: cp.y)
            }
            // Mirror freeform points
            if let pts = ann.points {
                ann.points = pts.map {
                    NSPoint(x: selectionRect.minX + (selectionRect.maxX - $0.x), y: $0.y)
                }
            }
        }

        cachedCompositedImage = nil
        needsDisplay = true
    }

    func flipImageVertically() {
        guard let original = screenshotImage,
            let cgImage = original.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return }

        guard let prevImage = original.copy() as? NSImage else { return }
        undoStack.append(.imageTransform(previousImage: prevImage, previousSnappedWindowImage: nil, annotationOffsets: []))
        redoStack.removeAll()

        let w = cgImage.width
        let h = cgImage.height
        let cs = cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard
            let ctx = CGContext(
                data: nil, width: w, height: h,
                bitsPerComponent: 8,
                bytesPerRow: 0, space: cs,
                bitmapInfo: bitmapInfo)
        else { return }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let flipped = ctx.makeImage() else { return }

        screenshotImage = NSImage(cgImage: flipped, size: original.size)

        // Mirror annotation Y coordinates around the image center
        for ann in annotations {
            ann.startPoint.y = selectionRect.minY + (selectionRect.maxY - ann.startPoint.y)
            ann.endPoint.y = selectionRect.minY + (selectionRect.maxY - ann.endPoint.y)
            if let cp = ann.controlPoint {
                ann.controlPoint = NSPoint(
                    x: cp.x, y: selectionRect.minY + (selectionRect.maxY - cp.y))
            }
            if let pts = ann.points {
                ann.points = pts.map {
                    NSPoint(x: $0.x, y: selectionRect.minY + (selectionRect.maxY - $0.y))
                }
            }
        }

        cachedCompositedImage = nil
        needsDisplay = true
    }

    /// Add a captured image as a draggable stamp annotation, placed below the current canvas.
    /// The canvas auto-expands to fit. Used by "Add Capture" in the editor.
    func addCaptureImage(_ newImage: NSImage) {
        let imgW = newImage.size.width
        let imgH = newImage.size.height

        // Place below the current canvas, left-aligned
        let placeY = -imgH  // just below origin (canvas will expand)

        let ann = Annotation(
            tool: .stamp,
            startPoint: NSPoint(x: 0, y: placeY),
            endPoint: NSPoint(x: imgW, y: placeY + imgH),
            color: NSColor.white.withAlphaComponent(0),
            strokeWidth: 0)
        ann.stampImage = newImage
        ann.isCaptureStamp = true

        annotations.append(ann)
        undoStack.append(.added(ann))
        redoStack.removeAll()

        // Auto-select so user can move/resize immediately
        currentTool = .select
        selectedAnnotation = ann
        cachedCompositedImage = nil

        // Expand the canvas to fit the new annotation
        expandCanvasToFitAnnotations()
        rebuildToolbarLayout()

        // Keep the editor top-bar size label in sync (the canvas may have grown).
        if let cg = screenshotImage?.cgImage(forProposedRect: nil, context: nil, hints: nil),
           let topBar = chromeParentView?.subviews.compactMap({ $0 as? EditorTopBarView }).first {
            topBar.updateSizeLabel(width: cg.width, height: cg.height)
        }

        needsDisplay = true
    }

    /// Resizes the canvas to tightly fit the original image content plus all annotations.
    /// Grows or shrinks as needed. Shifts everything so origin stays at (0,0).
    /// Only runs the expensive pixel scan when add-capture stamps are present.
    func expandCanvasToFitAnnotations() {
        guard isEditorMode, let original = screenshotImage,
              let oldCG = original.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return }

        // Only resize canvas when there are add-capture image stamps that might be outside bounds.
        // Normal annotations (arrows, text, etc.) don't need canvas resizing.
        let hasImageStamps = annotations.contains { $0.tool == .stamp && $0.stampImage != nil }
        guard hasImageStamps else { return }

        let scale = CGFloat(oldCG.width) / original.size.width

        // Detect the non-transparent bounding box of the original image.
        let opaqueRect: NSRect
        if let cached = cachedOpaqueRect {
            opaqueRect = cached
        } else {
            opaqueRect = opaqueContentRect(of: oldCG, scale: scale)
            cachedOpaqueRect = opaqueRect
        }

        // Compute bounding box of opaque image content + all annotations
        var minX: CGFloat = opaqueRect.minX
        var minY: CGFloat = opaqueRect.minY
        var maxX: CGFloat = opaqueRect.maxX
        var maxY: CGFloat = opaqueRect.maxY

        for ann in annotations {
            let r = ann.boundingRect
            guard r.width > 0, r.height > 0 else { continue }
            minX = min(minX, r.minX)
            minY = min(minY, r.minY)
            maxX = max(maxX, r.maxX)
            maxY = max(maxY, r.maxY)
        }

        let targetRect = NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)

        // If canvas already matches, nothing to do
        if abs(minX) < 1 && abs(minY) < 1
            && abs(maxX - selectionRect.width) < 1 && abs(maxY - selectionRect.height) < 1 {
            return
        }

        let newPtW = targetRect.width
        let newPtH = targetRect.height
        let newPxW = max(1, Int(newPtW * scale))
        let newPxH = max(1, Int(newPtH * scale))

        let cs = oldCG.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: nil, width: newPxW, height: newPxH,
            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }

        // Draw old image offset so that targetRect.origin maps to (0,0)
        let drawX = -targetRect.origin.x * scale
        let drawY = -targetRect.origin.y * scale
        ctx.draw(oldCG, in: CGRect(x: drawX, y: drawY, width: CGFloat(oldCG.width), height: CGFloat(oldCG.height)))

        guard let newCG = ctx.makeImage() else { return }
        guard let prevImage = original.copy() as? NSImage else { return }
        let shiftDx = -targetRect.origin.x
        let shiftDy = -targetRect.origin.y
        let offsets = annotations.map { ($0, shiftDx, shiftDy) }
        undoStack.append(.imageTransform(previousImage: prevImage, previousSnappedWindowImage: nil, annotationOffsets: offsets))

        screenshotImage = NSImage(cgImage: newCG, size: NSSize(width: newPtW, height: newPtH))
        cachedOpaqueRect = nil  // invalidate — image content changed

        // Shift all annotations so they align with the new origin
        if shiftDx != 0 || shiftDy != 0 {
            for ann in annotations {
                ann.move(dx: shiftDx, dy: shiftDy)
            }
        }

        selectionRect = NSRect(origin: .zero, size: NSSize(width: newPtW, height: newPtH))
        frame.size = NSSize(width: newPtW, height: newPtH)
        cachedCompositedImage = nil
    }

    /// Returns the bounding rect (in point coords) of non-transparent pixels in the image.
    /// Uses fast row/column scanning on the raw pixel data.
    private func opaqueContentRect(of cgImage: CGImage, scale: CGFloat) -> NSRect {
        let w = cgImage.width
        let h = cgImage.height
        guard w > 0, h > 0,
              let data = cgImage.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else {
            return NSRect(x: 0, y: 0, width: CGFloat(w) / scale, height: CGFloat(h) / scale)
        }

        let bytesPerRow = cgImage.bytesPerRow
        let bytesPerPixel = cgImage.bitsPerPixel / 8
        guard bytesPerPixel >= 4 else {
            return NSRect(x: 0, y: 0, width: CGFloat(w) / scale, height: CGFloat(h) / scale)
        }

        // Alpha channel offset depends on bitmap info
        let alphaInfo = CGImageAlphaInfo(rawValue: cgImage.bitmapInfo.rawValue & CGBitmapInfo.alphaInfoMask.rawValue)
        let alphaOffset: Int
        switch alphaInfo {
        case .premultipliedFirst, .first, .noneSkipFirst: alphaOffset = 0
        case .premultipliedLast, .last, .noneSkipLast: alphaOffset = 3
        default: alphaOffset = 3
        }

        var minRow = h, maxRow = 0, minCol = w, maxCol = 0

        // Bound the scan by the buffer's real length rather than by the
        // geometry: a provider whose data is shorter than bytesPerRow * h
        // would otherwise be read past the end.
        let byteCount = CFDataGetLength(data)
        // Nothing sensible to report from a truncated buffer; treat the whole
        // image as opaque rather than reading past the end.
        guard byteCount >= bytesPerRow * h else {
            return NSRect(x: 0, y: 0, width: CGFloat(w) / scale, height: CGFloat(h) / scale)
        }

        for row in 0..<h {
            let rowBase = row * bytesPerRow
            for col in 0..<w {
                let offset = rowBase + col * bytesPerPixel + alphaOffset
                guard offset < byteCount else { continue }
                let alpha = ptr[offset]
                if alpha > 0 {
                    if row < minRow { minRow = row }
                    if row > maxRow { maxRow = row }
                    if col < minCol { minCol = col }
                    if col > maxCol { maxCol = col }
                }
            }
        }

        if minRow > maxRow {
            // Fully transparent — return full rect
            return NSRect(x: 0, y: 0, width: CGFloat(w) / scale, height: CGFloat(h) / scale)
        }

        // CGImage rows are top-to-bottom, convert to AppKit bottom-left origin
        let ptMinX = CGFloat(minCol) / scale
        let ptMinY = CGFloat(h - 1 - maxRow) / scale
        let ptMaxX = CGFloat(maxCol + 1) / scale
        let ptMaxY = CGFloat(h - minRow) / scale
        return NSRect(x: ptMinX, y: ptMinY, width: ptMaxX - ptMinX, height: ptMaxY - ptMinY)
    }

    func invertImageColors() {
        guard let original = screenshotImage,
              let invertedScreenshot = Self.invertedCopy(of: original)
        else { return }

        // A selection snapped to a window draws — and exports — from
        // snappedWindowImage, a separately captured image. Inverting only the
        // screenshot left the capture itself in its original colours while
        // everything around it flipped (#88).
        let previousSnapped = snappedWindowImage
        let invertedSnapped = snappedWindowImage.flatMap { Self.invertedCopy(of: $0) }

        undoStack.append(.imageTransform(
            previousImage: original.copy() as? NSImage ?? original,
            previousSnappedWindowImage: previousSnapped,
            annotationOffsets: []))
        redoStack.removeAll()

        screenshotImage = invertedScreenshot
        if invertedSnapped != nil { snappedWindowImage = invertedSnapped }
        cachedCompositedImage = nil
        cachedEffectsScreenshot = nil
        needsDisplay = true
    }

    /// Colour-inverted copy of an image, or nil when it can't be read.
    static func invertedCopy(of image: NSImage) -> NSImage? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let filter = CIFilter(name: "CIColorInvert") else { return nil }
        filter.setValue(CIImage(cgImage: cgImage), forKey: kCIInputImageKey)
        guard let output = filter.outputImage,
              let inverted = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: inverted, size: image.size)
    }

    // MARK: - Zoom helpers

    /// Convert a canvas-space point to view-space (reverse of viewToCanvas).
    func canvasToView(_ p: NSPoint) -> NSPoint {
        if isInsideScrollView { return p }
        var q = p
        // Apply zoom
        if zoomLevel != 1.0 || zoomAnchorCanvas != .zero || zoomAnchorView != .zero {
            q = NSPoint(
                x: zoomAnchorView.x + (p.x - zoomAnchorCanvas.x) * zoomLevel,
                y: zoomAnchorView.y + (p.y - zoomAnchorCanvas.y) * zoomLevel
            )
        }

        return q
    }

    /// Convert a point in view space to canvas (annotation) space by reversing the zoom transform.
    func viewToCanvas(_ p: NSPoint) -> NSPoint {
        if isInsideScrollView { return p }
        let q = adjustPointForEditor(p)
        if zoomLevel == 1.0 && zoomAnchorCanvas == .zero && zoomAnchorView == .zero { return q }
        guard zoomAnchorCanvas != .zero || zoomAnchorView != .zero else { return q }
        return NSPoint(
            x: zoomAnchorCanvas.x + (q.x - zoomAnchorView.x) / zoomLevel,
            y: zoomAnchorCanvas.y + (q.y - zoomAnchorView.y) / zoomLevel
        )
    }

    func applyZoomTransform(to context: NSGraphicsContext) {
        if isInsideScrollView { return }
        if zoomLevel == 1.0 && zoomAnchorCanvas == .zero && zoomAnchorView == .zero { return }
        guard zoomAnchorCanvas != .zero || zoomAnchorView != .zero else { return }
        let cgCtx = context.cgContext
        // screen = anchorView + (canvas - anchorCanvas) * zoom
        cgCtx.translateBy(
            x: zoomAnchorView.x - zoomAnchorCanvas.x * zoomLevel,
            y: zoomAnchorView.y - zoomAnchorCanvas.y * zoomLevel)
        cgCtx.scaleBy(x: zoomLevel, y: zoomLevel)
    }

    /// Apply editor canvas offset + zoom transform. Use this for all canvas-space drawing.
    func applyCanvasTransform(to context: NSGraphicsContext) {
        applyEditorTransform(to: context)
        applyZoomTransform(to: context)
    }

    /// Set zoom level, pinning the given view-space cursor point in place.
    /// Reset zoom to 1× (no transform). Retained because crop/undo/redo call it;
    /// the overlay no longer zooms, so this just affirms the identity state.
    func resetZoom() {
        zoomLevel = 1.0
        zoomAnchorCanvas = .zero
        zoomAnchorView = .zero
    }

    /// Crop the screenshot to `viewRect` (view-space, within selectionRect),
    /// translate all annotations accordingly, and reset zoom.
    func commitCrop(viewRect: NSRect) {
        guard let originalImage = screenshotImage,
            let cgOriginal = originalImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return }

        // viewRect is already in canvas space (cropDragRect uses canvas coords).
        let canvasRect = viewRect

        // Map canvas rect → CGImage pixel rect.
        // CGImage uses top-left origin; canvas uses bottom-left.
        let pointsW = originalImage.size.width
        let pixScale = CGFloat(cgOriginal.width) / pointsW

        let normX = (canvasRect.minX - selectionRect.minX) / selectionRect.width
        let normY = (canvasRect.minY - selectionRect.minY) / selectionRect.height
        let normW = canvasRect.width / selectionRect.width
        let normH = canvasRect.height / selectionRect.height

        let cgW = CGFloat(cgOriginal.width)
        let cgH = CGFloat(cgOriginal.height)
        let cgPixelRect = CGRect(
            x: max(0, normX * cgW),
            y: max(0, (1.0 - normY - normH) * cgH),  // flip Y for CGImage top-left origin
            width: min(normW * cgW, cgW - max(0, normX * cgW)),
            height: min(normH * cgH, cgH - max(0, (1.0 - normY - normH) * cgH))
        )

        guard cgPixelRect.width > 0, cgPixelRect.height > 0,
            let croppedCG = cgOriginal.cropping(to: cgPixelRect)
        else { return }

        // Save state for undo before modifying
        guard let prevImage = originalImage.copy() as? NSImage else { return }
        undoStack.append(.imageTransform(previousImage: prevImage, previousSnappedWindowImage: nil, annotationOffsets: []))
        redoStack.removeAll()

        let dx = selectionRect.minX - canvasRect.minX
        let dy = selectionRect.minY - canvasRect.minY
        for ann in annotations { ann.move(dx: dx, dy: dy) }

        // Set NSImage size in points (not pixels) to preserve Retina scale
        let croppedPointSize = NSSize(
            width: CGFloat(croppedCG.width) / pixScale,
            height: CGFloat(croppedCG.height) / pixScale)
        screenshotImage = NSImage(cgImage: croppedCG, size: croppedPointSize)

        // Update selectionRect to match new image size
        selectionRect = NSRect(origin: .zero, size: croppedPointSize)

        cachedCompositedImage = nil

        // Resize view frame to match new image size (scroll view re-centers automatically)
        if isInsideScrollView {
            frame.size = croppedPointSize
            enclosingScrollView?.magnification = 1.0
            // Update top bar size label
            if let topBar = chromeParentView?.subviews.compactMap({ $0 as? EditorTopBarView }).first {
                topBar.updateSizeLabel(width: croppedCG.width, height: croppedCG.height)
                topBar.updateZoom(1.0)
            }
        } else {
            resetZoom()
        }
        currentTool = .arrow
        rebuildToolbarLayout()
        needsDisplay = true
    }

    /// One frame of the animated editor zoom: ease 25% of the remaining
    /// distance toward `editorZoomTarget`.
    private func stepEditorZoomAnimation() {
        guard let sv = enclosingScrollView else {
            editorZoomAnimTimer?.invalidate()
            editorZoomAnimTimer = nil
            return
        }
        let current = sv.magnification
        let target = editorZoomTarget
        let diff = target - current
        if abs(diff) < 0.001 {
            sv.setMagnification(target, centeredAt: editorZoomCursorDoc)
            editorZoomAnimTimer?.invalidate()
            editorZoomAnimTimer = nil
            needsDisplay = true
            if let topBar = sv.superview?.subviews.compactMap({ $0 as? EditorTopBarView }).first {
                topBar.updateZoom(target)
            }
            return
        }
        let next = current + diff * 0.25
        sv.setMagnification(next, centeredAt: editorZoomCursorDoc)
        if let topBar = sv.superview?.subviews.compactMap({ $0 as? EditorTopBarView }).first {
            topBar.updateZoom(next)
        }
    }

    // MARK: - Zoom (scroll wheel + trackpad pinch)

    /// Perform cursor-centered zoom on the enclosing scroll view.
    /// Uses NSScrollView's own setMagnification(_:centeredAt:) which handles all the
    /// coordinate math correctly, but we disable allowsMagnification so it doesn't
    /// apply its own elastic physics on top.
    func editorZoom(by factor: CGFloat, cursorInWindow: NSPoint, animated: Bool = false) {
        guard let sv = enclosingScrollView else { return }

        if animated {
            // Accumulate target and animate toward it
            if editorZoomAnimTimer == nil {
                editorZoomTarget = sv.magnification
            }
            editorZoomTarget = max(sv.minMagnification, min(sv.maxMagnification, editorZoomTarget * factor))
            editorZoomCursorDoc = convert(cursorInWindow, from: nil)

            if editorZoomAnimTimer == nil {
                editorZoomAnimTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
                    guard let self else { timer.invalidate(); return }
                    MainActor.assumeIsolated { self.stepEditorZoomAnimation() }
                }
            }
            return
        }

        let oldMag = sv.magnification
        let newMag = max(sv.minMagnification, min(sv.maxMagnification, oldMag * factor))
        guard newMag != oldMag else { return }

        // Convert cursor from window coords to document view (unscaled) coords
        let cursorInDoc = convert(cursorInWindow, from: nil)
        sv.setMagnification(newMag, centeredAt: cursorInDoc)

        // During active zooming, let the GPU-scaled layer handle the visual — it's instant.
        // Debounce the full-resolution redraw to when zooming stops (150ms idle).
        editorZoomRedrawTimer?.invalidate()
        editorZoomRedrawTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.needsDisplay = true }
        }

        if let topBar = sv.superview?.subviews.compactMap({ $0 as? EditorTopBarView }).first {
            topBar.updateZoom(newMag)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        // Editor mode: all scroll handling is done by CenteringClipView.
        // The capture overlay no longer zooms/pans on scroll.
        if isInsideScrollView {
            enclosingScrollView?.scrollWheel(with: event)
        }
    }

    override func magnify(with event: NSEvent) {
        // Editor mode pinch-zooms via the scroll view; the capture overlay
        // does not respond to pinch.
        if isInsideScrollView {
            editorZoom(by: 1.0 + event.magnification, cursorInWindow: event.locationInWindow)
        }
    }

    // MARK: - Output

    /// Render screenshot + all existing annotations into a full-size image.
    /// Used as source for pixelate/blur so they operate on the composited result.
    func compositedImage() -> NSImage? {
        if let cached = cachedCompositedImage { return cached }
        guard let screenshot = captureSourceImage ?? screenshotImage else { return nil }
        if annotations.isEmpty { return screenshot }

        let drawRect = captureDrawRect
        let dimBounds = highlightDimBounds
        let annotationsCopy = annotations
        var success = false
        let image = NSImage(size: drawRect.size, flipped: false) { _ in
            guard let context = NSGraphicsContext.current else {
                return true
            }
            screenshot.draw(
                in: NSRect(origin: .zero, size: drawRect.size), from: .zero, operation: .copy,
                fraction: 1.0)
            // Translate so annotations at selectionRect coords render correctly
            context.cgContext.translateBy(x: -drawRect.origin.x, y: -drawRect.origin.y)
            // Censor annotations render first so other annotations appear on top
            for annotation in annotationsCopy where annotation.tool == .pixelate {
                annotation.draw(in: context)
            }
            Annotation.drawHighlightDim(for: annotationsCopy, in: dimBounds)
            for annotation in annotationsCopy where annotation.tool != .pixelate {
                annotation.draw(in: context)
            }
            success = true
            return true
        }
        if !success {
            _ = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        if !success { return screenshot }
        cachedCompositedImage = image
        return image
    }

    func captureSelectedRegion() -> NSImage? {
        return renderSelectedRegion(includeAnnotations: true)
    }

    /// Capture the selected region WITHOUT annotations — just the raw screenshot.
    /// Used for editable history: the raw image is stored alongside annotation data.
    func captureSelectedRegionRaw() -> NSImage? {
        return renderSelectedRegion(includeAnnotations: false)
    }

    private func renderSelectedRegion(includeAnnotations: Bool) -> NSImage? {
        guard selectionRect.width > 0, selectionRect.height > 0 else { return nil }

        // Determine the source image's actual pixel scale so we render at
        // native resolution instead of relying on lockFocus() which always
        // picks the highest backing scale of any connected display.  This
        // prevents interpolation-upscaling when a 1x external monitor is
        // captured while a Retina display is also connected.
        let scale: CGFloat
        if let screenshot = captureSourceImage ?? screenshotImage,
            let cg = screenshot.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            scale = CGFloat(cg.width) / screenshot.size.width
        } else {
            scale = window?.backingScaleFactor ?? 2.0
        }

        // Snap selection rect to pixel boundaries to prevent sub-pixel
        // interpolation blur (especially visible on 1x non-Retina displays
        // where fractional mouse coordinates aren't absorbed by 2x scaling).
        let snappedRect = NSRect(
            x: round(selectionRect.origin.x * scale) / scale,
            y: round(selectionRect.origin.y * scale) / scale,
            width: round(selectionRect.width * scale) / scale,
            height: round(selectionRect.height * scale) / scale
        )

        let pixelW = Int(snappedRect.width * scale)
        let pixelH = Int(snappedRect.height * scale)
        guard pixelW > 0, pixelH > 0 else { return nil }
        // Use the source image's color space to avoid expensive color conversion on render.
        // Fall back to sRGB if unavailable.
        let cs: CGColorSpace
        if let screenshot = captureSourceImage ?? screenshotImage,
           let cg = screenshot.cgImage(forProposedRect: nil, context: nil, hints: nil),
           let srcCS = cg.colorSpace {
            cs = srcCS
        } else {
            cs = CGColorSpace(name: CGColorSpace.sRGB)!
        }
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard
            let cgCtx = CGContext(
                data: nil,
                width: pixelW, height: pixelH,
                bitsPerComponent: 8,
                bytesPerRow: pixelW * 4,
                space: cs,
                bitmapInfo: bitmapInfo
            )
        else { return nil }

        // Disable interpolation for pixel-perfect output — the screenshot
        // pixels should map 1:1 to the output without any filtering.
        cgCtx.interpolationQuality = .none
        // Scale the CG context so drawing in points maps to the correct pixels.
        cgCtx.scaleBy(x: scale, y: scale)
        cgCtx.translateBy(x: -snappedRect.origin.x, y: -snappedRect.origin.y)

        let nsContext = NSGraphicsContext(cgContext: cgCtx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsContext

        if let screenshot = captureSourceImage ?? screenshotImage {
            // In editor mode the image is at selectionRect (natural size);
            // in overlay mode it fills bounds (full screen).
            let drawRect = captureDrawRect
            screenshot.draw(in: drawRect, from: .zero, operation: .copy, fraction: 1.0)
        }

        if includeAnnotations {
            // Match the live draw order: censor effects first, then the spotlight
            // dim (union of highlight rects), then the regular shape annotations
            // on top — so the exported image matches what's on screen.
            for annotation in annotations where annotation.tool == .pixelate {
                annotation.draw(in: nsContext)
            }
            Annotation.drawHighlightDim(for: annotations, in: highlightDimBounds)
            for annotation in annotations where annotation.tool != .pixelate {
                annotation.draw(in: nsContext)
            }
        }

        NSGraphicsContext.restoreGraphicsState()

        guard let cgImage = cgCtx.makeImage() else { return nil }
        return NSImage(cgImage: cgImage, size: snappedRect.size)
    }
}
