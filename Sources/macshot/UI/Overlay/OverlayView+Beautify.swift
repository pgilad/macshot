// Over SwiftLint's size limits since before SwiftLint was added: see .swiftlint.yml.
// swiftlint:disable function_body_length cyclomatic_complexity
import Cocoa

/// The beautify preview and its toolbar state.
extension OverlayView {

    // MARK: - Beautify

    func drawBeautifyPreview(context: NSGraphicsContext) {
        let config = beautifyConfig
        let pad = config.padding
        let cornerRadius = config.isWindowSnap ? 10 : config.cornerRadius  // native macOS corner radius for snapped windows
        let shadowRadius = config.shadowRadius
        let shadowOffset = BeautifyRenderer.shadowOffset(for: shadowRadius)

        // Compute the expanded frame around the selection.
        // Shadow extends downward (negative Y in AppKit), so expand the origin down.
        let shadowBleed = shadowRadius + shadowOffset
        let expandedRect: NSRect
        if config.mode == .window && !config.isWindowSnap {
            let titleBarH: CGFloat = 28
            expandedRect = NSRect(
                x: selectionRect.minX - pad - shadowBleed,
                y: selectionRect.minY - pad - shadowBleed,
                width: selectionRect.width + pad * 2 + shadowBleed * 2,
                height: selectionRect.height + titleBarH + pad * 2 + shadowBleed * 2
            )
        } else {
            expandedRect = NSRect(
                x: selectionRect.minX - pad - shadowBleed,
                y: selectionRect.minY - pad - shadowBleed,
                width: selectionRect.width + pad * 2 + shadowBleed * 2,
                height: selectionRect.height + pad * 2 + shadowBleed * 2
            )
        }

        // Clear the dark overlay for the expanded area to make the preview visible
        context.saveGraphicsState()
        if !isEditorMode {
            // Overlay: re-draw the screenshot in the expanded area to erase the dark overlay,
            // then draw the dark overlay back so we have a clean base for the gradient.
            context.cgContext.saveGState()
            NSBezierPath(rect: expandedRect).addClip()
            if let image = screenshotImage {
                image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1.0)
            }
            NSColor.black.withAlphaComponent(0.45).setFill()
            NSBezierPath(rect: expandedRect).fill()
            context.cgContext.restoreGState()
        }

        // Position the image/window centered within the expanded rect (not affected by shadow bleed)
        let innerX = selectionRect.minX - pad
        let innerY = selectionRect.minY - pad

        // Draw gradient background (inner rect without shadow bleed)
        let bgRect: NSRect
        if config.mode == .window && !config.isWindowSnap {
            let titleBarH: CGFloat = 28
            bgRect = NSRect(
                x: innerX, y: innerY, width: selectionRect.width + pad * 2,
                height: selectionRect.height + titleBarH + pad * 2)
        } else {
            bgRect = NSRect(
                x: innerX, y: innerY, width: selectionRect.width + pad * 2,
                height: selectionRect.height + pad * 2)
        }
        context.cgContext.saveGState()
        let bgPath = NSBezierPath(
            roundedRect: bgRect, xRadius: config.bgRadius, yRadius: config.bgRadius)
        bgPath.addClip()
        BeautifyRenderer.drawGradientBackground(
            in: bgRect, config: config, context: context.cgContext)
        context.cgContext.restoreGState()

        // Compute the image rect inside the expanded frame
        let imageRect: NSRect
        let windowRect: NSRect

        if config.mode == .window && !config.isWindowSnap {
            let titleBarH: CGFloat = 28
            let windowW = selectionRect.width
            let windowH = selectionRect.height + titleBarH
            windowRect = NSRect(
                x: innerX + pad,
                y: innerY + pad,
                width: windowW,
                height: windowH
            )
            imageRect = NSRect(
                x: windowRect.minX,
                y: windowRect.minY,
                width: windowW,
                height: windowH - titleBarH
            )
        } else {
            imageRect = NSRect(
                x: innerX + pad,
                y: innerY + pad,
                width: selectionRect.width,
                height: selectionRect.height
            )
            windowRect = imageRect
        }

        // Drop shadow (not for snapped windows — handled via transparency layer below)
        if shadowRadius > 0 && !config.isWindowSnap {
            let shadowPath = NSBezierPath(
                roundedRect: windowRect, xRadius: cornerRadius, yRadius: cornerRadius)
            BeautifyRenderer.drawShadowedPath(shadowPath, radius: shadowRadius)
        }

        if config.isWindowSnap {
            // Snapped window: use independently captured window image (has real transparent corners).
            // Draw it directly on top of the gradient — transparent corners reveal the gradient.
            let drawWindowImage: NSImage?
            if let windowImage = snappedWindowImage {
                drawWindowImage = effectsActive ? ImageEffects.apply(to: windowImage, config: effectsConfig) : windowImage
            } else { drawWindowImage = nil }
            context.cgContext.saveGState()

            // Drop shadow from the window shape
            if shadowRadius > 0 {
                context.cgContext.saveGState()
                context.cgContext.setShadow(
                    offset: CGSize(
                        width: 0,
                        height: -BeautifyRenderer.contactShadowOffset(for: shadowRadius)),
                    blur: BeautifyRenderer.contactShadowBlur(for: shadowRadius),
                    color: NSColor.black.withAlphaComponent(
                        BeautifyRenderer.contactShadowAlpha(for: shadowRadius)).cgColor)
                if let windowImg = drawWindowImage {
                    windowImg.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1.0)
                } else if let image = screenshotImage {
                    let drawImage = effectsActive ? effectsProcessedScreenshot(image) : image
                    drawImage.draw(
                        in: imageRect, from: selectionRect, operation: .sourceOver, fraction: 1.0)
                }
                context.cgContext.restoreGState()

                context.cgContext.saveGState()
                context.cgContext.setShadow(
                    offset: CGSize(width: 0, height: -shadowOffset),
                    blur: shadowRadius,
                    color: NSColor.black.withAlphaComponent(
                        BeautifyRenderer.shadowAlpha(for: shadowRadius)).cgColor)
                if let windowImg = drawWindowImage {
                    windowImg.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1.0)
                } else if let image = screenshotImage {
                    let drawImage = effectsActive ? effectsProcessedScreenshot(image) : image
                    drawImage.draw(
                        in: imageRect, from: selectionRect, operation: .sourceOver, fraction: 1.0)
                }
                context.cgContext.restoreGState()
            }

            if let windowImg = drawWindowImage {
                windowImg.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1.0)
            } else if let image = screenshotImage {
                // Fallback: crop from screenshot (before window capture completes)
                let drawImage = effectsActive ? effectsProcessedScreenshot(image) : image
                drawImage.draw(
                    in: imageRect, from: selectionRect, operation: .sourceOver, fraction: 1.0)
            }

            // Draw annotations shifted to the preview position
            let dx = imageRect.minX - selectionRect.minX
            let dy = imageRect.minY - selectionRect.minY
            if dx != 0 || dy != 0 {
                context.cgContext.translateBy(x: dx, y: dy)
            }
            for annotation in annotations where annotation.tool == .pixelate {
                annotation.draw(in: context)
            }
            Annotation.drawHighlightDim(for: annotations, extra: currentAnnotation, in: selectionRect)
            for annotation in annotations where annotation.tool != .pixelate {
                annotation.draw(in: context)
            }
            currentAnnotation?.draw(in: context)
            if dx != 0 || dy != 0 {
                context.cgContext.translateBy(x: -dx, y: -dy)
            }

            context.cgContext.restoreGState()
        } else if config.mode == .window {
            // Draw window chrome
            let titleBarH: CGFloat = 28

            context.cgContext.saveGState()
            NSBezierPath(roundedRect: windowRect, xRadius: cornerRadius, yRadius: cornerRadius)
                .addClip()

            // Window background
            NSColor(white: 0.97, alpha: 1.0).setFill()
            NSBezierPath(rect: windowRect).fill()

            // Title bar
            let titleBarRect = NSRect(
                x: windowRect.minX, y: windowRect.maxY - titleBarH, width: windowRect.width,
                height: titleBarH)
            NSColor(white: 0.94, alpha: 1.0).setFill()
            NSBezierPath(rect: titleBarRect).fill()

            // Separator
            NSColor(white: 0.82, alpha: 1.0).setFill()
            NSBezierPath(
                rect: NSRect(
                    x: windowRect.minX, y: titleBarRect.minY - 0.5, width: windowRect.width,
                    height: 0.5)
            ).fill()

            // Traffic lights
            let buttonY = titleBarRect.midY
            let buttonRadius: CGFloat = 6
            let buttonStartX = windowRect.minX + 14
            let buttonSpacing: CGFloat = 20
            let trafficLights: [(NSColor, NSColor)] = [
                (
                    NSColor(calibratedRed: 1.0, green: 0.38, blue: 0.35, alpha: 1.0),
                    NSColor(calibratedRed: 0.85, green: 0.25, blue: 0.22, alpha: 1.0)
                ),
                (
                    NSColor(calibratedRed: 1.0, green: 0.75, blue: 0.25, alpha: 1.0),
                    NSColor(calibratedRed: 0.85, green: 0.60, blue: 0.15, alpha: 1.0)
                ),
                (
                    NSColor(calibratedRed: 0.30, green: 0.80, blue: 0.35, alpha: 1.0),
                    NSColor(calibratedRed: 0.20, green: 0.65, blue: 0.25, alpha: 1.0)
                ),
            ]
            for (i, (fill, ring)) in trafficLights.enumerated() {
                let cx = buttonStartX + CGFloat(i) * buttonSpacing
                let circleRect = NSRect(
                    x: cx - buttonRadius, y: buttonY - buttonRadius, width: buttonRadius * 2,
                    height: buttonRadius * 2)
                fill.setFill()
                NSBezierPath(ovalIn: circleRect).fill()
                ring.setStroke()
                let border = NSBezierPath(ovalIn: circleRect.insetBy(dx: 0.5, dy: 0.5))
                border.lineWidth = 0.5
                border.stroke()
            }

            // Draw screenshot in content area (clipped to window shape), with effects if active
            if let image = screenshotImage {
                let drawImage = effectsActive ? effectsProcessedScreenshot(image) : image
                drawImage.draw(
                    in: imageRect, from: selectionRect, operation: .sourceOver, fraction: 1.0)
            }

            // Draw annotations shifted to the preview position (including current live annotation)
            let dx = imageRect.minX - selectionRect.minX
            let dy = imageRect.minY - selectionRect.minY
            if dx != 0 || dy != 0 {
                context.cgContext.translateBy(x: dx, y: dy)
            }
            for annotation in annotations where annotation.tool == .pixelate {
                annotation.draw(in: context)
            }
            Annotation.drawHighlightDim(for: annotations, extra: currentAnnotation, in: selectionRect)
            for annotation in annotations where annotation.tool != .pixelate {
                annotation.draw(in: context)
            }
            currentAnnotation?.draw(in: context)
            if dx != 0 || dy != 0 {
                context.cgContext.translateBy(x: -dx, y: -dy)
            }

            context.cgContext.restoreGState()
        } else {
            // Rounded mode — just rounded corners on the image
            context.cgContext.saveGState()
            NSBezierPath(roundedRect: imageRect, xRadius: cornerRadius, yRadius: cornerRadius)
                .addClip()

            if let image = screenshotImage {
                let drawImage = effectsActive ? effectsProcessedScreenshot(image) : image
                drawImage.draw(in: imageRect, from: selectionRect, operation: .copy, fraction: 1.0)
            }

            // Draw annotations shifted to preview position (including current live annotation)
            let dx = imageRect.minX - selectionRect.minX
            let dy = imageRect.minY - selectionRect.minY
            if dx != 0 || dy != 0 {
                context.cgContext.translateBy(x: dx, y: dy)
            }
            for annotation in annotations where annotation.tool == .pixelate {
                annotation.draw(in: context)
            }
            Annotation.drawHighlightDim(for: annotations, extra: currentAnnotation, in: selectionRect)
            for annotation in annotations where annotation.tool != .pixelate {
                annotation.draw(in: context)
            }
            currentAnnotation?.draw(in: context)
            if dx != 0 || dy != 0 {
                context.cgContext.translateBy(x: -dx, y: -dy)
            }

            context.cgContext.restoreGState()
        }

        context.restoreGraphicsState()
    }

    /// Whether the current tool should show the options row
    var toolHasOptionsRow: Bool {
        // Show options row for a selected annotation's tool even when currentTool is .select
        if selectedAnnotation != nil && toolOptionsRowView?.editingAnnotation != nil {
            return true
        }
        switch currentTool {
        case .pencil, .line, .arrow, .rectangle, .ellipse, .marker, .number, .loupe, .measure,
            .pixelate, .stamp, .highlight:
            return true
        case .text:
            return true
        default:
            return showBeautifyInOptionsRow
        }
    }

    private func startBeautifyToolbarAnimation() {
        beautifyToolbarAnimProgress = 0
        beautifyToolbarAnimTarget = beautifyEnabled
        beautifyToolbarAnimTimer?.invalidate()
        beautifyToolbarAnimTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            MainActor.assumeIsolated {
                self.beautifyToolbarAnimProgress += 0.08  // ~12 frames = 0.2s
                if self.beautifyToolbarAnimProgress >= 1.0 {
                    self.beautifyToolbarAnimProgress = 1.0
                    self.beautifyToolbarAnimTimer?.invalidate()
                    self.beautifyToolbarAnimTimer = nil
                }
                self.needsDisplay = true
            }
        }
    }

    /// Apply the Beautify enabled state consistently regardless of which UI control changed it.
    func setBeautifyEnabled(_ enabled: Bool) {
        guard beautifyEnabled != enabled else { return }
        beautifyEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "beautifyEnabled")
        cachedCompositedImage = nil
        startBeautifyToolbarAnimation()
        needsDisplay = true
        onContentChanged?()
    }
}
