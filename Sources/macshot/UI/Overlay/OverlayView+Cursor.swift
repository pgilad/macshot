import Cocoa

/// Cursor updates and hit testing for the overlay chrome and selection handles.
extension OverlayView {

    // MARK: - Cursor

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        requestBoundarySnapIndexIfNeeded()

        // Anchored selection (right-click in idle → track cursor without
        // holding a button). Shares all modifier behaviour with drag-based
        // selection via `updateAnchoredSelection` so Shift-constrain and
        // the snap fallback in mouseUp still apply when the user commits.
        if isAnchoredSelecting {
            updateAnchoredSelection(to: point, event: event)
            updateCursorForPoint(point)
            return
        }

        if isKeyboardMoveSelectionActive {
            updateKeyboardMoveSelection(to: point, modifiers: event.modifierFlags)
            updateCursorForPoint(point)
            return
        }

        // Sticky color wheel: track hover with mouse movement
        if colorWheel.isVisible && colorWheel.isSticky {
            colorWheel.updateHover(at: point)
            needsDisplay = true
            return
        }

        // Stamp cursor preview — track in view coords (same as annotations)
        if currentTool == .stamp && currentStampImage != nil && state == .selected
            && !showBeautifyInOptionsRow {
            let canvasStampPt = viewToCanvas(point)
            let hoveringStamp = annotations.reversed().contains {
                $0.tool == .stamp && $0.hitTest(point: canvasStampPt)
            }
            let previewPoint: NSPoint? = hoveringStamp ? nil : canvasStampPt
            let shouldMovePreview: Bool
            if let previewPoint, let stampPreviewPoint {
                shouldMovePreview = hypot(
                    previewPoint.x - stampPreviewPoint.x,
                    previewPoint.y - stampPreviewPoint.y) > 0.5
            } else {
                shouldMovePreview = previewPoint != stampPreviewPoint
            }
            if shouldMovePreview {
                let oldPt = stampPreviewPoint ?? .zero
                stampPreviewPoint = previewPoint
                // Radius must cover the drawn preview (centered, max side = currentStampSize)
                invalidateCursorPreview(
                    oldCanvas: oldPt, newCanvas: previewPoint ?? .zero,
                    radius: max(40, currentStampSize / 2))
            }
        } else if stampPreviewPoint != nil {
            let oldPt = stampPreviewPoint!
            stampPreviewPoint = nil
            invalidateCursorPreview(
                oldCanvas: oldPt, newCanvas: oldPt, radius: max(40, currentStampSize / 2))
        }

        // Update cursor on every mouse move
        updateCursorForPoint(point)

        // Auto-measure: update preview as cursor moves while key is held
        if autoMeasureKeyHeld {
            updateAutoMeasurePreview()
        }

        // Snap highlight for the hovered window or accessibility element.
        // CGWindowListCopyWindowInfo is expensive — run it on a background thread,
        // skipping new queries while one is already in flight.
        // Delay window snap queries briefly after overlay appears so the overlay
        // renders without competing with CGWindowListCopyWindowInfo for the window server
        if windowSnapCooldown { return }
        if state == .idle && snapMode != .off
            && !(remoteSelectionRect.width >= 1 && remoteSelectionRect.height >= 1) {
            guard
                let screenPoint = window.map({
                    NSPoint(x: $0.frame.origin.x + point.x, y: $0.frame.origin.y + point.y)
                })
            else { return }
            querySnapTarget(at: screenPoint)
        }

        // Track cursor for loupe live preview (use canvas space for zoom correctness)
        if state == .selected && currentTool == .loupe && !showBeautifyInOptionsRow {
            let canvasPoint = viewToCanvas(point)
            let hoveringLoupe = annotations.reversed().contains {
                $0.tool == .loupe && $0.hitTest(point: canvasPoint)
            }
            let newPoint = hoveringLoupe ? NSPoint.zero : canvasPoint
            if newPoint != loupeCursorPoint {
                let oldPt = loupeCursorPoint
                loupeCursorPoint = newPoint
                let r = currentLoupeSize / 2 + 4
                invalidateCursorPreview(oldCanvas: oldPt, newCanvas: newPoint, radius: r)
            }
        }

        // Track cursor for pencil/marker dot preview (canvas space so it scales with zoom)
        let showDrawingCursor = state == .selected
            && (currentTool == .pencil || currentTool == .marker)
        if showDrawingCursor {
            let canvasPoint = viewToCanvas(point)
            if canvasPoint != drawingCursorPoint {
                let oldPt = drawingCursorPoint
                let oldR = drawingCursorRadius
                drawingCursorPoint = canvasPoint
                // Smart marker: query line height at cursor and update preview size
                if currentTool == .marker && smartMarkerEnabled {
                    if let handler = toolHandlers[.marker] as? MarkerToolHandler {
                        handler.ensureOCRCache(canvas: self)
                        smartMarkerLineHeight = handler.textLineHeight(at: canvasPoint, canvas: self)
                    }
                }
                // Invalidate both old and new positions with the larger radius
                let newR = drawingCursorRadius
                let r = max(oldR, newR) + 4
                invalidateCursorPreview(oldCanvas: oldPt, newCanvas: canvasPoint, radius: r)
            }
        } else if drawingCursorPoint != .zero {
            let oldPt = drawingCursorPoint
            let r = drawingCursorRadius + 4
            drawingCursorPoint = .zero
            smartMarkerLineHeight = nil
            invalidateCursorPreview(oldCanvas: oldPt, newCanvas: oldPt, radius: r)
        }

        // Track cursor for color sampler tool (canvas space)
        if state == .selected && currentTool == .colorSampler {
            let canvasPoint = viewToCanvas(point)
            if canvasPoint != colorSamplerPoint {
                let oldPt = colorSamplerPoint
                colorSamplerPoint = canvasPoint
                invalidateCursorPreview(oldCanvas: oldPt, newCanvas: canvasPoint, radius: 200)
            }
        } else if colorSamplerPoint != .zero {
            let oldPt = colorSamplerPoint
            colorSamplerPoint = .zero
            colorSamplerBitmap = nil
            invalidateCursorPreview(oldCanvas: oldPt, newCanvas: oldPt, radius: 200)
        }

        // Toolbar hover handled by ToolbarButtonView (real NSView subviews)
    }

    // Custom cursors
    /// Transparent 1x1 cursor used to hide the system cursor while the drawing dot preview is shown.
    private static let invisibleCursor: NSCursor = {
        let img = NSImage(size: NSSize(width: 1, height: 1))
        return NSCursor(image: img, hotSpot: .zero)
    }()

    // Diagonal resize cursors (macOS doesn't provide these publicly)
    private static let nwseCursor: NSCursor = {
        // Top-left <-> Bottom-right (backslash direction)
        if let cursor = NSCursor.perform(
            NSSelectorFromString("_windowResizeNorthWestSouthEastCursor"))?.takeUnretainedValue()
            as? NSCursor {
            return cursor
        }
        return .crosshair
    }()

    private static let neswCursor: NSCursor = {
        // Top-right <-> Bottom-left (slash direction)
        if let cursor = NSCursor.perform(
            NSSelectorFromString("_windowResizeNorthEastSouthWestCursor"))?.takeUnretainedValue()
            as? NSCursor {
            return cursor
        }
        return .crosshair
    }()

    override func cursorUpdate(with event: NSEvent) {
        // Intentionally empty — cursor management is handled imperatively in mouseMoved
        // via updateCursorForPoint(). Overriding prevents AppKit's default cursorUpdate
        // from resetting our custom cursors.
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if !isEditorMode && !isScrollCapturing && (state == .idle || state == .selecting) {
            addCursorRect(bounds, cursor: .crosshair)
            if preSelectionPresetButton?.isHidden == false && preSelectionPresetButtonRect.width > 1 {
                addCursorRect(preSelectionPresetButtonRect, cursor: .arrow)
            }
        }
    }

    /// Imperative cursor management. Called from mouseMoved and a 30fps timer.
    /// Simplified: arrow for chrome, resize cursors for handles, tool cursor for canvas.
    func updateCursorForPoint(_ point: NSPoint) {
        // Arrow cursor when mouse is over an open popover
        if PopoverHelper.isMouseInsidePopover {
            NSCursor.arrow.set()
            return
        }

        // Over the resolution box: let its own cursor rects (I-beam over fields,
        // arrow over the presets button) decide — don't override here.
        if resolutionBoxRect != .zero && resolutionBoxRect.contains(point) {
            return
        }
        if preSelectionPresetButton?.isHidden == false && preSelectionPresetButtonRect.contains(point) {
            NSCursor.arrow.set()
            return
        }

        // Non-interactive states — simple cursors
        if textEditView != nil {
            NSCursor.arrow.set()
            return
        }
        if state == .idle || state == .selecting {
            // Show resize cursor for remote selection handles
            if state == .idle && remoteSelectionRect.width >= 1 && remoteSelectionRect.height >= 1 {
                let remoteHandle = hitTestRemoteHandle(at: point)
                if remoteHandle != .none {
                    cursorForHandle(remoteHandle).set()
                    return
                }
            }
            NSCursor.crosshair.set()
            return
        }
        guard state == .selected else { return }

        // Chrome areas — arrow
        if isPointOnChrome(point) {
            NSCursor.arrow.set()
            return
        }

        // Selection resize handles (overlay only, not during scroll capture)
        if !isEditorMode && !isScrollCapturing, let handleCursor = resizeHandleCursor(at: point) {
            handleCursor.set()
            return
        }

        // The color sampler always acts on the rendered canvas, including over
        // existing annotations. Do not let annotation hover hit-testing replace
        // its crosshair with manipulation cursors such as the open hand.
        if currentTool == .colorSampler {
            NSCursor.crosshair.set()
            return
        }

        // Annotation control cursors (resize handles, rotation, delete, body)
        if state == .selected && !isDraggingAnnotation && !isResizingAnnotation && !isRotatingAnnotation {
            // Check selected annotation's handles first
            if selectedAnnotation != nil {
                // Unrotate point for handle hit test
                let handlePoint: NSPoint
                if let ann = selectedAnnotation, ann.rotation != 0 && ann.supportsRotation {
                    let center = NSPoint(x: ann.boundingRect.midX, y: ann.boundingRect.midY)
                    let cos_r = cos(-ann.rotation)
                    let sin_r = sin(-ann.rotation)
                    let dx = point.x - center.x
                    let dy = point.y - center.y
                    handlePoint = NSPoint(x: center.x + dx * cos_r - dy * sin_r,
                                          y: center.y + dx * sin_r + dy * cos_r)
                } else {
                    handlePoint = point
                }

                // Resize handles — directional cursors for shapes, open hand for line/arrow points
                let isShapeTool = [AnnotationTool.rectangle, .filledRectangle, .ellipse, .text,
                                   .pixelate, .stamp, .loupe, .highlight].contains(selectedAnnotation?.tool)
                for (_, handleEntry) in annotationResizeHandleRects.enumerated() {
                    let (handle, rect) = handleEntry
                    if rect.insetBy(dx: -4, dy: -4).contains(handlePoint) {
                        if isShapeTool {
                            switch handle {
                            case .topLeft, .bottomRight: Self.nwseCursor.set()
                            case .topRight, .bottomLeft: Self.neswCursor.set()
                            case .top, .bottom: NSCursor.resizeUpDown.set()
                            case .left, .right: NSCursor.resizeLeftRight.set()
                            default: NSCursor.openHand.set()
                            }
                        } else {
                            NSCursor.openHand.set()
                        }
                        return
                    }
                }

                // Rotation handle
                if annotationRotateHandleRect != .zero
                    && annotationRotateHandleRect.insetBy(dx: -6, dy: -6).contains(point) {
                    // Use a rotation-style cursor (crosshair works as a generic grab indicator)
                    NSCursor.openHand.set()
                    return
                }

                // Delete button
                if annotationDeleteButtonRect.contains(point) {
                    NSCursor.arrow.set()
                    return
                }

                // Edit button
                if annotationEditButtonRect != .zero && annotationEditButtonRect.contains(point) {
                    NSCursor.arrow.set()
                    return
                }
            }

            // Multi-select delete button
            if selectedAnnotations.count > 1 && multiSelectDeleteButtonRect.contains(point) {
                NSCursor.arrow.set()
                return
            }

            // Body hover — open hand (skip for pencil/marker where click always draws)
            if currentTool != .pencil && currentTool != .marker {
                let canvasPoint = viewToCanvas(point)
                if let selected = selectedAnnotation, selected.hitTest(point: canvasPoint) {
                    NSCursor.openHand.set()
                    return
                }
                if annotations.reversed().contains(where: { $0.isMovable && $0.hitTest(point: canvasPoint) }) {
                    NSCursor.openHand.set()
                    return
                }
            }
        }

        // Tool cursor — use handler's state-aware cursor if available, else legacy switch
        // Pencil/marker: hide system cursor when dot preview is active (the dot IS the cursor)
        if (currentTool == .pencil || currentTool == .marker)
            && state == .selected && drawingCursorPoint != .zero {
            Self.invisibleCursor.set()
        } else if let handler = toolHandlers[currentTool], let cursor = handler.cursorForCanvas(self) {
            cursor.set()
        } else {
            switch currentTool {
            case .select: NSCursor.arrow.set()
            default: NSCursor.crosshair.set()
            }
        }
    }

    /// Re-evaluate the cursor for the current tool (e.g. after toggling smart marker).
    /// Find the EditorTopBarView in the chrome parent (for updating zoom label from keyboard shortcuts).
    func findTopBar() -> EditorTopBarView? {
        chromeParentView?.subviews.compactMap { $0 as? EditorTopBarView }.first
    }

    func updateCursorForCurrentTool() {
        guard let win = window else { return }
        let point = convert(win.mouseLocationOutsideOfEventStream, from: nil)
        updateCursorForPoint(point)
    }

    // MARK: - Hit Testing

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Let real NSView subviews (toolbar strips, options row) handle their own events.
        // This prevents our mouseDown override from intercepting slider drags etc.
        // In editor mode the strips live in chromeParentView (a sibling container), not in
        // this view — AppKit's normal hit testing on the container handles them. Routing them
        // here would compare coordinates in different spaces and cause false matches.
        if !isEditorMode {
            let localPoint = convert(point, from: superview)
            if let strip = bottomStripView, !strip.isHidden, strip.frame.contains(localPoint) {
                return strip.hitTest(convert(point, to: strip.superview))
            }
            if let strip = rightStripView, !strip.isHidden, strip.frame.contains(localPoint) {
                return strip.hitTest(convert(point, to: strip.superview))
            }
            if let row = toolOptionsRowView, !row.isHidden, row.frame.contains(localPoint) {
                return row.hitTest(convert(point, to: row.superview))
            }
        }
        if let event = NSApp.currentEvent, shouldRouteTextEditorDoubleClickToCopy(event: event, at: point) {
            return self
        }
        let result = super.hitTest(point)
        if shouldIgnoreInactiveChromeHit(result) {
            return self
        }
        return result
    }

    /// AppKit's default hitTest can still resolve a mouse-down to a hidden or
    /// inactive toolbar/options subview (the chrome views are pooled and reused
    /// across capture sessions, not destroyed). When that happens the event
    /// never reaches OverlayView.mouseDown, so a new selection drag started over
    /// the *previous* position of now-hidden chrome silently fails. Redirect
    /// those hits back to self. Visible chrome is unaffected. (PR #219)
    private func shouldIgnoreInactiveChromeHit(_ view: NSView?) -> Bool {
        guard !isEditorMode, let view, view !== self else { return false }

        var current: NSView? = view
        var hasHiddenAncestor = false
        while let candidate = current, candidate !== self {
            hasHiddenAncestor = hasHiddenAncestor || candidate.isHidden
            if isOverlayChromeRoot(candidate) {
                return !showToolbars || hasHiddenAncestor
            }
            current = candidate.superview
        }
        return false
    }

    private func isOverlayChromeRoot(_ view: NSView) -> Bool {
        if let bottomStripView, view === bottomStripView { return true }
        if let rightStripView, view === rightStripView { return true }
        if let toolOptionsRowView, view === toolOptionsRowView { return true }
        return false
    }

    /// Returns true if the point is over any chrome element (toolbars, options row, popovers, labels).
    private func isPointOnChrome(_ point: NSPoint) -> Bool {
        // In editor mode, strips are in chromeParentView — different coordinate space.
        // Don't check them here; they handle their own hit testing as container subviews.
        if showToolbars && !isEditorMode {
            // Use the shared OVERLAY-space rects, valid in both themes: in normal
            // mode they equal the strip frames; in glass mode the strips live in
            // panels (frame is panel-local), so the rects are the only truth.
            if bottomStripView?.isHidden == false, bottomBarRect.contains(point) { return true }
            if rightStripView?.isHidden == false, rightBarRect.contains(point) { return true }
            if toolOptionsRowView?.isHidden == false, optionsRowRect.width > 1,
               optionsRowRect.contains(point) { return true }
        }
        if updateCursorForChrome(at: point) { return true }
        if resolutionBoxRect != .zero && resolutionBoxRect.contains(point) { return true }
        if preSelectionPresetButton?.isHidden == false && preSelectionPresetButtonRect.contains(point) {
            return true
        }
        return false
    }

    /// Returns the appropriate resize cursor if the point is on a selection handle, nil otherwise.
    private func resizeHandleCursor(at point: NSPoint) -> NSCursor? {
        let r = selectionRect
        let hs = handleSize + 4
        let edgeT: CGFloat = 6
        // Corner handles
        if NSRect(x: r.minX - hs / 2, y: r.maxY - hs / 2, width: hs, height: hs).contains(point)
            || NSRect(x: r.maxX - hs / 2, y: r.minY - hs / 2, width: hs, height: hs).contains(point) {
            return Self.nwseCursor
        }
        if NSRect(x: r.maxX - hs / 2, y: r.maxY - hs / 2, width: hs, height: hs).contains(point)
            || NSRect(x: r.minX - hs / 2, y: r.minY - hs / 2, width: hs, height: hs).contains(point) {
            return Self.neswCursor
        }
        // Edge handles
        if NSRect(x: r.minX + hs / 2, y: r.maxY - edgeT / 2, width: r.width - hs, height: edgeT)
            .contains(point)
            || NSRect(x: r.minX + hs / 2, y: r.minY - edgeT / 2, width: r.width - hs, height: edgeT)
                .contains(point) {
            return .resizeUpDown
        }
        if NSRect(x: r.minX - edgeT / 2, y: r.minY + hs / 2, width: edgeT, height: r.height - hs)
            .contains(point)
            || NSRect(
                x: r.maxX - edgeT / 2, y: r.minY + hs / 2, width: edgeT, height: r.height - hs
            ).contains(point) {
            return .resizeLeftRight
        }
        return nil
    }

    private func cursorForHandle(_ handle: ResizeHandle) -> NSCursor {
        switch handle {
        case .topLeft, .bottomRight: return Self.nwseCursor
        case .topRight, .bottomLeft: return Self.neswCursor
        case .top, .bottom: return .resizeUpDown
        case .left, .right: return .resizeLeftRight
        case .none, .move: return .arrow
        }
    }
}
