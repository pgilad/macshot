import Cocoa

/// Selection handles, outline glow and delete buttons drawn for annotations.
extension OverlayView {

    // MARK: - Annotation Controls

    func drawAnnotationControls(for annotation: Annotation, fullControls: Bool = true) {
        // Arrow, line, and measure: show only 2 endpoint handles, no bounding box
        if annotation.tool == .arrow || annotation.tool == .line || annotation.tool == .measure {
            if !fullControls {
                drawAnnotationOutlineGlow(annotation)
                return
            }

            let pts = annotation.waypoints
            let s: CGFloat = 10
            let sm: CGFloat = 8

            annotationResizeHandleRects = []

            // Draw guide path through all waypoints
            if pts.count > 2 {
                let guidePath = NSBezierPath()
                guidePath.lineWidth = 1
                guidePath.setLineDash([3, 4], count: 2, phase: 0)
                NSColor.white.withAlphaComponent(0.35).setStroke()
                guidePath.move(to: pts[0])
                for i in 1..<pts.count { guidePath.line(to: pts[i]) }
                guidePath.stroke()
            } else if annotation.controlPoint != nil {
                let midPt = annotation.controlPoint!
                let guidePath = NSBezierPath()
                guidePath.lineWidth = 1
                guidePath.setLineDash([3, 4], count: 2, phase: 0)
                NSColor.white.withAlphaComponent(0.35).setStroke()
                guidePath.move(to: annotation.startPoint)
                guidePath.line(to: midPt)
                guidePath.line(to: annotation.endPoint)
                guidePath.stroke()
            }

            // Endpoint handles (start = .bottomLeft, end = .topRight)
            let startRect = NSRect(
                x: pts.first!.x - s / 2, y: pts.first!.y - s / 2, width: s, height: s)
            let endRect = NSRect(
                x: pts.last!.x - s / 2, y: pts.last!.y - s / 2, width: s, height: s)
            annotationResizeHandleRects.append((.bottomLeft, startRect))
            annotationResizeHandleRects.append((.topRight, endRect))

            for rect in [startRect, endRect] {
                ToolbarLayout.accentColor.setFill()
                NSBezierPath(ovalIn: rect).fill()
                NSColor.white.withAlphaComponent(0.9).setStroke()
                let border = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
                border.lineWidth = 1.5
                border.stroke()
            }

            // Intermediate anchor handles — use .none as handle ID since we identify
            // them by array index (annotationResizeAnchorIndex), not by ResizeHandle enum.
            if pts.count > 2 {
                for i in 1..<(pts.count - 1) {
                    let handleID: ResizeHandle = .none
                    let midRect = NSRect(
                        x: pts[i].x - sm / 2, y: pts[i].y - sm / 2, width: sm, height: sm)
                    annotationResizeHandleRects.append((handleID, midRect))
                    NSColor.white.withAlphaComponent(0.9).setFill()
                    NSBezierPath(ovalIn: midRect).fill()
                    ToolbarLayout.accentColor.setStroke()
                    let midBorder = NSBezierPath(ovalIn: midRect.insetBy(dx: 0.5, dy: 0.5))
                    midBorder.lineWidth = 1.5
                    midBorder.stroke()
                }
            } else {
                // Legacy single bend handle (or visual midpoint)
                let midPt =
                    annotation.controlPoint
                    ?? NSPoint(
                        x: (annotation.startPoint.x + annotation.endPoint.x) / 2,
                        y: (annotation.startPoint.y + annotation.endPoint.y) / 2
                    )
                let midRect = NSRect(
                    x: midPt.x - sm / 2, y: midPt.y - sm / 2, width: sm, height: sm)
                annotationResizeHandleRects.append((.top, midRect))
                NSColor.white.withAlphaComponent(0.9).setFill()
                NSBezierPath(ovalIn: midRect).fill()
                ToolbarLayout.accentColor.setStroke()
                let midBorder = NSBezierPath(ovalIn: midRect.insetBy(dx: 0.5, dy: 0.5))
                midBorder.lineWidth = 1.5
                midBorder.stroke()
            }

            // Delete button near endPoint
            let btnSize: CGFloat = 22
            let deleteRect = NSRect(
                x: annotation.endPoint.x + 8, y: annotation.endPoint.y + 2, width: btnSize,
                height: btnSize)
            annotationDeleteButtonRect = deleteRect
            drawDeleteCircle(in: deleteRect)
            annotationEditButtonRect = .zero
            return
        }

        if annotation.tool == .number {
            drawNumberAnnotationControls(for: annotation, fullControls: fullControls)
            return
        }

        let baseRect: NSRect
        switch annotation.tool {
        case .pencil, .marker:
            guard let points = annotation.points, !points.isEmpty else { return }
            var minX = CGFloat.greatestFiniteMagnitude
            var minY = CGFloat.greatestFiniteMagnitude
            var maxX = -CGFloat.greatestFiniteMagnitude
            var maxY = -CGFloat.greatestFiniteMagnitude
            for p in points {
                minX = min(minX, p.x)
                minY = min(minY, p.y)
                maxX = max(maxX, p.x)
                maxY = max(maxY, p.y)
            }
            // Expand by the actual painted stroke radius so the box matches the visible stroke
            let strokeRadius =
                (annotation.tool == .marker ? annotation.strokeWidth * 6 : annotation.strokeWidth)
                / 2
            baseRect = NSRect(
                x: minX - strokeRadius, y: minY - strokeRadius,
                width: maxX - minX + strokeRadius * 2, height: maxY - minY + strokeRadius * 2)
        case .text:
            // startPoint = top-left, endPoint = bottom-right (set at commit time)
            if annotation.endPoint != annotation.startPoint {
                baseRect = annotation.boundingRect
            } else {
                // Legacy: recompute from attributed string size
                let text =
                    annotation.attributedText
                    ?? annotation.text.map {
                        NSAttributedString(
                            string: $0,
                            attributes: [.font: NSFont.systemFont(ofSize: annotation.fontSize)])
                    }
                let size = text?.size() ?? NSSize(width: 50, height: 20)
                baseRect = NSRect(origin: annotation.startPoint, size: size)
            }
        case .loupe:
            baseRect = annotation.boundingRect
        default:
            let strokePad = annotation.strokeWidth / 2
            baseRect = annotation.boundingRect.insetBy(dx: -strokePad, dy: -strokePad)
        }

        let padded = baseRect.insetBy(dx: -4, dy: -4)

        // Text: a glyph-tracing glow looks noisy. Show a plain solid selection
        // rectangle connecting the handles instead. Other annotations keep the
        // shape-following outline glow.
        if annotation.tool == .text {
            let rotated = annotation.rotation != 0 && annotation.supportsRotation
            if rotated {
                // Draw the rect rotated about the box center to match the text.
                NSGraphicsContext.current?.cgContext.saveGState()
                let center = NSPoint(x: baseRect.midX, y: baseRect.midY)
                let xform = NSAffineTransform()
                xform.translateX(by: center.x, yBy: center.y)
                xform.rotate(byRadians: annotation.rotation)
                xform.translateX(by: -center.x, yBy: -center.y)
                xform.concat()
            }
            let border = NSBezierPath(rect: padded)
            border.lineWidth = 1.5
            ToolbarLayout.accentColor.setStroke()
            border.stroke()
            if rotated {
                NSGraphicsContext.current?.cgContext.restoreGState()
            }
        } else {
            // Generic outline glow — works for all annotation types, single and multi-select
            drawAnnotationOutlineGlow(annotation)
        }

        // Multi-select: no handles, rotate, or delete buttons
        guard fullControls else { return }

        // Apply annotation rotation to controls (handles, delete button)
        if annotation.rotation != 0 && annotation.supportsRotation {
            let center = NSPoint(x: baseRect.midX, y: baseRect.midY)
            let xform = NSAffineTransform()
            xform.translateX(by: center.x, yBy: center.y)
            xform.rotate(byRadians: annotation.rotation)
            xform.translateX(by: -center.x, yBy: -center.y)
            NSGraphicsContext.current?.cgContext.saveGState()
            xform.concat()
        }

        // Draw resize handles (8 positions) — pencil/marker don't support rectangular resize.
        if annotation.tool != .pencil && annotation.tool != .marker {
            let handles = annotationAllHandleRects(for: padded)
            annotationResizeHandleRects = handles
            for (_, rect) in handles {
                NSColor.white.setFill()
                NSBezierPath(ovalIn: rect).fill()
                ToolbarLayout.accentColor.setStroke()
                let border = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
                border.lineWidth = 1.5
                border.stroke()
            }
        } else {
            annotationResizeHandleRects = []
        }

        // Restore rotation transform before drawing rotation handle (in screen space)
        if annotation.rotation != 0 && annotation.supportsRotation {
            NSGraphicsContext.current?.cgContext.restoreGState()
        }

        // Rotation handle (above top-center) — matches delete/edit button style
        annotationRotateHandleRect = .zero
        if annotation.supportsRotation {
            let center = NSPoint(x: padded.midX, y: padded.midY)
            let hs: CGFloat = 22
            let handleDist: CGFloat = padded.height / 2 + 20
            // Rotate the handle position by the annotation's current rotation
            let handleX = center.x - handleDist * sin(annotation.rotation)
            let handleY = center.y + handleDist * cos(annotation.rotation)
            let rotRect = NSRect(x: handleX - hs / 2, y: handleY - hs / 2, width: hs, height: hs)
            annotationRotateHandleRect = rotRect

            // Connecting line from top-center of box to handle
            let topCenterX = center.x - (padded.height / 2 + 2) * sin(annotation.rotation)
            let topCenterY = center.y + (padded.height / 2 + 2) * cos(annotation.rotation)
            let connPath = NSBezierPath()
            connPath.lineWidth = 1
            connPath.setLineDash([3, 3], count: 2, phase: 0)
            NSColor.white.withAlphaComponent(0.5).setStroke()
            connPath.move(to: NSPoint(x: topCenterX, y: topCenterY))
            connPath.line(to: NSPoint(x: handleX, y: handleY))
            connPath.stroke()

            // Dark fill (same as delete/edit)
            NSColor(white: 0.12, alpha: 0.94).setFill()
            NSBezierPath(ovalIn: rotRect).fill()
            // Accent border
            ToolbarLayout.accentColor.withAlphaComponent(0.9).setStroke()
            let rotBorder = NSBezierPath(ovalIn: rotRect.insetBy(dx: 0.75, dy: 0.75))
            rotBorder.lineWidth = 1.5
            rotBorder.stroke()

            // White rotate icon
            let cfg = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
            if let img = NSImage(
                systemSymbolName: "arrow.triangle.2.circlepath",
                accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
                let tinted = NSImage(size: img.size, flipped: false) { rect in
                    img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
                    NSColor.white.setFill()
                    rect.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: NSRect(
                    x: rotRect.midX - img.size.width / 2 + 0.5, y: rotRect.midY - img.size.height / 2,
                    width: img.size.width, height: img.size.height))
            }
        }

        // Delete button (X) at top-right outside the box
        let btnSize: CGFloat = 22
        let deleteRect = NSRect(
            x: padded.maxX + 4, y: padded.maxY - btnSize, width: btnSize, height: btnSize)
        annotationDeleteButtonRect = deleteRect
        drawDeleteCircle(in: deleteRect)

        // Two-circle loupe: resize handle on the SOURCE circle (drag to change
        // zoom — the source frames exactly what the lens shows).
        loupeSourceHandleRect = .zero
        if annotation.tool == .loupe, let src = annotation.loupeSourceRect, src.width > 4 {
            let r = min(src.width, src.height) / 2
            // Place on the source circle's outer edge, away from the lens.
            let lensCenter = NSPoint(x: annotation.loupeLensSquareRect.midX,
                                     y: annotation.loupeLensSquareRect.midY)
            let srcCenter = NSPoint(x: src.midX, y: src.midY)
            var ux = srcCenter.x - lensCenter.x, uy = srcCenter.y - lensCenter.y
            let d = hypot(ux, uy)
            if d > 0.001 { ux /= d; uy /= d } else { ux = 0; uy = -1 }
            let hp = NSPoint(x: srcCenter.x + ux * r, y: srcCenter.y + uy * r)
            let hs: CGFloat = 12
            let hrect = NSRect(x: hp.x - hs / 2, y: hp.y - hs / 2, width: hs, height: hs)
            loupeSourceHandleRect = hrect
            NSColor.white.setFill()
            NSBezierPath(ovalIn: hrect).fill()
            ToolbarLayout.accentColor.setStroke()
            let hb = NSBezierPath(ovalIn: hrect.insetBy(dx: 0.5, dy: 0.5))
            hb.lineWidth = 1.5
            hb.stroke()
        }

        // Edit button (pencil) for text annotations — matches delete button style
        if annotation.tool == .text {
            let editRect = NSRect(
                x: padded.maxX + 4, y: padded.maxY - btnSize * 2 - 4, width: btnSize,
                height: btnSize)
            annotationEditButtonRect = editRect
            // Dark fill (same as delete)
            NSColor(white: 0.12, alpha: 0.94).setFill()
            NSBezierPath(ovalIn: editRect).fill()
            // Accent border
            ToolbarLayout.accentColor.withAlphaComponent(0.9).setStroke()
            let editBorder = NSBezierPath(ovalIn: editRect.insetBy(dx: 0.75, dy: 0.75))
            editBorder.lineWidth = 1.5
            editBorder.stroke()
            // White pencil icon
            let symbolConfig = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
            if let img = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)?
                .withSymbolConfiguration(symbolConfig) {
                let tinted = NSImage(size: img.size, flipped: false) { rect in
                    img.draw(in: rect)
                    NSColor.white.setFill()
                    rect.fill(using: .sourceAtop)
                    return true
                }
                let imgRect = NSRect(
                    x: editRect.midX - img.size.width / 2, y: editRect.midY - img.size.height / 2,
                    width: img.size.width, height: img.size.height)
                tinted.draw(in: imgRect, from: .zero, operation: .sourceOver, fraction: 1.0)
            }
        } else {
            annotationEditButtonRect = .zero
        }
    }

    private func drawNumberAnnotationControls(for annotation: Annotation, fullControls: Bool) {
        drawAnnotationOutlineGlow(annotation)

        annotationRotateHandleRect = .zero
        annotationEditButtonRect = .zero
        annotationResizeHandleRects = []

        guard fullControls else { return }

        let center = annotation.startPoint
        let tip = displayNumberTipHandlePoint(for: annotation)
        let guidePath = NSBezierPath()
        guidePath.lineWidth = 1
        guidePath.setLineDash([3, 4], count: 2, phase: 0)
        NSColor.white.withAlphaComponent(0.35).setStroke()
        guidePath.move(to: center)
        guidePath.line(to: tip)
        guidePath.stroke()

        let handleSize: CGFloat = 10
        let centerRect = NSRect(
            x: center.x - handleSize / 2, y: center.y - handleSize / 2,
            width: handleSize, height: handleSize)
        let tipRect = NSRect(
            x: tip.x - handleSize / 2, y: tip.y - handleSize / 2,
            width: handleSize, height: handleSize)
        // Keep both as draggable handles (center moves the circle, tip moves the
        // pointer), but only DRAW the tip dot. The center dot sat on top of the
        // digit and made the number hard to read while selected — the whole
        // circle body is draggable anyway.
        annotationResizeHandleRects = [(.bottomLeft, centerRect), (.topRight, tipRect)]

        ToolbarLayout.accentColor.setFill()
        NSBezierPath(ovalIn: tipRect).fill()
        NSColor.white.withAlphaComponent(0.9).setStroke()
        let tipBorder = NSBezierPath(ovalIn: tipRect.insetBy(dx: 0.5, dy: 0.5))
        tipBorder.lineWidth = 1.5
        tipBorder.stroke()

        let buttonAnchor = annotation.boundingRect
        let btnSize: CGFloat = 22
        let deleteRect = NSRect(
            x: buttonAnchor.maxX + 6, y: buttonAnchor.maxY - btnSize,
            width: btnSize, height: btnSize)
        annotationDeleteButtonRect = deleteRect
        drawDeleteCircle(in: deleteRect)
    }

    private func displayNumberTipHandlePoint(for annotation: Annotation) -> NSPoint {
        let dx = annotation.endPoint.x - annotation.startPoint.x
        let dy = annotation.endPoint.y - annotation.startPoint.y
        if hypot(dx, dy) > 4 {
            return annotation.endPoint
        }
        let radius = 8 + annotation.strokeWidth * 3
        return NSPoint(x: annotation.startPoint.x + radius + 16, y: annotation.startPoint.y)
    }

    /// Shared CIContext for outline glow rendering — reused across frames.
    private static let outlineGlowCIContext = CIContext()

    /// Draw a generic outline glow around any annotation by rendering it offscreen,
    /// dilating the alpha mask, then compositing the outline back. Cached on the annotation.
    private func drawAnnotationOutlineGlow(_ annotation: Annotation) {
        // Skip expensive glow during resize — bounding box changes every frame,
        // invalidating the CIFilter cache. A simple stroke rect is drawn instead.
        if isResizingAnnotation && isSelected(annotation) {
            if annotation.tool == .number { return }
            let rect = annotation.boundingRect.insetBy(dx: -2, dy: -2)
            ToolbarLayout.accentColor.withAlphaComponent(0.5).setStroke()
            let path = annotation.tool == .loupe
                ? NSBezierPath(ovalIn: rect)
                : NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
            path.lineWidth = 2
            path.stroke()
            return
        }
        let outlineWidth: CGFloat = 3
        // Generous padding — accounts for stroke width, line caps, Chaikin smoothing overshoot,
        // arrowheads, and the dilation radius. Bitmap is cached so size doesn't matter per-frame.
        let effectiveStroke: CGFloat
        switch annotation.tool {
        case .marker:
            effectiveStroke = annotation.strokeWidth * 6
        case .loupe:
            effectiveStroke = 4
        default:
            effectiveStroke = annotation.strokeWidth
        }
        let padding = effectiveStroke + outlineWidth + 20

        // Compute actual bounding box — for pencil/marker, use the points array
        // since boundingRect only considers startPoint/endPoint.
        let baseBBox: NSRect
        if let pts = annotation.points, !pts.isEmpty,
           annotation.tool == .pencil || annotation.tool == .marker {
            var minX = CGFloat.greatestFiniteMagnitude, minY = CGFloat.greatestFiniteMagnitude
            var maxX = -CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
            for p in pts {
                minX = min(minX, p.x); minY = min(minY, p.y)
                maxX = max(maxX, p.x); maxY = max(maxY, p.y)
            }
            baseBBox = NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        } else {
            baseBBox = annotation.boundingRect
        }

        // For the glow cache, always use the unrotated bbox. We'll apply rotation at draw time.
        // This avoids regenerating the expensive CIFilter pipeline on every rotation change.
        let unrotatedBBox = baseBBox.insetBy(dx: -padding, dy: -padding)
        guard unrotatedBBox.width > 0, unrotatedBBox.height > 0 else { return }

        // Use cached glow if available and unrotated position hasn't changed.
        // Rotation is handled at draw time via transform, not by regenerating the glow.
        if let cached = annotation.outlineGlowImage, annotation.outlineGlowRect == unrotatedBBox {
            guard let context = NSGraphicsContext.current else { return }
            context.cgContext.saveGState()
            context.cgContext.setAlpha(0.55)
            if annotation.rotation != 0 && annotation.supportsRotation {
                let cx = unrotatedBBox.midX, cy = unrotatedBBox.midY
                context.cgContext.translateBy(x: cx, y: cy)
                context.cgContext.rotate(by: annotation.rotation)
                context.cgContext.translateBy(x: -cx, y: -cy)
            }
            cached.draw(in: unrotatedBBox, from: .zero, operation: .sourceOver, fraction: 1.0)
            context.cgContext.restoreGState()
            return
        }

        let scale: CGFloat = window?.backingScaleFactor ?? 2.0
        let pxW = Int(ceil(unrotatedBBox.width * scale))
        let pxH = Int(ceil(unrotatedBBox.height * scale))
        guard pxW > 0, pxH > 0, pxW < 8000, pxH < 8000 else { return }

        // Render the annotation at rotation=0 into an offscreen bitmap.
        // We temporarily zero out rotation so the glow is cached unrotated.
        let savedRotation = annotation.rotation
        annotation.rotation = 0
        let offscreen = NSImage(size: NSSize(width: unrotatedBBox.width * scale, height: unrotatedBBox.height * scale))
        offscreen.lockFocus()
        guard let offNSCtx = NSGraphicsContext.current else { annotation.rotation = savedRotation; offscreen.unlockFocus(); return }
        offNSCtx.cgContext.scaleBy(x: scale, y: scale)
        offNSCtx.cgContext.translateBy(x: -unrotatedBBox.origin.x, y: -unrotatedBBox.origin.y)
        if annotation.tool == .loupe {
            // Glow only the lens circle. Drawing the full loupe would trace the
            // connecting line + source ring too, and since the glow bitmap is
            // clipped to the lens bounding box, the line produced a broken stray
            // segment. A filled lens circle gives a clean ring glow.
            NSColor.black.setFill()
            NSBezierPath(ovalIn: annotation.loupeLensSquareRect).fill()
        } else {
            annotation.draw(in: offNSCtx)
        }
        offscreen.unlockFocus()
        annotation.rotation = savedRotation

        guard let cgOrig = offscreen.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }

        let ciOrig = CIImage(cgImage: cgOrig)
        guard let dilateFilter = CIFilter(name: "CIMorphologyMaximum") else { return }
        dilateFilter.setValue(ciOrig, forKey: kCIInputImageKey)
        dilateFilter.setValue(outlineWidth * scale, forKey: kCIInputRadiusKey)
        guard let dilated = dilateFilter.outputImage else { return }

        guard let colorFilter = CIFilter(name: "CIFalseColor") else { return }
        let accentCI = CIColor(color: ToolbarLayout.accentColor) ?? CIColor.blue
        colorFilter.setValue(dilated, forKey: kCIInputImageKey)
        colorFilter.setValue(accentCI, forKey: "inputColor0")
        colorFilter.setValue(accentCI, forKey: "inputColor1")
        guard let colored = colorFilter.outputImage else { return }

        guard let subtractFilter = CIFilter(name: "CISourceOutCompositing") else { return }
        subtractFilter.setValue(colored, forKey: kCIInputImageKey)
        subtractFilter.setValue(ciOrig, forKey: kCIInputBackgroundImageKey)
        guard let outline = subtractFilter.outputImage else { return }

        guard let outlineCG = Self.outlineGlowCIContext.createCGImage(outline, from: ciOrig.extent) else { return }

        let outlineImage = NSImage(cgImage: outlineCG, size: unrotatedBBox.size)
        annotation.outlineGlowImage = outlineImage
        annotation.outlineGlowRect = unrotatedBBox

        guard let context = NSGraphicsContext.current else { return }
        context.cgContext.saveGState()
        context.cgContext.setAlpha(0.55)
        if annotation.rotation != 0 && annotation.supportsRotation {
            let cx = unrotatedBBox.midX, cy = unrotatedBBox.midY
            context.cgContext.translateBy(x: cx, y: cy)
            context.cgContext.rotate(by: annotation.rotation)
            context.cgContext.translateBy(x: -cx, y: -cy)
        }
        outlineImage.draw(in: unrotatedBBox, from: .zero, operation: .sourceOver, fraction: 1.0)
        context.cgContext.restoreGState()
    }

    /// Draw a single-annotation delete circle — dark fill, red border, red xmark icon.
    private func drawDeleteCircle(in rect: NSRect) {
        // Dark fill
        NSColor(white: 0.12, alpha: 0.94).setFill()
        NSBezierPath(ovalIn: rect).fill()
        // Red border
        let borderColor = NSColor(red: 0.9, green: 0.3, blue: 0.3, alpha: 0.9)
        borderColor.setStroke()
        let border = NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75))
        border.lineWidth = 1.5
        border.stroke()
        // Red xmark icon
        let iconCfg = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
        if let xImg = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(iconCfg) {
            let tinted = NSImage(size: xImg.size, flipped: false) { r in
                xImg.draw(in: r)
                NSColor(red: 1.0, green: 0.4, blue: 0.4, alpha: 1.0).setFill()
                r.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: NSRect(x: rect.midX - xImg.size.width / 2,
                                    y: rect.midY - xImg.size.height / 2,
                                    width: xImg.size.width, height: xImg.size.height),
                        from: .zero, operation: .sourceOver, fraction: 1.0)
        }
    }

    /// Draw a pill-shaped "Delete N" button below the multi-selection bounding box.
    func drawMultiSelectDeleteButton() {
        guard selectedAnnotations.count > 1 else {
            multiSelectDeleteButtonRect = .zero
            return
        }

        // Compute union bounding rect of all selected annotations
        var unionRect = selectedAnnotations[0].boundingRect
        for ann in selectedAnnotations.dropFirst() {
            unionRect = unionRect.union(ann.boundingRect)
        }

        // Build label
        let count = selectedAnnotations.count
        let label = "Delete" + " \(count)"
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let labelSize = (label as NSString).size(withAttributes: labelAttrs)

        // Pill dimensions
        let iconSize: CGFloat = 13
        let hPad: CGFloat = 12
        let gap: CGFloat = 5
        let pillW = hPad + iconSize + gap + labelSize.width + hPad
        let pillH: CGFloat = 28
        let pillX = unionRect.midX - pillW / 2
        let pillY = unionRect.minY - pillH - 8

        let pillRect = NSRect(x: pillX, y: pillY, width: pillW, height: pillH)
        multiSelectDeleteButtonRect = pillRect

        // Dark background pill
        NSColor(white: 0.12, alpha: 0.94).setFill()
        NSBezierPath(roundedRect: pillRect, xRadius: pillH / 2, yRadius: pillH / 2).fill()
        NSColor.white.withAlphaComponent(0.08).setStroke()
        let borderPath = NSBezierPath(roundedRect: pillRect.insetBy(dx: 0.5, dy: 0.5),
                                       xRadius: pillH / 2, yRadius: pillH / 2)
        borderPath.lineWidth = 0.5
        borderPath.stroke()

        // Trash icon
        let iconCfg = NSImage.SymbolConfiguration(pointSize: iconSize, weight: .medium)
        if let trashImg = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)?
            .withSymbolConfiguration(iconCfg) {
            let tinted = NSImage(size: trashImg.size, flipped: false) { rect in
                trashImg.draw(in: rect)
                NSColor(red: 1.0, green: 0.4, blue: 0.4, alpha: 1.0).setFill()
                rect.fill(using: .sourceAtop)
                return true
            }
            let iconY = pillRect.midY - trashImg.size.height / 2
            tinted.draw(in: NSRect(x: pillX + hPad, y: iconY,
                                    width: trashImg.size.width, height: trashImg.size.height),
                        from: .zero, operation: .sourceOver, fraction: 1.0)
        }

        // Label
        let labelX = pillX + hPad + iconSize + gap
        let labelY = pillRect.midY - labelSize.height / 2
        (label as NSString).draw(at: NSPoint(x: labelX, y: labelY), withAttributes: labelAttrs)
    }

    private func annotationAllHandleRects(for rect: NSRect) -> [(ResizeHandle, NSRect)] {
        let s: CGFloat = 8
        let r = rect
        return [
            (.topLeft, NSRect(x: r.minX - s / 2, y: r.maxY - s / 2, width: s, height: s)),
            (.topRight, NSRect(x: r.maxX - s / 2, y: r.maxY - s / 2, width: s, height: s)),
            (.bottomLeft, NSRect(x: r.minX - s / 2, y: r.minY - s / 2, width: s, height: s)),
            (.bottomRight, NSRect(x: r.maxX - s / 2, y: r.minY - s / 2, width: s, height: s)),
            (.top, NSRect(x: r.midX - s / 2, y: r.maxY - s / 2, width: s, height: s)),
            (.bottom, NSRect(x: r.midX - s / 2, y: r.minY - s / 2, width: s, height: s)),
            (.left, NSRect(x: r.minX - s / 2, y: r.midY - s / 2, width: s, height: s)),
            (.right, NSRect(x: r.maxX - s / 2, y: r.midY - s / 2, width: s, height: s)),
        ]
    }
}
