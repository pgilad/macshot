// Over SwiftLint's size limits since before SwiftLint was added: see .swiftlint.yml.
// swiftlint:disable function_body_length cyclomatic_complexity
import Cocoa

/// draw(_:) and the previews drawn over the capture.
extension OverlayView {

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let context = NSGraphicsContext.current else { return }

        // In editor mode: dark background, draw image centered at natural size (no stretch).
        // selectionRect stays at (0, 0, imgW, imgH) — annotations always use image-relative coords.
        if isEditorMode {
            drawEditorBackground(context: context)
        } else if isScrollCapturing {
            // During scroll capture: make the entire window transparent so the user sees
            // live screen content everywhere (not just inside the selection).
            context.cgContext.clear(bounds)
        } else if let image = screenshotImage {
            // Screenshot ready — draw it with dark overlay
            if !usesExternalScreenshotPreview {
                image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1.0)
            }
            if !selectionOutsideShadowDisabled {
                NSColor.black.withAlphaComponent(0.45).setFill()
                NSBezierPath(rect: bounds).fill()
            }
        } else {
            // No screenshot yet — fully transparent. User sees live desktop
            // through the overlay and can start selecting immediately.
            context.cgContext.clear(bounds)
        }

        // Snap-target highlight (drawn before helper text so text appears on top)
        drawSnapHighlight()

        // Helper text (capture instructions). Suppressed when the user has
        // enabled "Hide capture instructions" in Settings (issue #226).
        if Preferences.hideCaptureInstructions {
            hidePreSelectionPresetButton()
        } else {
            if state == .idle {
                if screenshotImage != nil {
                    drawIdleHelperText()
                } else {
                    hidePreSelectionPresetButton()
                }
            } else if state == .selecting {
                hidePreSelectionPresetButton()
                drawSelectingHelperText()
            } else {
                hidePreSelectionPresetButton()
            }
        }

        // Draw remote selection region (cross-screen drag from another overlay)
        if remoteSelectionRect.width >= 1 && remoteSelectionRect.height >= 1 {
            if shouldClipSelectionImage() {
                context.saveGraphicsState()
                NSBezierPath(rect: remoteSelectionRect).setClip()
                if usesExternalScreenshotPreview && zoomLevel == 1 {
                    context.cgContext.setBlendMode(.clear)
                    NSBezierPath(rect: remoteSelectionRect).fill()
                } else if let image = screenshotImage {
                    image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1.0)
                }
                context.restoreGraphicsState()
            }
            // Purple border for remote selection
            let remoteBorder = NSBezierPath(rect: remoteSelectionRect)
            remoteBorder.lineWidth = 2.0
            ToolbarLayout.accentColor.setStroke()
            remoteBorder.stroke()

            // Resize handles for remote selection
            drawRemoteResizeHandles()
        }

        // Draw clear selection region
        if state != .idle && selectionRect.width >= 1 && selectionRect.height >= 1 {
            // During scroll capture: punch a fully-transparent hole so the live screen
            // content underneath shows through the overlay window.
            if isScrollCapturing {
                context.saveGraphicsState()
                context.cgContext.clear(selectionRect)
                context.restoreGraphicsState()
            }

            // Draw screenshot clipped to selection (image never bleeds outside).
            // In editor mode this is already handled by the detached draw block above.
            if shouldClipSelectionImage() {
                context.saveGraphicsState()
                NSBezierPath(rect: selectionRect).setClip()
                if !isScrollCapturing, usesExternalScreenshotPreview, zoomLevel == 1 {
                    context.cgContext.setBlendMode(.clear)
                    NSBezierPath(rect: selectionRect).fill()
                } else if !isScrollCapturing, let image = screenshotImage {
                    applyZoomTransform(to: context)
                    image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1.0)
                }
                context.restoreGraphicsState()
            }

            // Skip annotation drawing if the editor already drew them via the cached composite.
            let editorDrawnFromCache = (self as? EditorView)?.drewFromCompositeCache ?? false
            let drawingHighlightPreview = currentAnnotation?.tool == .highlight

            if !editorDrawnFromCache {
                // Use cached annotation layer whenever possible — even during active
                // drawing. Committed annotations don't change while a new stroke is
                // being drawn, so re-iterating them every frame wastes CPU and causes
                // event coalescing (fewer mouse events → over-smoothed strokes).
                if !annotations.isEmpty && !isEditorMode {
                    if isDraggingAnnotation || isResizingAnnotation || isRotatingAnnotation,
                       let staticLayer = cachedAnnotationLayerExcludingSelected {
                        // During drag/resize: draw cached static annotations + selected ones live
                        context.saveGraphicsState()
                        applyCanvasTransform(to: context)
                        staticLayer.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1.0)
                        // The static layer skipped the highlight dim; draw it live
                        // here over the union of ALL highlights at their current
                        // (possibly mid-drag) positions, before the selected
                        // annotations' borders.
                        Annotation.drawHighlightDim(for: annotations, in: highlightDimBounds)
                        for annotation in selectedAnnotations {
                            annotation.draw(in: context)
                        }
                    } else if drawingHighlightPreview {
                        // Drawing a NEW highlight: draw only pre-dim effects here.
                        // The live union dim and all annotation borders are drawn
                        // below in final render order so existing highlight borders
                        // do not appear thinner while dragging.
                        context.saveGraphicsState()
                        applyCanvasTransform(to: context)
                        for annotation in annotations where annotation.tool == .pixelate {
                            annotation.draw(in: context)
                        }
                    } else {
                        let layer = annotationLayerImage()
                        context.saveGraphicsState()
                        applyCanvasTransform(to: context)
                        layer.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1.0)
                    }
                } else if !annotations.isEmpty {
                    // Editor mode: no annotation layer cache, draw individually.
                    // Draw user annotations unclipped — strokes can continue past the selection border.
                    // Censor annotations (pixelate/blur) render first so other annotations
                    // always appear on top of blurred regions.
                    context.saveGraphicsState()
                    applyCanvasTransform(to: context)
                    for annotation in annotations where annotation.tool == .pixelate {
                        annotation.draw(in: context)
                    }
                    // Skip the committed-highlight dim while a new highlight is
                    // being drawn — it's drawn live below over the full union
                    // (committed + in-progress) so the existing ones don't get
                    // re-dimmed by the preview pass.
                    if !drawingHighlightPreview {
                        Annotation.drawHighlightDim(for: annotations, in: highlightDimBounds)
                        for annotation in annotations where annotation.tool != .pixelate {
                            annotation.draw(in: context)
                        }
                    }
                } else {
                    context.saveGraphicsState()
                    applyCanvasTransform(to: context)
                }
            } else {
                // Still need the canvas transform for active drawing and overlays below
                context.saveGraphicsState()
                applyCanvasTransform(to: context)
            }
            // Live spotlight dim preview while a new highlight is being dragged:
            // dim the union of ALL highlights (committed + the in-progress one) so
            // previously-placed highlights stay bright instead of being re-dimmed.
            if let cur = currentAnnotation, cur.tool == .highlight {
                Annotation.drawHighlightDim(for: annotations, extra: cur, in: highlightDimBounds)
                for annotation in annotations where annotation.tool != .pixelate {
                    annotation.draw(in: context)
                }
            }
            currentAnnotation?.draw(in: context)
            autoMeasurePreview?.draw(in: context)

            // Crop selection rectangle preview
            if isCropDragging && cropDragRect.width > 1 && cropDragRect.height > 1 {
                drawCropPreview()

                // Crop border
                NSColor.white.setStroke()
                let cropBorder = NSBezierPath(rect: cropDragRect)
                cropBorder.lineWidth = 1.5
                cropBorder.stroke()

                // Rule of thirds grid
                NSColor.white.withAlphaComponent(0.3).setStroke()
                let thirdW = cropDragRect.width / 3
                let thirdH = cropDragRect.height / 3
                for i in 1...2 {
                    let gridLine = NSBezierPath()
                    gridLine.move(
                        to: NSPoint(
                            x: cropDragRect.minX + thirdW * CGFloat(i), y: cropDragRect.minY))
                    gridLine.line(
                        to: NSPoint(
                            x: cropDragRect.minX + thirdW * CGFloat(i), y: cropDragRect.maxY))
                    gridLine.lineWidth = 0.5
                    gridLine.stroke()
                    let hLine = NSBezierPath()
                    hLine.move(
                        to: NSPoint(
                            x: cropDragRect.minX, y: cropDragRect.minY + thirdH * CGFloat(i)))
                    hLine.line(
                        to: NSPoint(
                            x: cropDragRect.maxX, y: cropDragRect.minY + thirdH * CGFloat(i)))
                    hLine.lineWidth = 0.5
                    hLine.stroke()
                }
            }

            // Live loupe preview when loupe tool is active
            if currentTool == .loupe && selectionRect.contains(loupeCursorPoint)
                && loupeCursorPoint != .zero {
                drawLoupePreview(at: loupeCursorPoint)
            }
            if currentTool == .colorSampler && colorSamplerPoint != .zero {
                drawColorSamplerPreview(at: colorSamplerPoint)
            }

            // Draw selection highlight for selected annotations
            for selected in selectedAnnotations {
                // Only draw full controls (handles, buttons) for single selection
                drawAnnotationControls(for: selected, fullControls: selectedAnnotations.count == 1)
            }
            // Consolidated delete button for multi-selection
            drawMultiSelectDeleteButton()

            // Pencil/marker cursor dot preview inside zoom transform so it scales with zoom
            if (currentTool == .pencil || currentTool == .marker) && drawingCursorPoint != .zero && currentAnnotation == nil && !isDraggingAnnotation && !isResizingAnnotation && !isRotatingAnnotation {
                drawDrawingCursorPreview(at: drawingCursorPoint)
            }

            // Snap alignment guides
            drawSnapGuides()

            // Lasso selection marquee (drawn in canvas space — same as annotations)
            if isLassoSelecting && lassoRect.width > 0 && lassoRect.height > 0 {
                NSColor.systemBlue.withAlphaComponent(0.1).setFill()
                NSBezierPath(rect: lassoRect).fill()
                NSColor.systemBlue.withAlphaComponent(0.6).setStroke()
                let border = NSBezierPath(rect: lassoRect)
                border.lineWidth = 1.0
                let pattern: [CGFloat] = [4, 3]
                border.setLineDash(pattern, count: 2, phase: 0)
                border.stroke()
            }

            context.restoreGraphicsState()

            // (Text move handle removed — standard annotation chrome handles movement)

            // Live beautify preview — draw gradient background, shadow, and rounded image around selection
            let showBeautifyPreview = beautifyEnabled && state == .selected && !isScrollCapturing
            let showEffectsPreview = effectsActive && state == .selected && !isScrollCapturing && !beautifyEnabled

            if showBeautifyPreview {
                context.saveGraphicsState()
                applyCanvasTransform(to: context)
                drawBeautifyPreview(context: context)
                context.restoreGraphicsState()

                // Re-draw in-progress annotation on top of beautify so it stays visible
                if currentAnnotation != nil || autoMeasurePreview != nil {
                    context.saveGraphicsState()
                    applyCanvasTransform(to: context)
                    currentAnnotation?.draw(in: context)
                    autoMeasurePreview?.draw(in: context)
                    context.restoreGraphicsState()
                }

                // Re-draw annotation controls on top of the beautify preview so they stay visible.
                if !selectedAnnotations.isEmpty {
                    context.saveGraphicsState()
                    applyCanvasTransform(to: context)
                    for selected in selectedAnnotations {
                        drawAnnotationControls(for: selected, fullControls: selectedAnnotations.count == 1)
                    }
                    drawMultiSelectDeleteButton()
                    context.restoreGraphicsState()
                }

                // Re-draw loupe preview on top of beautify so it stays visible
                if currentTool == .loupe && selectionRect.contains(loupeCursorPoint)
                    && loupeCursorPoint != .zero {
                    context.saveGraphicsState()
                    applyCanvasTransform(to: context)
                    drawLoupePreview(at: loupeCursorPoint)
                    context.restoreGraphicsState()
                }

                // Re-draw color sampler preview on top of beautify
                if currentTool == .colorSampler && colorSamplerPoint != .zero {
                    context.saveGraphicsState()
                    applyCanvasTransform(to: context)
                    drawColorSamplerPreview(at: colorSamplerPoint)
                    context.restoreGraphicsState()
                }

                // Re-draw snap guides on top of beautify
                if snapGuideX != nil || snapGuideY != nil {
                    context.saveGraphicsState()
                    applyCanvasTransform(to: context)
                    drawSnapGuides()
                    context.restoreGraphicsState()
                }

                // Re-draw drawing cursor dot preview on top of beautify
                if (currentTool == .pencil || currentTool == .marker) && drawingCursorPoint != .zero && currentAnnotation == nil && !isDraggingAnnotation && !isResizingAnnotation && !isRotatingAnnotation {
                    context.saveGraphicsState()
                    applyCanvasTransform(to: context)
                    drawDrawingCursorPreview(at: drawingCursorPoint)
                    context.restoreGraphicsState()
                }

                // Re-draw crop preview on top of beautify
                if isCropDragging && cropDragRect.width > 1 && cropDragRect.height > 1 {
                    context.saveGraphicsState()
                    applyCanvasTransform(to: context)
                    drawCropPreview()
                    NSColor.white.setStroke()
                    let cropBorder = NSBezierPath(rect: cropDragRect)
                    cropBorder.lineWidth = 1.5
                    cropBorder.stroke()
                    context.restoreGraphicsState()
                }
            }

            // Effects-only preview (no beautify) — draw effects-processed screenshot in selection
            if showEffectsPreview, let screenshot = screenshotImage {
                context.saveGraphicsState()
                applyCanvasTransform(to: context)
                NSBezierPath(rect: selectionRect).setClip()
                let effectsImage = effectsProcessedScreenshot(screenshot)
                effectsImage.draw(in: captureDrawRect, from: .zero, operation: .copy, fraction: 1.0)
                // Re-draw annotations on top (censor first, then everything else)
                for annotation in annotations where annotation.tool == .pixelate { annotation.draw(in: context) }
                Annotation.drawHighlightDim(for: annotations, extra: currentAnnotation, in: highlightDimBounds)
                for annotation in annotations where annotation.tool != .pixelate { annotation.draw(in: context) }
                currentAnnotation?.draw(in: context)
                context.restoreGraphicsState()

                // Re-draw overlays on top of effects preview
                if !selectedAnnotations.isEmpty {
                    context.saveGraphicsState()
                    applyCanvasTransform(to: context)
                    for selected in selectedAnnotations {
                        drawAnnotationControls(for: selected, fullControls: selectedAnnotations.count == 1)
                    }
                    drawMultiSelectDeleteButton()
                    context.restoreGraphicsState()
                }
                if currentTool == .loupe && selectionRect.contains(loupeCursorPoint) && loupeCursorPoint != .zero {
                    context.saveGraphicsState()
                    applyCanvasTransform(to: context)
                    drawLoupePreview(at: loupeCursorPoint)
                    context.restoreGraphicsState()
                }
                if currentTool == .colorSampler && colorSamplerPoint != .zero {
                    context.saveGraphicsState()
                    applyCanvasTransform(to: context)
                    drawColorSamplerPreview(at: colorSamplerPoint)
                    context.restoreGraphicsState()
                }
                if (currentTool == .pencil || currentTool == .marker) && drawingCursorPoint != .zero && currentAnnotation == nil && !isDraggingAnnotation && !isResizingAnnotation && !isRotatingAnnotation {
                    context.saveGraphicsState()
                    applyCanvasTransform(to: context)
                    drawDrawingCursorPreview(at: drawingCursorPoint)
                    context.restoreGraphicsState()
                }
                if snapGuideX != nil || snapGuideY != nil {
                    context.saveGraphicsState()
                    applyCanvasTransform(to: context)
                    drawSnapGuides()
                    context.restoreGraphicsState()
                }
            }

            // Selection border — hidden in editor mode and when beautify/effects preview is active,
            // red during scroll capture, purple otherwise
            if shouldDrawSelectionBorder()
                && !showBeautifyPreview && !showEffectsPreview {
                let borderPath = NSBezierPath(rect: selectionRect)
                borderPath.lineWidth = isScrollCapturing ? 2.5 : 2.0
                (isScrollCapturing ? NSColor.systemRed : ToolbarLayout.accentColor).setStroke()
                borderPath.stroke()
            }

            // Resolution box (real NSView) is managed in updateResolutionBox(),
            // called from layout/selection changes — not drawn here.

            // Resize handles (not during scroll capture)
            if state == .selected && !isEditorMode && !isScrollCapturing {
                drawResizeHandles()
            }

            // Boundary-snap guide line(s) — while resizing or drawing a new
            // selection with an active snap.
            if isResizingSelection || state == .selecting {
                drawBoundarySnapGuides()
            }

            // Hide the text view when color picker is open for bg/outline (so picker isn't behind it)
            if let sv = textEditor.scrollView {
                let shouldHide = false
                sv.isHidden = shouldHide
            }

            // Live text box (bg/outline + resize handles)
            if let sv = textEditor.scrollView, textEditView != nil {
                let pad: CGFloat = 4
                let pillRect = sv.frame.insetBy(dx: -pad, dy: -pad)
                let cornerR: CGFloat = 4

                // Background fill
                if textEditor.bgEnabled {
                    textEditor.bgColor.setFill()
                    NSBezierPath(roundedRect: pillRect, xRadius: cornerR, yRadius: cornerR).fill()
                }

                // Text outline
                if textEditor.outlineEnabled {
                    textEditor.outlineColor.setStroke()
                    let outlinePath = NSBezierPath(
                        roundedRect: pillRect, xRadius: cornerR, yRadius: cornerR)
                    outlinePath.lineWidth = 2
                    outlinePath.stroke()
                }

                // Draw text content when scroll view is hidden (color picker open)
                if sv.isHidden, let tv = textEditView, let attrStr = tv.textStorage,
                    attrStr.length > 0 {
                    let inset = tv.textContainerInset
                    let textRect = NSRect(
                        x: sv.frame.minX + inset.width, y: sv.frame.minY + inset.height,
                        width: sv.frame.width - inset.width * 2,
                        height: sv.frame.height - inset.height * 2)
                    context.saveGraphicsState()
                    let flipped = NSAffineTransform()
                    flipped.translateX(by: 0, yBy: sv.frame.maxY + sv.frame.minY)
                    flipped.scaleX(by: 1, yBy: -1)
                    flipped.concat()
                    attrStr.draw(in: textRect)
                    context.restoreGraphicsState()
                }

                // Box border (always visible while editing)
                NSColor.white.withAlphaComponent(0.4).setStroke()
                let borderPath = NSBezierPath(rect: sv.frame)
                borderPath.lineWidth = 1
                let pattern: [CGFloat] = [4, 3]
                borderPath.setLineDash(pattern, count: 2, phase: 0)
                borderPath.stroke()

                // Resize handles on the text box
                let hs: CGFloat = 6
                let handleColor = NSColor.white
                let handleRects = [
                    NSRect(
                        x: sv.frame.minX - hs / 2, y: sv.frame.minY - hs / 2, width: hs, height: hs),  // bottom-left
                    NSRect(
                        x: sv.frame.maxX - hs / 2, y: sv.frame.minY - hs / 2, width: hs, height: hs),  // bottom-right
                    NSRect(
                        x: sv.frame.minX - hs / 2, y: sv.frame.maxY - hs / 2, width: hs, height: hs),  // top-left
                    NSRect(
                        x: sv.frame.maxX - hs / 2, y: sv.frame.maxY - hs / 2, width: hs, height: hs),  // top-right
                    NSRect(
                        x: sv.frame.midX - hs / 2, y: sv.frame.minY - hs / 2, width: hs, height: hs),  // bottom
                    NSRect(
                        x: sv.frame.midX - hs / 2, y: sv.frame.maxY - hs / 2, width: hs, height: hs),  // top
                    NSRect(
                        x: sv.frame.minX - hs / 2, y: sv.frame.midY - hs / 2, width: hs, height: hs),  // left
                    NSRect(
                        x: sv.frame.maxX - hs / 2, y: sv.frame.midY - hs / 2, width: hs, height: hs),  // right
                ]
                for hr in handleRects {
                    handleColor.setFill()
                    NSBezierPath(roundedRect: hr, xRadius: 1, yRadius: 1).fill()
                    NSColor.black.withAlphaComponent(0.3).setStroke()
                    NSBezierPath(roundedRect: hr, xRadius: 1, yRadius: 1).stroke()
                }
            }

            // Stamp cursor preview
            if let previewPt = stampPreviewPoint, let img = currentStampImage,
                currentTool == .stamp {
                let stampSize: CGFloat = currentStampSize
                let aspect = img.size.width / max(img.size.height, 1)
                let w = aspect >= 1 ? stampSize : stampSize * aspect
                let h = aspect >= 1 ? stampSize / aspect : stampSize
                let previewRect = NSRect(
                    x: previewPt.x - w / 2, y: previewPt.y - h / 2, width: w, height: h)
                context.saveGraphicsState()
                applyCanvasTransform(to: context)
                img.draw(
                    in: previewRect, from: .zero, operation: .sourceOver, fraction: 0.5,
                    respectFlipped: true, hints: nil)
                context.restoreGraphicsState()
            }

            // Toolbars — reposition only when selection/layout changes (not every draw).
            // In editor mode toolbars have autoresizingMask, so they only need repositioning
            // on explicit layout changes (handled by rebuildToolbarLayout).
            // In overlay mode the selection rect moves, so we must reposition here.
            if showToolbars && state == .selected && !isScrollCapturing {
                if !isEditorMode { repositionToolbars() }
                // Toolbars are real NSView subviews (ToolbarStripView) — no custom drawing needed.
                // Tool options row handled by ToolOptionsRowView (real NSView subview)

                // Color picker popover

                // Beautify style picker popover

                // Stroke width picker popover

                // Loupe size picker

                // Redact type picker

            }

            // Radial color wheel
            if colorWheel.isVisible {
                colorWheel.draw(currentColor: currentColor)
            }
        }

        // Overlay error message
        if let errorMsg = overlayErrorMessage {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor.white,
            ]
            let str = errorMsg as NSString
            let strSize = str.size(withAttributes: attrs)
            let padding: CGFloat = 12
            let msgW = strSize.width + padding * 2
            let msgH = strSize.height + padding
            let msgX = bounds.midX - msgW / 2
            let msgY = bounds.maxY - msgH - 40
            let msgRect = NSRect(x: msgX, y: msgY, width: msgW, height: msgH)
            NSColor(red: 0.8, green: 0.2, blue: 0.2, alpha: 0.9).setFill()
            NSBezierPath(roundedRect: msgRect, xRadius: 8, yRadius: 8).fill()
            str.draw(
                at: NSPoint(x: msgRect.minX + padding, y: msgRect.minY + padding / 2),
                withAttributes: attrs)
        }

        // Instant tooltip for hovered toolbar button
        drawHoveredTooltip()

    }

    private static let helperFont = NSFont.systemFont(ofSize: 13, weight: .medium)

    private static let helperSmallFont = NSFont.systemFont(ofSize: 12, weight: .regular)

    private static let helperSmallBoldFont = NSFont.systemFont(ofSize: 12, weight: .semibold)

    private static let helperDimColor = NSColor.white.withAlphaComponent(0.7)

    private func drawIdleHelperText() {
        let line1: String
        let line3state: String
        switch snapMode {
        case .window:
            line1 = "Click a window  ·  Drag for custom area  ·  F for full screen"
            line3state = "WINDOW"
        case .element:
            line1 = "Click an element  ·  Drag for custom area  ·  F for full screen"
            line3state = "ELEMENT"
        case .off:
            line1 = "Drag to select  ·  Click for full screen"
            line3state = "OFF"
        }
        let line3prefix = "Snap mode: "
        let line3suffix = "  (Tab to switch)"

        let snapColor = snapMode == .off ? NSColor.systemOrange : NSColor.systemGreen

        let attrs1: [NSAttributedString.Key: Any] = [.font: Self.helperFont, .foregroundColor: NSColor.white]
        let attrs2prefix: [NSAttributedString.Key: Any] = [
            .font: Self.helperSmallFont, .foregroundColor: Self.helperDimColor,
        ]
        let attrs2state: [NSAttributedString.Key: Any] = [
            .font: Self.helperSmallBoldFont, .foregroundColor: snapColor,
        ]
        let attrs2suffix: [NSAttributedString.Key: Any] = [
            .font: Self.helperSmallFont, .foregroundColor: Self.helperDimColor,
        ]

        let size1 = (line1 as NSString).size(withAttributes: attrs1)
        let size2pre = (line3prefix as NSString).size(withAttributes: attrs2prefix)
        let size2state = (line3state as NSString).size(withAttributes: attrs2state)
        let size2suf = (line3suffix as NSString).size(withAttributes: attrs2suffix)
        let size2total = CGSize(
            width: size2pre.width + size2state.width + size2suf.width,
            height: max(size2pre.height, size2state.height, size2suf.height))

        let lineSpacing: CGFloat = 6
        let padding: CGFloat = 14
        let buttonSize = NSSize(width: 34, height: 28)
        let buttonGap: CGFloat = 10
        let showPresetButton = shouldShowPreSelectionPresetButton
        let buttonBlockHeight = showPresetButton ? buttonSize.height + buttonGap : 0
        let totalTextHeight = size1.height + lineSpacing + size2total.height + buttonBlockHeight
        let bgWidth = max(size1.width, size2total.width, showPresetButton ? buttonSize.width : 0) + padding * 2
        let bgHeight = totalTextHeight + padding * 2

        let bgX = bounds.midX - bgWidth / 2
        let bgY = bounds.midY - bgHeight / 2
        let bgRect = NSRect(x: bgX, y: bgY, width: bgWidth, height: bgHeight)

        NSColor.black.withAlphaComponent(0.65).setFill()
        NSBezierPath(roundedRect: bgRect, xRadius: 8, yRadius: 8).fill()

        if showPresetButton {
            let buttonFrame = NSRect(
                x: bounds.midX - buttonSize.width / 2,
                y: bgY + padding,
                width: buttonSize.width,
                height: buttonSize.height)
            showPreSelectionPresetButton(frame: buttonFrame)
        } else {
            hidePreSelectionPresetButton()
        }

        let textY2 = bgY + padding + buttonBlockHeight
        let textY1 = textY2 + size2total.height + lineSpacing

        (line1 as NSString).draw(
            at: NSPoint(x: bounds.midX - size1.width / 2, y: textY1), withAttributes: attrs1)

        // Draw snap line as three segments with different colors
        let line2startX = bounds.midX - size2total.width / 2
        let line2Y = textY2 + (size2total.height - size2pre.height) / 2
        (line3prefix as NSString).draw(
            at: NSPoint(x: line2startX, y: line2Y), withAttributes: attrs2prefix)
        (line3state as NSString).draw(
            at: NSPoint(x: line2startX + size2pre.width, y: line2Y), withAttributes: attrs2state)
        (line3suffix as NSString).draw(
            at: NSPoint(x: line2startX + size2pre.width + size2state.width, y: line2Y),
            withAttributes: attrs2suffix)
    }

    private static let helperTextAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 12, weight: .medium),
        .foregroundColor: NSColor.white,
    ]

    private func drawSelectingHelperText() {
        guard selectionRect.width >= 1, selectionRect.height >= 1 else { return }

        let text = autoQuickSaveMode
            ? "Hold Space to move. Release to finish"
            : "Hold Space to move. Release to annotate and edit"
        let attrs = Self.helperTextAttrs
        let size = (text as NSString).size(withAttributes: attrs)
        let padding: CGFloat = 10
        let bgWidth = size.width + padding * 2
        let bgHeight = size.height + padding

        // Position below the selection, centered
        var labelX = selectionRect.midX - bgWidth / 2
        var labelY = selectionRect.minY - bgHeight - 8

        // If below screen, put above
        if labelY < bounds.minY + 4 {
            labelY = selectionRect.maxY + 8
        }
        // Clamp horizontal
        labelX = max(bounds.minX + 4, min(labelX, bounds.maxX - bgWidth - 4))

        let bgRect = NSRect(x: labelX, y: labelY, width: bgWidth, height: bgHeight)
        NSColor.black.withAlphaComponent(0.65).setFill()
        NSBezierPath(roundedRect: bgRect, xRadius: 6, yRadius: 6).fill()

        (text as NSString).draw(
            at: NSPoint(x: bgRect.minX + padding, y: bgRect.minY + padding / 2),
            withAttributes: attrs)
    }

    private static let sizeLabelFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)

    private func drawResizeHandles() {
        for (_, rect) in allHandleRects() {
            ToolbarLayout.handleColor.setFill()
            NSBezierPath(ovalIn: rect).fill()
        }
    }

    /// Compare two colors by RGB components (ignoring minor floating point differences)    /// Convert NSColor to hex string like "FF3B30"
    func colorToHexString(_ color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return "000000" }
        let r = Int(round(rgb.redComponent * 255))
        let g = Int(round(rgb.greenComponent * 255))
        let b = Int(round(rgb.blueComponent * 255))
        return String(format: "%02X%02X%02X", r, g, b)
    }

    // MARK: - Color Sampler Preview

    /// Sample the visible canvas color at `canvasPoint` and draw a live preview.
    private func drawColorSamplerPreview(at canvasPoint: NSPoint) {
        guard let result = sampleCanvasColor(at: canvasPoint) else { return }
        let sampledColor = result.color
        let hexStr = result.hex

        guard let context = NSGraphicsContext.current else { return }
        context.saveGraphicsState()

        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        let copyFont = NSFont.systemFont(ofSize: 10, weight: .regular)
        let hexAttrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.white,
        ]
        let copyAttrs: [NSAttributedString.Key: Any] = [
            .font: copyFont, .foregroundColor: NSColor.white.withAlphaComponent(0.5),
        ]

        let hexSize = (hexStr as NSString).size(withAttributes: hexAttrs)
        let copyText = "Right-click to copy"
        let copySize = (copyText as NSString).size(withAttributes: copyAttrs)

        let swatchSize: CGFloat = 16
        let padding: CGFloat = 8
        let gap: CGFloat = 6
        let labelW = padding + swatchSize + gap + max(hexSize.width, copySize.width) + padding
        let labelH = padding + hexSize.height + 2 + copySize.height + padding

        let labelX = canvasPoint.x + 16
        let labelY = canvasPoint.y - labelH - 8
        let labelRect = NSRect(x: labelX, y: labelY, width: labelW, height: labelH)

        // Background pill
        NSColor.black.withAlphaComponent(0.85).setFill()
        NSBezierPath(roundedRect: labelRect, xRadius: 6, yRadius: 6).fill()

        // Color swatch
        let swatchRect = NSRect(
            x: labelRect.minX + padding,
            y: labelRect.midY - swatchSize / 2,
            width: swatchSize, height: swatchSize)
        sampledColor.setFill()
        NSBezierPath(roundedRect: swatchRect, xRadius: 3, yRadius: 3).fill()
        NSColor.white.withAlphaComponent(0.4).setStroke()
        let swatchBorder = NSBezierPath(roundedRect: swatchRect, xRadius: 3, yRadius: 3)
        swatchBorder.lineWidth = 0.5
        swatchBorder.stroke()

        // Hex text + copy hint
        let textX = swatchRect.maxX + gap
        (hexStr as NSString).draw(
            at: NSPoint(x: textX, y: labelRect.maxY - padding - hexSize.height),
            withAttributes: hexAttrs)
        (copyText as NSString).draw(
            at: NSPoint(x: textX, y: labelRect.minY + padding), withAttributes: copyAttrs)

        context.restoreGraphicsState()
    }

    /// Sample the rendered canvas without transient UI chrome. Committed annotations
    /// are included, while selection handles, toolbars, and this preview are not.
    func sampleCanvasColor(at canvasPoint: NSPoint) -> (
        color: NSColor, hex: String
    )? {
        guard let image = compositedImage() ?? screenshotImage else { return nil }
        return sampleColor(from: image, at: canvasPoint)
    }

    /// Sample a pixel color from an image at the given canvas-space point.
    /// Returns (NSColor for display, hex string with raw sRGB values matching what other tools report).
    private func sampleColor(from image: NSImage, at canvasPoint: NSPoint) -> (
        color: NSColor, hex: String
    )? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let imgSize = image.size
        let drawRect = captureDrawRect

        let px = (canvasPoint.x - drawRect.origin.x) * imgSize.width / drawRect.width
        let py = (canvasPoint.y - drawRect.origin.y) * imgSize.height / drawRect.height
        guard px >= 0, py >= 0, px < imgSize.width, py < imgSize.height else { return nil }

        // Map to CGImage pixel coordinates.
        let scaleX = CGFloat(cgImage.width) / imgSize.width
        let scaleY = CGFloat(cgImage.height) / imgSize.height
        let cgX = Int(px * scaleX)
        let cgY = Int(CGFloat(cgImage.height) - 1 - py * scaleY)  // flip Y for CGImage (top-left origin)
        guard cgX >= 0, cgX < cgImage.width, cgY >= 0, cgY < cgImage.height else { return nil }

        // Render the single pixel into a known-format 1×1 sRGB bitmap to get correct raw values.
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        guard
            let ctx = CGContext(
                data: nil, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4,
                space: srgb,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(
            cgImage,
            in: CGRect(
                x: -CGFloat(cgX), y: -(CGFloat(cgImage.height) - 1 - CGFloat(cgY)),
                width: CGFloat(cgImage.width), height: CGFloat(cgImage.height)))
        guard let data = ctx.data else { return nil }
        let ptr = data.assumingMemoryBound(to: UInt8.self)
        let a = CGFloat(ptr[3]) / 255
        guard a > 0 else { return nil }
        // Undo premultiplication
        let r = UInt8(min(255, CGFloat(ptr[0]) / a))
        let g = UInt8(min(255, CGFloat(ptr[1]) / a))
        let b = UInt8(min(255, CGFloat(ptr[2]) / a))

        let hex = String(format: "#%02X%02X%02X", r, g, b)
        let color = NSColor(
            srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
        return (color, hex)
    }

    // MARK: - Crop and drawing cursor previews

    private func drawCropPreview() {
        let dimColor = NSColor.black.withAlphaComponent(0.4)
        dimColor.setFill()
        NSBezierPath(
            rect: NSRect(
                x: selectionRect.minX, y: cropDragRect.maxY,
                width: selectionRect.width, height: selectionRect.maxY - cropDragRect.maxY)
        ).fill()
        NSBezierPath(
            rect: NSRect(
                x: selectionRect.minX, y: selectionRect.minY,
                width: selectionRect.width, height: cropDragRect.minY - selectionRect.minY)
        ).fill()
        NSBezierPath(
            rect: NSRect(
                x: selectionRect.minX, y: cropDragRect.minY,
                width: cropDragRect.minX - selectionRect.minX, height: cropDragRect.height)
        ).fill()
        NSBezierPath(
            rect: NSRect(
                x: cropDragRect.maxX, y: cropDragRect.minY,
                width: selectionRect.maxX - cropDragRect.maxX, height: cropDragRect.height)
        ).fill()
    }

    /// Half-extent of the drawing cursor preview (used for dirty rect invalidation).
    var drawingCursorRadius: CGFloat {
        if currentTool == .marker {
            if smartMarkerEnabled {
                // Smart marker pill: height is the dominant dimension
                let h = smartMarkerLineHeight ?? (currentMarkerSize * 6)
                return h / 2
            }
            return (currentMarkerSize * 6) / 2
        } else {
            return max(currentStrokeWidth / 2, 2)
        }
    }

    private func drawDrawingCursorPreview(at center: NSPoint) {
        if currentTool == .marker && smartMarkerEnabled {
            // Smart marker: vertical pill that scales to text line height
            let h = smartMarkerLineHeight ?? (currentMarkerSize * 6)
            let w: CGFloat = min(h * 0.55, 14)
            let pillRect = NSRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h)
            let pill = NSBezierPath(roundedRect: pillRect, xRadius: w / 2, yRadius: w / 2)
            currentColor.withAlphaComponent(0.45).setFill()
            pill.fill()
            currentColor.withAlphaComponent(0.8).setStroke()
            pill.lineWidth = 1.0
            pill.stroke()
        } else if currentTool == .marker {
            // Normal marker: circle at marker stroke size
            let radius = drawingCursorRadius
            let circleRect = NSRect(
                x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            let path = NSBezierPath(ovalIn: circleRect)
            currentColor.withAlphaComponent(0.35).setFill()
            path.fill()
            currentColor.withAlphaComponent(0.7).setStroke()
            path.lineWidth = 1.0
            path.stroke()
        } else {
            // Pencil: solid dot at stroke width (fixed size — don't scale by pressure
            // to avoid distracting size ripple while moving the cursor)
            let radius = max(drawingCursorRadius, 0.5)
            let circleRect = NSRect(
                x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            let path = NSBezierPath(ovalIn: circleRect)
            annotationColor.setFill()
            path.fill()
            let border = NSBezierPath(ovalIn: circleRect.insetBy(dx: -0.5, dy: -0.5))
            border.lineWidth = 1.0
            NSColor.white.withAlphaComponent(0.6).setStroke()
            border.stroke()
            let inner = NSBezierPath(ovalIn: circleRect.insetBy(dx: 0.5, dy: 0.5))
            inner.lineWidth = 0.5
            NSColor.black.withAlphaComponent(0.3).setStroke()
            inner.stroke()
        }
    }

    // MARK: - Loupe Preview

    private func drawLoupePreview(at center: NSPoint) {
        guard let screenshot = screenshotImage, let context = NSGraphicsContext.current else {
            return
        }
        // Build a throwaway loupe annotation with the SAME settings used on commit
        // and render it through the real drawLoupe path, so the cursor-follow
        // preview matches the placed loupe exactly (outline color + thickness).
        let size = currentLoupeSize
        let preview = Annotation(
            tool: .loupe,
            startPoint: NSPoint(x: center.x - size / 2, y: center.y - size / 2),
            endPoint: NSPoint(x: center.x + size / 2, y: center.y + size / 2),
            color: currentColor,
            strokeWidth: size)
        preview.loupeMagnification = currentLoupeMagnification
        preview.outlineColor = currentLoupeOutlineColor
        preview.loupeOutlineEnabled = currentLoupeOutlineEnabled
        preview.sourceImage = screenshot
        preview.sourceImageBounds = captureDrawRect
        preview.bakeLoupe()

        context.saveGraphicsState()
        context.cgContext.setAlpha(0.75)
        preview.draw(in: context)
        context.restoreGraphicsState()
    }
}
