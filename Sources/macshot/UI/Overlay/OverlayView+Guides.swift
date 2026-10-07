import Cocoa

/// Snap alignment guides and the auto measure preview.
extension OverlayView {

    // MARK: - Snap/Alignment Guides

    /// Collect all snap target X and Y values from the selection rect and existing annotations.
    private func collectSnapTargets(excluding: Annotation? = nil) -> (xs: [CGFloat], ys: [CGFloat])
    {
        var xs: [CGFloat] = []
        var ys: [CGFloat] = []

        // Selection rect edges and center
        xs += [selectionRect.minX, selectionRect.midX, selectionRect.maxX]
        ys += [selectionRect.minY, selectionRect.midY, selectionRect.maxY]

        // Existing annotation bounding rects
        for ann in annotations where ann !== excluding {
            let r = ann.boundingRect
            guard r.width > 0 || r.height > 0 else { continue }
            xs += [r.minX, r.midX, r.maxX]
            ys += [r.minY, r.midY, r.maxY]
        }

        return (xs, ys)
    }

    /// Snap a point's X and Y to the nearest target within threshold. Returns snapped point and sets guide lines.
    func snapPoint(_ point: NSPoint, excluding: Annotation? = nil) -> NSPoint {
        guard snapGuidesEnabled else {
            snapGuideX = nil
            snapGuideY = nil
            return point
        }

        let (xs, ys) = collectSnapTargets(excluding: excluding)
        var result = point
        snapGuideX = nil
        snapGuideY = nil

        // Snap X
        var bestDx: CGFloat = snapThreshold + 1
        for tx in xs {
            let d = abs(point.x - tx)
            if d < bestDx {
                bestDx = d
                result.x = tx
                snapGuideX = tx
            }
        }
        if bestDx > snapThreshold {
            snapGuideX = nil
            result.x = point.x
        }

        // Snap Y
        var bestDy: CGFloat = snapThreshold + 1
        for ty in ys {
            let d = abs(point.y - ty)
            if d < bestDy {
                bestDy = d
                result.y = ty
                snapGuideY = ty
            }
        }
        if bestDy > snapThreshold {
            snapGuideY = nil
            result.y = point.y
        }

        return result
    }

    /// Snap a rect (for move operations) — checks all edges and center against targets.
    /// Returns the delta adjustment needed.
    func snapRectDelta(rect: NSRect, excluding: Annotation? = nil) -> (
        dx: CGFloat, dy: CGFloat
    ) {
        guard snapGuidesEnabled else {
            snapGuideX = nil
            snapGuideY = nil
            return (0, 0)
        }

        let (xs, ys) = collectSnapTargets(excluding: excluding)
        let edgesX = [rect.minX, rect.midX, rect.maxX]
        let edgesY = [rect.minY, rect.midY, rect.maxY]

        snapGuideX = nil
        snapGuideY = nil
        var bestDx: CGFloat = snapThreshold + 1
        var snapDx: CGFloat = 0
        var bestDy: CGFloat = snapThreshold + 1
        var snapDy: CGFloat = 0

        for ex in edgesX {
            for tx in xs {
                let d = abs(ex - tx)
                if d < bestDx {
                    bestDx = d
                    snapDx = tx - ex
                    snapGuideX = tx
                }
            }
        }
        if bestDx > snapThreshold {
            snapGuideX = nil
            snapDx = 0
        }

        for ey in edgesY {
            for ty in ys {
                let d = abs(ey - ty)
                if d < bestDy {
                    bestDy = d
                    snapDy = ty - ey
                    snapGuideY = ty
                }
            }
        }
        if bestDy > snapThreshold {
            snapGuideY = nil
            snapDy = 0
        }

        return (snapDx, snapDy)
    }

    /// Draw snap guide lines (called from draw after annotations, before toolbars).
    func drawSnapGuides() {
        guard snapGuidesEnabled else { return }

        let guideColor = NSColor.systemCyan.withAlphaComponent(0.6)
        guideColor.setStroke()

        if let gx = snapGuideX {
            let line = NSBezierPath()
            line.move(to: NSPoint(x: gx, y: selectionRect.minY))
            line.line(to: NSPoint(x: gx, y: selectionRect.maxY))
            line.lineWidth = 0.5
            let pattern: [CGFloat] = [4, 3]
            line.setLineDash(pattern, count: 2, phase: 0)
            line.stroke()
        }

        if let gy = snapGuideY {
            let line = NSBezierPath()
            line.move(to: NSPoint(x: selectionRect.minX, y: gy))
            line.line(to: NSPoint(x: selectionRect.maxX, y: gy))
            line.lineWidth = 0.5
            let pattern: [CGFloat] = [4, 3]
            line.setLineDash(pattern, count: 2, phase: 0)
            line.stroke()
        }
    }

    /// Solid accent guide line(s) on the image edge the selection just snapped
    /// to (boundary snap). Spans the full overlay so the snapped image line is
    /// obvious. Drawn only while resizing with an active snap.
    func drawBoundarySnapGuides() {
        guard boundarySnapGuideX != nil || boundarySnapGuideY != nil else { return }
        ToolbarLayout.accentColor.withAlphaComponent(0.9).setStroke()
        if let gx = boundarySnapGuideX {
            let line = NSBezierPath()
            line.move(to: NSPoint(x: gx, y: bounds.minY))
            line.line(to: NSPoint(x: gx, y: bounds.maxY))
            line.lineWidth = 1
            line.stroke()
        }
        if let gy = boundarySnapGuideY {
            let line = NSBezierPath()
            line.move(to: NSPoint(x: bounds.minX, y: gy))
            line.line(to: NSPoint(x: bounds.maxX, y: gy))
            line.lineWidth = 1
            line.stroke()
        }
    }

    // MARK: - Auto Measure

    /// Update the auto-measure live preview based on cursor position.
    /// Called on keyDown repeat and mouseMoved while key is held.
    func updateAutoMeasurePreview() {
        let vertical = autoMeasureVertical
        autoMeasurePreview = computeAutoMeasure(vertical: vertical)
        needsDisplay = true
    }

    /// Compute an auto-measure annotation from the cursor position along a vertical or horizontal axis
    /// by scanning outward until the pixel color changes significantly.
    private func computeAutoMeasure(vertical: Bool) -> Annotation? {
        guard let screenshot = screenshotImage,
            let cgImage = screenshot.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }

        guard let window = window else { return nil }
        let windowPoint = window.mouseLocationOutsideOfEventStream
        let viewPoint = convert(windowPoint, from: nil)
        let canvasPoint = viewToCanvas(viewPoint)

        let drawRect = captureDrawRect
        let normX = (canvasPoint.x - drawRect.minX) / drawRect.width
        let normY = (canvasPoint.y - drawRect.minY) / drawRect.height

        let w = cgImage.width
        let h = cgImage.height

        let pixelX = Int(normX * CGFloat(w))
        let pixelY = Int((1.0 - normY) * CGFloat(h))

        guard pixelX >= 0, pixelX < w, pixelY >= 0, pixelY < h else {
            return nil
        }

        // Cache the bitmap context — only recreate if the image dimensions changed
        if autoMeasureBitmapCtx == nil || autoMeasureBitmapW != w || autoMeasureBitmapH != h {
            let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
            guard let ctx = CGContext(
                data: nil, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4,
                space: srgb,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
            autoMeasureBitmapCtx = ctx
            autoMeasureBitmapW = w
            autoMeasureBitmapH = h
        }

        guard let data = autoMeasureBitmapCtx?.data else { return nil }
        let ptr = data.assumingMemoryBound(to: UInt8.self)

        func pixelAt(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
            let offset = (y * w + x) * 4
            return (ptr[offset], ptr[offset + 1], ptr[offset + 2])
        }

        func colorDiff(_ a: (UInt8, UInt8, UInt8), _ b: (UInt8, UInt8, UInt8)) -> Int {
            abs(Int(a.0) - Int(b.0)) + abs(Int(a.1) - Int(b.1)) + abs(Int(a.2) - Int(b.2))
        }

        let refColor = pixelAt(pixelX, pixelY)
        let threshold = 30

        func toCanvas(px: Int, py: Int) -> NSPoint {
            let nx = CGFloat(px) / CGFloat(w)
            let ny = 1.0 - CGFloat(py) / CGFloat(h)
            return NSPoint(
                x: drawRect.minX + nx * drawRect.width,
                y: drawRect.minY + ny * drawRect.height)
        }

        var startPx: Int
        var endPx: Int

        if vertical {
            startPx = pixelY
            for py in stride(from: pixelY - 1, through: 0, by: -1) {
                if colorDiff(refColor, pixelAt(pixelX, py)) > threshold { break }
                startPx = py
            }
            endPx = pixelY
            for py in (pixelY + 1)..<h {
                if colorDiff(refColor, pixelAt(pixelX, py)) > threshold { break }
                endPx = py
            }
            var p1 = toCanvas(px: pixelX, py: startPx)
            var p2 = toCanvas(px: pixelX, py: endPx)
            // Auto-measure scans the whole screenshot; when clamping is on and the
            // cursor is inside the selection, stop the ruler at the selection edges.
            if currentMeasureClampToSelection && selectionRect.contains(canvasPoint) {
                p1.y = min(max(p1.y, selectionRect.minY), selectionRect.maxY)
                p2.y = min(max(p2.y, selectionRect.minY), selectionRect.maxY)
            }
            let ann = Annotation(
                tool: .measure, startPoint: p1, endPoint: p2,
                color: annotationColor, strokeWidth: currentStrokeWidth)
            ann.measureInPoints = currentMeasureInPoints
            return ann
        } else {
            startPx = pixelX
            for px in stride(from: pixelX - 1, through: 0, by: -1) {
                if colorDiff(refColor, pixelAt(px, pixelY)) > threshold { break }
                startPx = px
            }
            endPx = pixelX
            for px in (pixelX + 1)..<w {
                if colorDiff(refColor, pixelAt(px, pixelY)) > threshold { break }
                endPx = px
            }
            var p1 = toCanvas(px: startPx, py: pixelY)
            var p2 = toCanvas(px: endPx, py: pixelY)
            if currentMeasureClampToSelection && selectionRect.contains(canvasPoint) {
                p1.x = min(max(p1.x, selectionRect.minX), selectionRect.maxX)
                p2.x = min(max(p2.x, selectionRect.minX), selectionRect.maxX)
            }
            let ann = Annotation(
                tool: .measure, startPoint: p1, endPoint: p2,
                color: annotationColor, strokeWidth: currentStrokeWidth)
            ann.measureInPoints = currentMeasureInPoints
            return ann
        }
    }
}
