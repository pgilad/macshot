import Cocoa

/// Mouse events: selection, annotation dragging and the right-click color wheel.
extension OverlayView {

    // MARK: - Long press

    /// The pointer stayed down on an annotation with the pencil or marker:
    /// select it and start dragging it instead of drawing.
    func handleLongPress(at point: NSPoint) {
        longPressTriggered = true
        longPressTimer = nil
        // Select the annotation under the long-press point
        if let clicked = annotations.reversed().first(where: { $0.isMovable && $0.hitTest(point: point) }) {
            shiftClickPendingDeselect = nil
            if NSEvent.modifierFlags.contains(.control) {
                if isSelected(clicked) {
                    shiftClickPendingDeselect = clicked
                } else {
                    selectedAnnotations.append(clicked)
                }
            } else if !isSelected(clicked) {
                selectedAnnotation = clicked
            }
            isDraggingAnnotation = true
            didMoveAnnotation = false
            annotationDragStart = point
            // Build cache of non-selected annotations for fast drag rendering
            cachedAnnotationLayerExcludingSelected = buildAnnotationLayer(excluding: Set(selectedAnnotations.map { ObjectIdentifier($0) }))
            // Cancel any in-progress pencil stroke
            currentAnnotation = nil
            NSCursor.closedHand.set()
            needsDisplay = true
        }
    }

    // MARK: - Handle hit testing

    func allHandleRects() -> [(ResizeHandle, NSRect)] {
        let r = selectionRect
        let s = handleSize
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

    private func hitTestHandle(at point: NSPoint) -> ResizeHandle {
        // Use the same hit area as resizeHandleCursor so cursor and click zones match
        let hitPad: CGFloat = 2  // handle rect is already handleSize; expand by 2 to match cursor zone
        // Check corner handles first (they take priority over edges)
        for (handle, rect) in allHandleRects() {
            switch handle {
            case .topLeft, .topRight, .bottomLeft, .bottomRight:
                if rect.insetBy(dx: -hitPad, dy: -hitPad).contains(point) {
                    return handle
                }
            default:
                break
            }
        }

        // Check full edges/borders (not just the handle dots)
        let edgeThickness: CGFloat = 6  // match resizeHandleCursor's edgeT
        let r = selectionRect
        // Top edge
        if NSRect(x: r.minX, y: r.maxY - edgeThickness / 2, width: r.width, height: edgeThickness)
            .contains(point)
        {
            return .top
        }
        // Bottom edge
        if NSRect(x: r.minX, y: r.minY - edgeThickness / 2, width: r.width, height: edgeThickness)
            .contains(point)
        {
            return .bottom
        }
        // Left edge
        if NSRect(x: r.minX - edgeThickness / 2, y: r.minY, width: edgeThickness, height: r.height)
            .contains(point)
        {
            return .left
        }
        // Right edge
        if NSRect(x: r.maxX - edgeThickness / 2, y: r.minY, width: edgeThickness, height: r.height)
            .contains(point)
        {
            return .right
        }

        return .none
    }

    private func handleRectsForRect(_ r: NSRect) -> [(ResizeHandle, NSRect)] {
        let s = handleSize
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

    func hitTestRemoteHandle(at point: NSPoint) -> ResizeHandle {
        let r = remoteSelectionRect
        guard r.width >= 1, r.height >= 1 else { return .none }
        let hitPad: CGFloat = 2
        for (handle, rect) in handleRectsForRect(r) {
            switch handle {
            case .topLeft, .topRight, .bottomLeft, .bottomRight:
                if rect.insetBy(dx: -hitPad, dy: -hitPad).contains(point) { return handle }
            default: break
            }
        }
        let edgeThickness: CGFloat = 6
        if NSRect(x: r.minX, y: r.maxY - edgeThickness / 2, width: r.width, height: edgeThickness).contains(point) { return .top }
        if NSRect(x: r.minX, y: r.minY - edgeThickness / 2, width: r.width, height: edgeThickness).contains(point) { return .bottom }
        if NSRect(x: r.minX - edgeThickness / 2, y: r.minY, width: edgeThickness, height: r.height).contains(point) { return .left }
        if NSRect(x: r.maxX - edgeThickness / 2, y: r.minY, width: edgeThickness, height: r.height).contains(point) { return .right }
        return .none
    }

    func drawRemoteResizeHandles() {
        for (_, rect) in handleRectsForRect(remoteSelectionRect) {
            ToolbarLayout.handleColor.setFill()
            NSBezierPath(ovalIn: rect).fill()
        }
    }

    /// Returns the anchor point (fixed corner) for a given resize handle on a rect.
    private func anchorForHandle(_ handle: ResizeHandle, in r: NSRect) -> NSPoint {
        switch handle {
        case .topLeft:     return NSPoint(x: r.maxX, y: r.minY)
        case .topRight:    return NSPoint(x: r.minX, y: r.minY)
        case .bottomLeft:  return NSPoint(x: r.maxX, y: r.maxY)
        case .bottomRight: return NSPoint(x: r.minX, y: r.maxY)
        case .top:         return NSPoint(x: r.midX, y: r.minY)
        case .bottom:      return NSPoint(x: r.midX, y: r.maxY)
        case .left:        return NSPoint(x: r.maxX, y: r.midY)
        case .right:       return NSPoint(x: r.minX, y: r.midY)
        case .none, .move:  return .zero
        }
    }

    // MARK: - Mouse Events

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        requestBoundarySnapIndexIfNeeded()
        justDismissedTextEditor = false  // reset per click; set below if we commit one

        // Anchored selection commit: a left-click while the right-click-
        // anchored tracker is live finalizes the selection and returns to
        // the standard flow. Do this BEFORE any other mouseDown handling so
        // we don't accidentally restart the selection from the click point.
        if isAnchoredSelecting {
            updateSelectionRect(to: point, shiftHeld: event.modifierFlags.contains(.shift), modifiers: event.modifierFlags)
            commitAnchoredSelection()
            return
        }

        // Update pressure for tablet/Sidecar (0.0 for non-tablet events → treat as 1.0)
        let p = event.pressure
        #if PRESSURE_EMULATION
        // Debug: simulate pressure from mouse speed. Slow = heavy (1.0), fast = light (0.2).
        // Uses deltaX/deltaY from the event to compute instantaneous speed.
        let speed = hypot(event.deltaX, event.deltaY)
        let simulated = max(0.2, min(1.0, 1.0 - speed / 40.0))
        currentPressure = simulated
        #else
        currentPressure = p > 0 ? CGFloat(p) : 1.0
        #endif

        // Auto-measure: click to commit the preview annotation
        if autoMeasureKeyHeld, let preview = autoMeasurePreview {
            annotations.append(preview)
            undoStack.append(.added(preview))
            redoStack.removeAll()
            autoMeasurePreview = nil
            cachedCompositedImage = nil
            // Recompute a new preview at the current position
            updateAutoMeasurePreview()
            return
        }

        // Note: toolbar strips and options row are routed by hitTest() — they never reach here
        if preSelectionPresetButton?.isHidden == false && preSelectionPresetButtonRect.contains(point) {
            return
        }

        // Control-click = right-click for color sampler (supports BetterTouchTool and other tools
        // that simulate right-click via control-click instead of rightMouseDown)
        if event.modifierFlags.contains(.control) && state == .selected
            && currentTool == .colorSampler
        {
            if let result = sampleCanvasColor(at: viewToCanvas(point)) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result.hex, forType: .string)
                showOverlayError(String(format: "Copied %@", result.hex))
                needsDisplay = true
            }
            return
        }

        // Control-click on line/arrow: add anchor point (same as right-click)
        if event.modifierFlags.contains(.control) && state == .selected {
            if let ann = selectedAnnotation,
                ann.tool == .arrow || ann.tool == .line || ann.tool == .measure
            {
                let canvasPoint = viewToCanvas(point)
                if ann.hitTest(point: canvasPoint) {
                    addAnchorPoint(to: ann, at: canvasPoint)
                    cachedCompositedImage = nil
                    needsDisplay = true
                    return
                }
            }
        }

        // Editor top bar button clicks
        if handleTopChromeClick(at: point) {
            return
        }

        if state == .selected
            && isDoubleClickToCopyEnabled
            && textEditor.isEditing
            && handleDoubleClickToCopy(event: event, at: point)
        {
            return
        }

        let isTextEditing = textEditView != nil

        // Check text box resize handles when editing
        if isTextEditing && showToolbars {
            // Check text box resize handles
            if let sv = textEditor.scrollView {
                let hs: CGFloat = 10  // hit area
                let f = sv.frame
                let handles: [(ResizeHandle, NSRect)] = [
                    (
                        .bottomLeft,
                        NSRect(x: f.minX - hs / 2, y: f.minY - hs / 2, width: hs, height: hs)
                    ),
                    (
                        .bottomRight,
                        NSRect(x: f.maxX - hs / 2, y: f.minY - hs / 2, width: hs, height: hs)
                    ),
                    (
                        .topLeft,
                        NSRect(x: f.minX - hs / 2, y: f.maxY - hs / 2, width: hs, height: hs)
                    ),
                    (
                        .topRight,
                        NSRect(x: f.maxX - hs / 2, y: f.maxY - hs / 2, width: hs, height: hs)
                    ),
                    (
                        .bottom,
                        NSRect(x: f.midX - hs / 2, y: f.minY - hs / 2, width: hs, height: hs)
                    ),
                    (.top, NSRect(x: f.midX - hs / 2, y: f.maxY - hs / 2, width: hs, height: hs)),
                    (.left, NSRect(x: f.minX - hs / 2, y: f.midY - hs / 2, width: hs, height: hs)),
                    (.right, NSRect(x: f.maxX - hs / 2, y: f.midY - hs / 2, width: hs, height: hs)),
                ]
                for (handle, rect) in handles {
                    if rect.contains(point) {
                        isResizingTextBox = true
                        textBoxResizeHandle = handle
                        textBoxResizeStart = point
                        textBoxOrigFrame = f
                        return
                    }
                }
            }
            // Clicking on the text editor itself — don't commit
            if let sv = textEditor.scrollView, sv.frame.contains(point) {
                return
            }
        }

        // Don't commit text if clicking on text formatting controls in the options row
        let isTextFormattingClick =
            textEditView != nil && currentTool == .text
            && ((toolOptionsRowView?.frame.contains(point) ?? false))
        // A click that dismisses an open text editor should NOT also place a new
        // text box where it landed — remember that we just committed one so the
        // text-tool dispatch (startAnnotation) skips creating a new field.
        justDismissedTextEditor = textEditor.isEditing && !isTextFormattingClick
        if !isTextFormattingClick {
            commitTextFieldIfNeeded()
        }

        // Double-click to copy: when the setting is on, two fast clicks inside the
        // selection confirm the capture. Annotations the first click added (and any
        // in-progress second-click annotation) are rewound first via the undo stack
        // so the copied image looks like nothing was drawn during the double-click.
        if state == .selected
            && isDoubleClickToCopyEnabled
            && handleDoubleClickToCopy(event: event, at: point)
        {
            return
        }

        switch state {
        case .idle:
            // Check remote selection handles for cross-screen resize
            if remoteSelectionRect.width >= 1 && remoteSelectionRect.height >= 1 {
                let remoteHandle = hitTestRemoteHandle(at: point)
                if remoteHandle != .none {
                    isResizingRemoteSelection = true
                    remoteResizeHandle = remoteHandle
                    remoteResizeAnchor = anchorForHandle(remoteHandle, in: remoteSelectionFullRect)
                    return
                }
                return
            }
            // Always start a drag — snap is resolved in mouseUp if no real drag occurred
            selectionStart = point
            selectionRect = NSRect(origin: point, size: .zero)
            state = .selecting
            overlayDelegate?.overlayViewDidBeginSelection()
            needsDisplay = true

        case .selected:
            // Sticky color wheel: click to pick a color
            if colorWheel.isVisible && colorWheel.isSticky {
                colorWheel.updateHover(at: point)
                if colorWheel.hoveredColor != nil {
                    currentColor = colorWheel.hoveredColor!
                    applyColorToTextIfEditing()
                    applyColorToSelectedAnnotation()
                    rebuildToolbarLayout()
                }
                colorWheel.dismiss()
                needsDisplay = true
                return
            }

            // Resolution box is a real interactive subview — clicks inside it are
            // handled by the view itself (don't intercept here).
            if resolutionBoxRect != .zero && resolutionBoxRect.contains(point) {
                return
            }

            // Check handles (disabled in editor)
            if shouldAllowSelectionResize() {
                let handle = hitTestHandle(at: point)
                if handle != .none {
                    isResizingSelection = true
                    selectionIsWindowSnap = false
                    snappedWindowID = nil
                    snappedWindowImage = nil
                    resizeHandle = handle
                    return
                }
            }

            // Crop tool drag (use canvas coords so it aligns with the image)
            if currentTool == .crop && pointIsInSelection(point) {
                isCropDragging = true
                cropDragStart = viewToCanvas(point)
                cropDragRect = .zero
                needsDisplay = true
                return
            }

            // Color sampler works anywhere on the screenshot, not just inside selection
            if currentTool == .colorSampler {
                let canvasPoint = viewToCanvas(point)
                startAnnotation(at: canvasPoint)
                return
            }

            // Start annotation (convert to canvas space for zoom).
            // Require the click to be inside the selection rectangle.
            if currentTool != .crop && pointIsInSelection(point) {
                let canvasPoint = viewToCanvas(point)
                startAnnotation(at: canvasPoint)
                return
            }

            // Outside the selection — historically this reset everything to
            // start a new selection, but accidental clicks outside an
            // established selection were destroying in-progress annotation
            // work (#154). Treat outside clicks as a no-op once we have a
            // committed selection; ESC still cancels deliberately.
            return

        case .selecting:
            break
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        // Cancel long-press timer if the user moved more than 3px (they're drawing, not selecting)
        if longPressTimer != nil {
            let dx = point.x - longPressPoint.x
            let dy = point.y - longPressPoint.y
            if dx * dx + dy * dy > 9 {
                longPressTimer?.invalidate()
                longPressTimer = nil
            }
        }

        // If long-press already triggered selection, handle as annotation drag
        if longPressTriggered && isDraggingAnnotation {
            // Fall through to the annotation drag handling below
        }

        // Remote selection resize (cross-screen)
        if isResizingRemoteSelection {
            let anchor = remoteResizeAnchor
            let fullRect = remoteSelectionFullRect
            var newRect = NSRect(
                x: min(anchor.x, point.x), y: min(anchor.y, point.y),
                width: abs(point.x - anchor.x), height: abs(point.y - anchor.y))
            // For edge handles, preserve the dimension that shouldn't change
            switch remoteResizeHandle {
            case .top, .bottom:
                newRect.origin.x = fullRect.origin.x
                newRect.size.width = fullRect.width
            case .left, .right:
                newRect.origin.y = fullRect.origin.y
                newRect.size.height = fullRect.height
            default: break
            }
            // Update full rect and clip for local display
            remoteSelectionFullRect = newRect
            let screenBounds = NSRect(origin: .zero, size: bounds.size)
            let clipped = newRect.intersection(screenBounds)
            remoteSelectionRect = clipped.isEmpty ? .zero : clipped
            // Update primary + other screens
            overlayDelegate?.overlayViewRemoteSelectionDidChange(newRect)
            needsDisplay = true
            return
        }

        // Crop drag update (in canvas coords)
        if isCropDragging {
            let canvasPt = viewToCanvas(point)
            let clampedPoint = NSPoint(
                x: max(selectionRect.minX, min(canvasPt.x, selectionRect.maxX)),
                y: max(selectionRect.minY, min(canvasPt.y, selectionRect.maxY))
            )
            let origin = NSPoint(
                x: min(cropDragStart.x, clampedPoint.x), y: min(cropDragStart.y, clampedPoint.y))
            cropDragRect = NSRect(
                origin: origin,
                size: NSSize(
                    width: abs(clampedPoint.x - cropDragStart.x),
                    height: abs(clampedPoint.y - cropDragStart.y)))
            needsDisplay = true
            return
        }

        // Handle text box resize
        if isResizingTextBox, let sv = textEditor.scrollView, let tv = textEditView {
            let dx = point.x - textBoxResizeStart.x
            let dy = point.y - textBoxResizeStart.y
            let orig = textBoxOrigFrame
            var newFrame = orig
            let minW: CGFloat = 60
            let minH: CGFloat = max(28, textEditor.fontSize + 12)

            switch textBoxResizeHandle {
            case .right: newFrame.size.width = max(minW, orig.width + dx)
            case .left:
                newFrame.origin.x = min(orig.maxX - minW, orig.minX + dx)
                newFrame.size.width = orig.maxX - newFrame.minX
            case .top: newFrame.size.height = max(minH, orig.height + dy)
            case .bottom:
                let newMinY = min(orig.maxY - minH, orig.minY + dy)
                newFrame.origin.y = newMinY
                newFrame.size.height = orig.maxY - newMinY
            case .topRight:
                newFrame.size.width = max(minW, orig.width + dx)
                newFrame.size.height = max(minH, orig.height + dy)
            case .topLeft:
                newFrame.origin.x = min(orig.maxX - minW, orig.minX + dx)
                newFrame.size.width = orig.maxX - newFrame.minX
                newFrame.size.height = max(minH, orig.height + dy)
            case .bottomRight:
                newFrame.size.width = max(minW, orig.width + dx)
                let newMinY = min(orig.maxY - minH, orig.minY + dy)
                newFrame.origin.y = newMinY
                newFrame.size.height = orig.maxY - newMinY
            case .bottomLeft:
                newFrame.origin.x = min(orig.maxX - minW, orig.minX + dx)
                newFrame.size.width = orig.maxX - newFrame.minX
                let newMinY = min(orig.maxY - minH, orig.minY + dy)
                newFrame.origin.y = newMinY
                newFrame.size.height = orig.maxY - newMinY
            default: break
            }

            sv.frame = newFrame
            tv.frame.size = newFrame.size
            tv.textContainer?.containerSize = NSSize(
                width: newFrame.width - tv.textContainerInset.width * 2,
                height: CGFloat.greatestFiniteMagnitude)
            needsDisplay = true
            return
        }

        switch state {
        case .selecting:
            updateSelectionRect(to: point, shiftHeld: event.modifierFlags.contains(.shift), modifiers: event.modifierFlags)

        case .selected:
            // Convert to canvas space for annotation interactions (accounts for zoom)
            let canvasPoint = viewToCanvas(point)
            if isRotatingAnnotation, let annotation = selectedAnnotation {
                let center = NSPoint(
                    x: annotation.boundingRect.midX, y: annotation.boundingRect.midY)
                let currentAngle = atan2(canvasPoint.x - center.x, canvasPoint.y - center.y)
                var newRotation = rotationOriginal - (currentAngle - rotationStartAngle)
                // Shift: snap to 45° steps
                if NSEvent.modifierFlags.contains(.shift) {
                    let step = CGFloat.pi / 4
                    newRotation = (newRotation / step).rounded() * step
                }
                annotation.rotation = newRotation
                needsDisplay = true
                return
            }
            if isResizingAnnotation, let annotation = selectedAnnotation {
                if spaceRepositioning {
                    let dx = canvasPoint.x - spaceRepositionLast.x
                    let dy = canvasPoint.y - spaceRepositionLast.y
                    annotation.move(dx: dx, dy: dy)
                    annotationResizeOrigStart.x += dx
                    annotationResizeOrigStart.y += dy
                    annotationResizeOrigEnd.x += dx
                    annotationResizeOrigEnd.y += dy
                    annotationResizeOrigTextOrigin.x += dx
                    annotationResizeOrigTextOrigin.y += dy
                    annotationResizeOrigControlPoint.x += dx
                    annotationResizeOrigControlPoint.y += dy
                    annotationResizeMouseStart.x += dx
                    annotationResizeMouseStart.y += dy
                    spaceRepositionLast = canvasPoint
                    if annotation.tool == .loupe {
                        annotation.bakedBlurNSImage = nil
                        annotation.bakeLoupe()
                    }
                    if annotation.tool == .pixelate { annotation.bakedBlurNSImage = nil }
                    cachedCompositedImage = nil
                    needsDisplay = true
                    return
                }

                let dx = canvasPoint.x - annotationResizeMouseStart.x
                let dy = canvasPoint.y - annotationResizeMouseStart.y
                let origStart = annotationResizeOrigStart
                let origEnd = annotationResizeOrigEnd

                // Text annotations: resize the text box and re-render textImage
                if annotation.tool == .text {
                    let origRect = NSRect(origin: origStart,
                        size: NSSize(width: origEnd.x - origStart.x, height: origEnd.y - origStart.y))
                    var newRect = origRect
                    let minW: CGFloat = 40
                    // Minimum height must fit the actual rendered line height
                    // (ascent+descent+leading ≈ 1.2–1.3× font size), not just the
                    // point size, or the text clips at the bottom and floats with
                    // a gap at the top. Measure it from the string when available.
                    let textInset: CGFloat = 4
                    let lineHeight: CGFloat
                    if let attrStr = annotation.attributedText, attrStr.length > 0 {
                        lineHeight = ceil(attrStr.boundingRect(
                            with: NSSize(width: CGFloat.greatestFiniteMagnitude,
                                         height: CGFloat.greatestFiniteMagnitude),
                            options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
                    } else {
                        lineHeight = ceil(annotation.fontSize * 1.3)
                    }
                    let minH: CGFloat = max(20, lineHeight + textInset * 2)

                    switch annotationResizeHandle {
                    case .right: newRect.size.width = max(minW, origRect.width + dx)
                    case .left:
                        newRect.origin.x = min(origRect.maxX - minW, origRect.minX + dx)
                        newRect.size.width = origRect.maxX - newRect.minX
                    case .top:
                        newRect.size.height = max(minH, origRect.height + dy)
                    case .bottom:
                        let newMinY = min(origRect.maxY - minH, origRect.minY + dy)
                        newRect.origin.y = newMinY
                        newRect.size.height = origRect.maxY - newMinY
                    case .topRight:
                        newRect.size.width = max(minW, origRect.width + dx)
                        newRect.size.height = max(minH, origRect.height + dy)
                    case .topLeft:
                        newRect.origin.x = min(origRect.maxX - minW, origRect.minX + dx)
                        newRect.size.width = origRect.maxX - newRect.minX
                        newRect.size.height = max(minH, origRect.height + dy)
                    case .bottomRight:
                        newRect.size.width = max(minW, origRect.width + dx)
                        let newMinY = min(origRect.maxY - minH, origRect.minY + dy)
                        newRect.origin.y = newMinY
                        newRect.size.height = origRect.maxY - newMinY
                    case .bottomLeft:
                        newRect.origin.x = min(origRect.maxX - minW, origRect.minX + dx)
                        newRect.size.width = origRect.maxX - newRect.minX
                        let newMinY = min(origRect.maxY - minH, origRect.minY + dy)
                        newRect.origin.y = newMinY
                        newRect.size.height = origRect.maxY - newMinY
                    default: break
                    }

                    annotation.startPoint = newRect.origin
                    annotation.endPoint = NSPoint(x: newRect.maxX, y: newRect.maxY)
                    annotation.textDrawRect = newRect
                    // Re-render textImage at new size through the outline layout
                    // manager so a per-glyph outline stays outside the fill (#257).
                    if let attrStr = annotation.attributedText {
                        annotation.textImage = OutlineTextRenderer.renderImage(
                            attrStr, size: newRect.size, inset: 4)
                    }
                    cachedCompositedImage = nil
                    needsDisplay = true
                    break
                }

                let shiftHeld = event.modifierFlags.contains(.shift)

                if annotation.tool == .number {
                    switch annotationResizeHandle {
                    case .bottomLeft:
                        let pointerWasCollapsed =
                            hypot(origEnd.x - origStart.x, origEnd.y - origStart.y) <= 4
                        annotation.startPoint = canvasPoint
                        if pointerWasCollapsed {
                            annotation.endPoint = canvasPoint
                        }
                    case .topRight:
                        var newTip = canvasPoint
                        if shiftHeld {
                            let dx = canvasPoint.x - annotation.startPoint.x
                            let dy = canvasPoint.y - annotation.startPoint.y
                            let angle = atan2(dy, dx)
                            let snapped = (angle / (.pi / 4)).rounded() * (.pi / 4)
                            let distance = hypot(dx, dy)
                            newTip = NSPoint(
                                x: annotation.startPoint.x + distance * cos(snapped),
                                y: annotation.startPoint.y + distance * sin(snapped))
                        }
                        annotation.endPoint = newTip
                    default:
                        break
                    }
                    cachedCompositedImage = nil
                    needsDisplay = true
                    return
                }

                // Arrow/line/measure: .bottomLeft = startPoint, .topRight = endPoint, others = anchor points
                if annotation.tool == .arrow || annotation.tool == .line
                    || annotation.tool == .measure
                {
                    let newPt = NSPoint(
                        x: annotationResizeOrigControlPoint.x + dx,
                        y: annotationResizeOrigControlPoint.y + dy)
                    switch annotationResizeHandle {
                    case .bottomLeft:
                        var newStart = NSPoint(x: origStart.x + dx, y: origStart.y + dy)
                        if shiftHeld {
                            let anchor = annotation.endPoint
                            let ddx = newStart.x - anchor.x
                            let ddy = newStart.y - anchor.y
                            let angle = atan2(ddy, ddx)
                            let snapped = (angle / (.pi / 4)).rounded() * (.pi / 4)
                            let dist = hypot(ddx, ddy)
                            newStart = NSPoint(
                                x: anchor.x + dist * cos(snapped), y: anchor.y + dist * sin(snapped)
                            )
                        }
                        if annotation.tool == .measure && currentMeasureClampToSelection {
                            newStart = shiftHeld
                                ? newStart.clampedAlongRay(from: annotation.endPoint, in: selectionRect)
                                : newStart.clampedToRect(selectionRect)
                        }
                        annotation.startPoint = newStart
                        if var anchors = annotation.anchorPoints, !anchors.isEmpty {
                            anchors[0] = newStart
                            annotation.anchorPoints = anchors
                        }
                    case .topRight:
                        var newEnd = NSPoint(x: origEnd.x + dx, y: origEnd.y + dy)
                        if shiftHeld {
                            let anchor = annotation.startPoint
                            let ddx = newEnd.x - anchor.x
                            let ddy = newEnd.y - anchor.y
                            let angle = atan2(ddy, ddx)
                            let snapped = (angle / (.pi / 4)).rounded() * (.pi / 4)
                            let dist = hypot(ddx, ddy)
                            newEnd = NSPoint(
                                x: anchor.x + dist * cos(snapped), y: anchor.y + dist * sin(snapped)
                            )
                        }
                        if annotation.tool == .measure && currentMeasureClampToSelection {
                            newEnd = shiftHeld
                                ? newEnd.clampedAlongRay(from: annotation.startPoint, in: selectionRect)
                                : newEnd.clampedToRect(selectionRect)
                        }
                        annotation.endPoint = newEnd
                        if var anchors = annotation.anchorPoints, anchors.count >= 2 {
                            anchors[anchors.count - 1] = newEnd
                            annotation.anchorPoints = anchors
                        }
                    default:
                        // Dragging an anchor point (multi-anchor or legacy controlPoint)
                        if annotationResizeAnchorIndex >= 0, var anchors = annotation.anchorPoints {
                            if annotationResizeAnchorIndex < anchors.count {
                                anchors[annotationResizeAnchorIndex] = newPt
                                annotation.anchorPoints = anchors
                                // Keep start/end in sync
                                annotation.startPoint = anchors.first!
                                annotation.endPoint = anchors.last!
                            }
                        } else {
                            // Legacy single controlPoint
                            annotation.controlPoint = newPt
                        }
                    }
                } else {
                    // Work in bounding-rect space so resize is correct regardless of draw direction
                    let origMinX = min(origStart.x, origEnd.x)
                    let origMaxX = max(origStart.x, origEnd.x)
                    let origMinY = min(origStart.y, origEnd.y)
                    let origMaxY = max(origStart.y, origEnd.y)
                    var newMinX = origMinX
                    var newMaxX = origMaxX
                    var newMinY = origMinY
                    var newMaxY = origMaxY

                    switch annotationResizeHandle {
                    case .topLeft:
                        newMinX = min(origMinX + dx, origMaxX - 10)
                        newMaxY = max(origMaxY + dy, origMinY + 10)
                    case .topRight:
                        newMaxX = max(origMaxX + dx, origMinX + 10)
                        newMaxY = max(origMaxY + dy, origMinY + 10)
                    case .bottomLeft:
                        newMinX = min(origMinX + dx, origMaxX - 10)
                        newMinY = min(origMinY + dy, origMaxY - 10)
                    case .bottomRight:
                        newMaxX = max(origMaxX + dx, origMinX + 10)
                        newMinY = min(origMinY + dy, origMaxY - 10)
                    case .top:
                        newMaxY = max(origMaxY + dy, origMinY + 10)
                    case .bottom:
                        newMinY = min(origMinY + dy, origMaxY - 10)
                    case .left:
                        newMinX = min(origMinX + dx, origMaxX - 10)
                    case .right:
                        newMaxX = max(origMaxX + dx, origMinX + 10)
                    default:
                        break
                    }

                    // Loupe is always circular; shift forces square/circle for other shape corner handles.
                    if annotation.tool == .loupe {
                        let w = newMaxX - newMinX
                        let h = newMaxY - newMinY
                        let side: CGFloat
                        switch annotationResizeHandle {
                        case .left, .right:
                            side = max(40, w)
                        case .top, .bottom:
                            side = max(40, h)
                        default:
                            side = max(40, max(w, h))
                        }
                        let centerX = (origMinX + origMaxX) / 2
                        let centerY = (origMinY + origMaxY) / 2
                        switch annotationResizeHandle {
                        case .topLeft:
                            newMinX = origMaxX - side
                            newMaxX = origMaxX
                            newMinY = origMinY
                            newMaxY = origMinY + side
                        case .topRight:
                            newMinX = origMinX
                            newMaxX = origMinX + side
                            newMinY = origMinY
                            newMaxY = origMinY + side
                        case .bottomLeft:
                            newMinX = origMaxX - side
                            newMaxX = origMaxX
                            newMinY = origMaxY - side
                            newMaxY = origMaxY
                        case .bottomRight:
                            newMinX = origMinX
                            newMaxX = origMinX + side
                            newMinY = origMaxY - side
                            newMaxY = origMaxY
                        case .top:
                            newMinX = centerX - side / 2
                            newMaxX = centerX + side / 2
                            newMinY = origMinY
                            newMaxY = origMinY + side
                        case .bottom:
                            newMinX = centerX - side / 2
                            newMaxX = centerX + side / 2
                            newMinY = origMaxY - side
                            newMaxY = origMaxY
                        case .left:
                            newMinX = origMaxX - side
                            newMaxX = origMaxX
                            newMinY = centerY - side / 2
                            newMaxY = centerY + side / 2
                        case .right:
                            newMinX = origMinX
                            newMaxX = origMinX + side
                            newMinY = centerY - side / 2
                            newMaxY = centerY + side / 2
                        default:
                            break
                        }
                        annotation.strokeWidth = side
                    } else if annotation.tool == .stamp {
                        // Stamps always keep their aspect ratio, whichever handle is dragged.
                        let origW = max(origMaxX - origMinX, 1)
                        let origH = max(origMaxY - origMinY, 1)
                        var scale: CGFloat
                        switch annotationResizeHandle {
                        case .left, .right:
                            scale = (newMaxX - newMinX) / origW
                        case .top, .bottom:
                            scale = (newMaxY - newMinY) / origH
                        default:
                            scale = max((newMaxX - newMinX) / origW, (newMaxY - newMinY) / origH)
                        }
                        scale = max(scale, 10 / min(origW, origH))
                        let w = origW * scale
                        let h = origH * scale
                        let centerX = (origMinX + origMaxX) / 2
                        let centerY = (origMinY + origMaxY) / 2
                        switch annotationResizeHandle {
                        case .topLeft:
                            newMinX = origMaxX - w
                            newMaxX = origMaxX
                            newMinY = origMinY
                            newMaxY = origMinY + h
                        case .topRight:
                            newMinX = origMinX
                            newMaxX = origMinX + w
                            newMinY = origMinY
                            newMaxY = origMinY + h
                        case .bottomLeft:
                            newMinX = origMaxX - w
                            newMaxX = origMaxX
                            newMinY = origMaxY - h
                            newMaxY = origMaxY
                        case .bottomRight:
                            newMinX = origMinX
                            newMaxX = origMinX + w
                            newMinY = origMaxY - h
                            newMaxY = origMaxY
                        case .top:
                            newMinX = centerX - w / 2
                            newMaxX = centerX + w / 2
                            newMinY = origMinY
                            newMaxY = origMinY + h
                        case .bottom:
                            newMinX = centerX - w / 2
                            newMaxX = centerX + w / 2
                            newMinY = origMaxY - h
                            newMaxY = origMaxY
                        case .left:
                            newMinX = origMaxX - w
                            newMaxX = origMaxX
                            newMinY = centerY - h / 2
                            newMaxY = centerY + h / 2
                        case .right:
                            newMinX = origMinX
                            newMaxX = origMinX + w
                            newMinY = centerY - h / 2
                            newMaxY = centerY + h / 2
                        default:
                            break
                        }
                    } else if shiftHeld {
                        let w = newMaxX - newMinX
                        let h = newMaxY - newMinY
                        let side = max(w, h)
                        switch annotationResizeHandle {
                        case .topLeft:
                            newMinX = newMaxX - side
                            newMaxY = newMinY + side
                        case .topRight:
                            newMaxX = newMinX + side
                            newMaxY = newMinY + side
                        case .bottomLeft:
                            newMinX = newMaxX - side
                            newMinY = newMaxY - side
                        case .bottomRight:
                            newMaxX = newMinX + side
                            newMinY = newMaxY - side
                        default: break
                        }
                    }

                    annotation.startPoint = NSPoint(x: newMinX, y: newMinY)
                    annotation.endPoint = NSPoint(x: newMaxX, y: newMaxY)
                    if annotation.tool == .loupe {
                        // Two-circle loupe: resizing the lens keeps the zoom
                        // (magnification) fixed and re-frames the source so it
                        // still outlines exactly what the lens shows.
                        annotation.syncLoupeSourceToMagnification()
                        annotation.bakedBlurNSImage = nil
                        annotation.bakeLoupe()
                    }
                }
                if annotation.tool == .pixelate { annotation.bakedBlurNSImage = nil }
                cachedCompositedImage = nil
                needsDisplay = true
            } else if isLassoSelecting {
                // Update lasso marquee rectangle
                let x = min(lassoStart.x, canvasPoint.x)
                let y = min(lassoStart.y, canvasPoint.y)
                let w = abs(canvasPoint.x - lassoStart.x)
                let h = abs(canvasPoint.y - lassoStart.y)
                lassoRect = NSRect(x: x, y: y, width: w, height: h)
                needsDisplay = true
            } else if isResizingLoupeSource, let loupe = selectedAnnotation, loupe.tool == .loupe {
                // Resize the source circle by dragging its handle → changes zoom.
                // magnification = lensSize / sourceSize; the source is re-framed to
                // match via syncLoupeSourceToMagnification on the next draw/bake.
                let cx = loupeSourceDragOrig.midX, cy = loupeSourceDragOrig.midY
                let newR = max(6, hypot(canvasPoint.x - cx, canvasPoint.y - cy))
                let lensSize = loupe.loupeLensSquareRect.width
                let mag = max(1.1, min(12, lensSize / (newR * 2)))
                loupe.loupeMagnification = mag
                let newSize = lensSize / mag
                loupe.loupeSourceRect = NSRect(x: cx - newSize / 2, y: cy - newSize / 2,
                                               width: newSize, height: newSize)
                loupe.bakedBlurNSImage = nil
                loupe.bakeLoupe()
                didMoveAnnotation = true
                cachedCompositedImage = nil
                needsDisplay = true
            } else if isDraggingLoupeSource, let loupe = selectedAnnotation, loupe.tool == .loupe {
                // Move the rooted source circle independently; the lens stays put
                // and the connecting line re-adjusts. Magnification is kept, so
                // the source size is unchanged.
                let dx = canvasPoint.x - loupeSourceDragStart.x
                let dy = canvasPoint.y - loupeSourceDragStart.y
                loupe.loupeSourceRect = loupeSourceDragOrig.offsetBy(dx: dx, dy: dy)
                loupe.bakedBlurNSImage = nil
                loupe.bakeLoupe()
                didMoveAnnotation = true
                cachedCompositedImage = nil
                needsDisplay = true
            } else if isDraggingAnnotation, !selectedAnnotations.isEmpty {
                // Snapshot the pre-move state once, on the first actual move, so
                // the drag can be recorded as an undo entry on mouseUp (which also
                // makes "move existing shape" register as an edit).
                if !didMoveAnnotation {
                    preMoveSnapshots = selectedAnnotations.map { ($0, $0.clone()) }
                }
                let rawDx = canvasPoint.x - annotationDragStart.x
                let rawDy = canvasPoint.y - annotationDragStart.y
                // For single selection, apply snap; for multi, just move raw
                let finalDx: CGFloat
                let finalDy: CGFloat
                if selectedAnnotations.count == 1, let annotation = selectedAnnotations.first {
                    let movedRect = annotation.boundingRect.offsetBy(dx: rawDx, dy: rawDy)
                    let snap = snapRectDelta(rect: movedRect, excluding: annotation)
                    finalDx = rawDx + snap.dx
                    finalDy = rawDy + snap.dy
                    annotationDragStart = NSPoint(
                        x: canvasPoint.x + snap.dx, y: canvasPoint.y + snap.dy)
                } else {
                    finalDx = rawDx
                    finalDy = rawDy
                    annotationDragStart = canvasPoint
                }
                for annotation in selectedAnnotations {
                    annotation.move(dx: finalDx, dy: finalDy)
                    if annotation.tool == .loupe {
                        annotation.bakedBlurNSImage = nil
                        annotation.bakeLoupe()
                    }
                }
                didMoveAnnotation = true
                cachedCompositedImage = nil
                needsDisplay = true
            } else if isDraggingSelection {
                var moved = selectionRect
                moved.origin = NSPoint(x: point.x - dragOffset.x, y: point.y - dragOffset.y)
                selectionRect = boundarySnappedMovedRect(moved, modifiers: event.modifierFlags)
                updateResolutionBox()
                needsDisplay = true
            } else if isResizingSelection {
                if spaceRepositioning {
                    let dx = point.x - spaceRepositionLast.x
                    let dy = point.y - spaceRepositionLast.y
                    var moved = selectionRect
                    moved.origin.x += dx
                    moved.origin.y += dy
                    selectionRect = boundarySnappedMovedRect(moved, modifiers: event.modifierFlags)
                    spaceRepositionLast = point
                } else {
                    resizeSelection(to: point, modifiers: event.modifierFlags)
                }
                overlayDelegate?.overlayViewSelectionDidChange(selectionRect)
                updateResolutionBox()
                needsDisplay = true
            } else if currentAnnotation != nil {
                if spaceRepositioning {
                    // Space held: reposition the whole shape
                    let dx = canvasPoint.x - spaceRepositionLast.x
                    let dy = canvasPoint.y - spaceRepositionLast.y
                    currentAnnotation!.startPoint.x += dx
                    currentAnnotation!.startPoint.y += dy
                    currentAnnotation!.endPoint.x += dx
                    currentAnnotation!.endPoint.y += dy
                    if let points = currentAnnotation!.points {
                        currentAnnotation!.points = points.map {
                            NSPoint(x: $0.x + dx, y: $0.y + dy)
                        }
                    }
                    spaceRepositionLast = canvasPoint
                } else {
                    let p = event.pressure
                    #if PRESSURE_EMULATION
                    let speed = hypot(event.deltaX, event.deltaY)
                    currentPressure = max(0.2, min(1.0, 1.0 - speed / 40.0))
                    #else
                    currentPressure = p > 0 ? CGFloat(p) : 1.0
                    #endif
                    updateAnnotation(
                        at: canvasPoint, shiftHeld: event.modifierFlags.contains(.shift))
                }
                lastDragPoint = canvasPoint
                needsDisplay = true
            }

        default:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        spaceRepositioning = false

        // Any drag that used boundary snap is ending — clear its guide lines.
        boundarySnapGuideX = nil
        boundarySnapGuideY = nil

        // Clean up long-press timer
        longPressTimer?.invalidate()
        longPressTimer = nil
        longPressTriggered = false

        // Finish remote selection resize — final sync + transfer focus to the primary
        if isResizingRemoteSelection {
            isResizingRemoteSelection = false
            remoteResizeHandle = .none
            overlayDelegate?.overlayViewRemoteSelectionDidFinish(remoteSelectionFullRect)
            return
        }

        // Crop commit
        if isCropDragging {
            isCropDragging = false
            let rect = cropDragRect
            cropDragRect = .zero
            if rect.width > 4 && rect.height > 4 {
                commitCrop(viewRect: rect)
            }
            needsDisplay = true
            return
        }

        if isResizingTextBox {
            isResizingTextBox = false
            return
        }
        if isRotatingAnnotation {
            isRotatingAnnotation = false
            commitAnnotationManipulationUndo()
            cachedAnnotationLayerExcludingSelected = nil
            cachedAnnotationLayer = nil
            NSCursor.openHand.set()
            needsDisplay = true
            return
        }
        if isDraggingLoupeSource || isResizingLoupeSource {
            let wasResize = isResizingLoupeSource
            isDraggingLoupeSource = false
            isResizingLoupeSource = false
            commitAnnotationManipulationUndo()
            cachedAnnotationLayerExcludingSelected = nil
            cachedAnnotationLayer = nil
            if let ann = selectedAnnotation, ann.tool == .loupe {
                ann.bakedBlurNSImage = nil
                ann.bakeLoupe()
                if wasResize {
                    // Reflect the new zoom in the options row slider/label.
                    toolOptionsRowView?.rebuild(forAnnotation: ann)
                }
            }
            cachedCompositedImage = nil
            NSCursor.openHand.set()
            needsDisplay = true
            return
        }
        if isResizingAnnotation {
            isResizingAnnotation = false
            commitAnnotationManipulationUndo()
            cachedAnnotationLayerExcludingSelected = nil
            cachedAnnotationLayer = nil
            annotationResizeHandle = .none
            if let ann = selectedAnnotation {
                if ann.tool == .loupe { ann.bakeLoupe() }
                if ann.tool == .pixelate { ann.bakedBlurNSImage = nil; ann.bakePixelate() }
                if ann.tool == .stamp && !ann.isCaptureStamp {
                    // Remember the size so the next stamp is placed to match.
                    setActiveStampSize(max(ann.boundingRect.width, ann.boundingRect.height))
                }
                toolOptionsRowView?.rebuild(forAnnotation: ann)
            }
            NSCursor.openHand.set()
            needsDisplay = true
            return
        }
        lastDragPoint = nil
        switch state {
        case .selecting:
            finishSelection()

        case .selected:
            if isLassoSelecting {
                isLassoSelecting = false
                // Select all annotations whose bounding rect intersects the lasso
                if lassoRect.width > 2 && lassoRect.height > 2 {
                    let selected = annotations.filter { $0.isMovable && $0.boundingRect.intersects(lassoRect) }
                    if !selected.isEmpty {
                        selectedAnnotations = selected
                    }
                }
                lassoRect = .zero
                needsDisplay = true
            } else if isDraggingAnnotation {
                // Deferred ctrl+click deselect: only remove the annotation if
                // the user didn't drag (i.e. it was a click, not a move).
                if let pending = shiftClickPendingDeselect {
                    shiftClickPendingDeselect = nil
                    if !didMoveAnnotation {
                        if let idx = selectedAnnotations.firstIndex(where: { $0 === pending }) {
                            selectedAnnotations.remove(at: idx)
                        }
                    }
                }
                // Record the move as an undo entry (and an edit) if anything
                // actually moved. Each dragged annotation gets its own entry.
                commitAnnotationManipulationUndo()
                isDraggingAnnotation = false
                didMoveAnnotation = false
                cachedAnnotationLayerExcludingSelected = nil
                cachedAnnotationLayer = nil
                snapGuideX = nil
                snapGuideY = nil
                NSCursor.openHand.set()
                for ann in selectedAnnotations {
                    if ann.tool == .loupe { ann.bakeLoupe() }
                    if ann.tool == .pixelate { ann.bakedBlurNSImage = nil; ann.bakePixelate() }
                }
                // Auto-expand canvas if annotation was dragged outside bounds (editor mode)
                expandCanvasToFitAnnotations()
                needsDisplay = true
            } else if isDraggingSelection {
                isDraggingSelection = false
                needsDisplay = true
            } else if isResizingSelection {
                isResizingSelection = false
                resizeHandle = .none
                boundarySnapGuideX = nil
                boundarySnapGuideY = nil
                if let win = window {
                    updateCursorForPoint(convert(win.mouseLocationOutsideOfEventStream, from: nil))
                }
                needsDisplay = true
            } else if let annotation = currentAnnotation {
                finishAnnotation(annotation)
            }

        default:
            break
        }
    }

    /// Handle the "double-click to copy" feature. Called from `mouseDown` when the setting
    /// is enabled and `state == .selected`. Returns true when the event was consumed.
    ///
    /// On the first click we snapshot the undo-stack depth. On the second click (clickCount >= 2)
    /// inside the selection we rewind the stack to that snapshot — removing any annotation the
    /// first click finished — cancel any in-progress drawing, then trigger confirm.
    private func handleDoubleClickToCopy(event: NSEvent, at point: NSPoint) -> Bool {
        // A double-click landing on an existing text annotation should never
        // "copy" — it means "edit that text" (issue #287). Return false so the
        // downstream edit paths (text-tool inline / select-tool handler) run.
        // For tools that don't route into text editing (e.g. crop, colorSampler)
        // this simply suppresses the accidental copy, which is the safe outcome.
        //
        // Only while NOT already editing: when a text field is open, the
        // in-editor double-click-to-copy path (deadline logic below) owns this
        // gesture, and another committed text box happening to sit under the
        // click must not hijack it.
        if !textEditor.isEditing {
            let hitText = annotations.reversed().contains(where: {
                $0.tool == .text && $0.hitTest(point: point)
            }) || (selectedAnnotation?.tool == .text && selectedAnnotation?.hitTest(point: point) == true)
            if hitText {
                textToolDoubleClickCopyDeadline = 0
                return false
            }
        }

        if textEditor.isEditing {
            guard hasPendingTextToolDoubleClickCopy(for: event) else { return false }
        }

        if event.clickCount >= 2 {
            if textEditor.isEditing {
                commitTextFieldIfNeeded()
                doubleClickUndoBaseline = undoStack.count
            }
            guard pointIsInSelection(point) else {
                // Outside selection: no drawing occurred — just confirm.
                doubleClickUndoBaseline = nil
                textToolDoubleClickCopyDeadline = 0
                overlayDelegate?.overlayViewDidConfirm()
                return true
            }
            // Cancel any in-progress annotation from this second click.
            currentAnnotation = nil
            // Rewind the undo stack to the baseline captured on the first click,
            // popping the annotation(s) the first click finished.
            if let baseline = doubleClickUndoBaseline {
                while undoStack.count > baseline { undo() }
            }
            doubleClickUndoBaseline = nil
            textToolDoubleClickCopyDeadline = 0
            // Clear caches so the confirm renders without the popped annotations.
            cachedCompositedImage = nil
            cachedAnnotationLayer = nil
            overlayDelegate?.overlayViewDidConfirm()
            return true
        }

        // clickCount == 1: record the baseline so the next click (if it doubles up)
        // knows how far to rewind. Only record when the click could plausibly create
        // an annotation (inside selection, drawing tool). Otherwise leave it nil so
        // a double-click outside still works without an unrelated baseline.
        if pointIsInSelection(point) {
            doubleClickUndoBaseline = undoStack.count
            let hitText = annotations.reversed().contains(where: {
                $0.tool == .text && $0.hitTest(point: point)
            })
            textToolDoubleClickCopyDeadline =
                currentTool == .text && !hitText
                ? event.timestamp + NSEvent.doubleClickInterval + 0.05
                : 0
        } else {
            doubleClickUndoBaseline = nil
            textToolDoubleClickCopyDeadline = 0
        }
        return false
    }

    private var isDoubleClickToCopyEnabled: Bool {
        Preferences.doubleClickToCopy
    }

    private func hasPendingTextToolDoubleClickCopy(for event: NSEvent) -> Bool {
        event.type == .leftMouseDown
            && event.clickCount >= 2
            && event.timestamp <= textToolDoubleClickCopyDeadline
    }

    func shouldRouteTextEditorDoubleClickToCopy(event: NSEvent, at point: NSPoint) -> Bool {
        guard state == .selected,
              isDoubleClickToCopyEnabled,
              hasPendingTextToolDoubleClickCopy(for: event),
              let sv = textEditor.scrollView,
              sv.frame.contains(point)
        else { return false }
        return true
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        // Text Fill/Outline color picking handled by ToolOptionsRowView

        // Toolbar right-clicks handled by ToolbarButtonView.onRightClick → handleToolbarButtonRightClick

        // Anchored selection toggle: right-click in idle starts no-hold
        // tracking from that point; a second right-click while tracking
        // commits. Left-click during tracking also commits (handled in
        // mouseDown). ESC cancels. Locked in editor mode.
        if isAnchoredSelecting {
            updateSelectionRect(to: point, shiftHeld: event.modifierFlags.contains(.shift), modifiers: event.modifierFlags)
            commitAnchoredSelection()
            return
        }
        if state == .idle && shouldAllowNewSelection() {
            selectionStart = point
            selectionRect = NSRect(origin: point, size: .zero)
            state = .selecting
            isAnchoredSelecting = true
            overlayDelegate?.overlayViewDidBeginSelection()
            needsDisplay = true
            return
        }

        // Right-click on a line/arrow/measure: add anchor point.
        // Auto-selects the annotation if it isn't selected yet.
        if state == .selected {
            let canvasPoint = viewToCanvas(point)
            // Check already-selected annotation first
            if let ann = selectedAnnotation,
                (ann.tool == .arrow || ann.tool == .line || ann.tool == .measure),
                ann.hitTest(point: canvasPoint)
            {
                addAnchorPoint(to: ann, at: canvasPoint)
                cachedCompositedImage = nil
                needsDisplay = true
                return
            }
            // Check any unselected line/arrow/measure under the cursor
            if let ann = annotations.reversed().first(where: {
                ($0.tool == .arrow || $0.tool == .line || $0.tool == .measure)
                && $0.hitTest(point: canvasPoint)
            }) {
                selectedAnnotation = ann
                addAnchorPoint(to: ann, at: canvasPoint)
                cachedCompositedImage = nil
                needsDisplay = true
                return
            }
        }

        if state == .selected && currentTool == .colorSampler {
            // Right-click with color sampler: copy hex to clipboard
            if let result = sampleCanvasColor(at: viewToCanvas(point)) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result.hex, forType: .string)
                showOverlayError(String(format: "Copied %@", result.hex))
                needsDisplay = true
            }
            return
        }

        if state == .selected && pointIsInSelection(point) {
            // Show radial color wheel
            colorWheel.show(at: point)

            colorWheel.hoveredIndex = -1
            needsDisplay = true
            return
        }
    }

    override func rightMouseDragged(with event: NSEvent) {
        if colorWheel.isVisible {
            let point = convert(event.locationInWindow, from: nil)
            colorWheel.updateHover(at: point)
            needsDisplay = true
            return
        }
    }

    override func rightMouseUp(with event: NSEvent) {
        if colorWheel.isVisible && !colorWheel.isSticky {
            if colorWheel.hoveredColor != nil {
                // User dragged to a color — pick it and dismiss
                currentColor = colorWheel.hoveredColor!
                applyColorToTextIfEditing()
                applyColorToSelectedAnnotation()
                rebuildToolbarLayout()
                colorWheel.dismiss()
            } else {
                // User released without dragging — enter sticky mode
                // so they can click a color (iPad/Sidecar/accessibility)
                colorWheel.isSticky = true
            }
            needsDisplay = true
            return
        }
    }

    // MARK: - Middle Mouse (toggle move mode)

    override func otherMouseDown(with event: NSEvent) {
        // Middle mouse: no action (previously toggled select tool)
    }
}
