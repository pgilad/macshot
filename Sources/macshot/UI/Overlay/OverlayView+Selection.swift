import Cocoa

/// Finishing, resizing and snapping the capture selection.
extension OverlayView {

    // MARK: - Finishing the selection

    func finishSelection() {
        if selectionRect.width > 5 || selectionRect.height > 5 {
            // Real drag — use drawn rect as-is
            state = .selected
            applyPreSelectionLockAfterSelection()
            if !autoOCRMode && !autoQuickSaveMode && !autoScrollCaptureMode && !autoConfirmMode { showToolbars = true }
            overlayDelegate?.overlayViewDidFinishSelection(selectionRect)
        } else if snapMode != .off, let snapRect = hoveredSnapRect, !snapRect.isEmpty {
            // Click (no drag) with snap on — select the hovered target.
            selectionRect = snapRect
            selectionIsWindowSnap = snapMode == .window
            snappedWindowID = selectionIsWindowSnap ? hoveredSnapWindowID : nil
            // Only whole-window snaps use the independent capture that preserves
            // transparent corners. Element snaps are ordinary screen crops.
            if selectionIsWindowSnap, let wid = hoveredSnapWindowID, let screen = window?.screen {
                Task {
                    if let cgImage = await ScreenCaptureManager.captureWindow(windowID: wid, screen: screen) {
                        self.snappedWindowImage = NSImage(cgImage: cgImage,
                            size: NSSize(width: CGFloat(cgImage.width) / screen.backingScaleFactor,
                                         height: CGFloat(cgImage.height) / screen.backingScaleFactor))
                        self.needsDisplay = true
                    }
                }
            }
            state = .selected
            if !autoOCRMode && !autoQuickSaveMode && !autoScrollCaptureMode && !autoConfirmMode { showToolbars = true }
            overlayDelegate?.overlayViewDidFinishSelection(selectionRect)
        } else {
            // Click (no drag), snap off — expand to full screen
            selectionRect = bounds
            state = .selected
            if !autoOCRMode && !autoQuickSaveMode && !autoScrollCaptureMode && !autoConfirmMode { showToolbars = true }
            overlayDelegate?.overlayViewDidFinishSelection(selectionRect)
        }
        hoveredSnapRect = nil
        // Update cursor to match the selected tool (replaces resize cursor from dragging)
        if let win = window {
            let point = convert(win.mouseLocationOutsideOfEventStream, from: nil)
            updateCursorForPoint(point)
        }
        // Auto-trigger OCR if triggered from "Capture OCR & QR"
        if autoOCRMode {
            autoOCRMode = false
            overlayDelegate?.overlayViewDidRequestOCR()
        }
        // Auto-trigger quick save if triggered from "Quick Capture"
        if autoQuickSaveMode {
            autoQuickSaveMode = false
            overlayDelegate?.overlayViewDidRequestQuickSave()
        }
        // Auto-trigger scroll capture if triggered from "Scroll Capture"
        if autoScrollCaptureMode {
            autoScrollCaptureMode = false
            overlayDelegate?.overlayViewDidRequestScrollCapture(rect: selectionRect)
        }
        // Auto-confirm for "Add Capture" — just confirm selection, no save/copy
        if autoConfirmMode {
            autoConfirmMode = false
            overlayDelegate?.overlayViewDidConfirm()
        }
        needsDisplay = true
    }

    private func applyPreSelectionLockAfterSelection() {
        switch activePreSelectionPreset {
        case .ratio(let aspect):
            lockedAspect = aspect > 0 ? aspect : nil
        case .freeform, .resolution:
            lockedAspect = nil
        }
    }

    /// Update `selectionRect` from the anchor at `selectionStart` to the
    /// current cursor point. Honors Shift (constrain to square) and Space
    /// (reposition anchor). Shared between drag-to-select (mouseDragged)
    /// and right-click-anchored select (mouseMoved) so both flows produce
    /// identical geometry.
    func updateSelectionRect(to point: NSPoint, shiftHeld: Bool,
                                     modifiers: NSEvent.ModifierFlags = []) {
        var point = point
        if spaceRepositioning {
            let dx = point.x - spaceRepositionLast.x
            let dy = point.y - spaceRepositionLast.y
            selectionStart.x += dx
            selectionStart.y += dy
            spaceRepositionLast = point
        }

        if case .resolution(let pxW, let pxH) = activePreSelectionPreset {
            selectionRect = fixedPreSelectionRect(centeredAt: point, pxW: pxW, pxH: pxH)
            overlayDelegate?.overlayViewSelectionDidChange(selectionRect)
            needsDisplay = true
            return
        }

        // Boundary snap the MOVING corner (the cursor) to nearby image edges.
        // Skipped for freeform-constrained drags (aspect/shift) so the constraint
        // stays exact, and bypassed with Option. The anchor edge stays put.
        // While repositioning with Space the whole rect translates rigidly, so we
        // snap the WHOLE moved rect below instead of just the cursor corner.
        if !spaceRepositioning, boundarySnapEnabled, !modifiers.contains(.option), let index = boundarySnapIndex,
           activePreSelectionRatio == nil, !shiftHeld {
            point = snapMovingPoint(point, anchor: selectionStart, index: index)
        } else if !spaceRepositioning, boundarySnapGuideX != nil || boundarySnapGuideY != nil {
            boundarySnapGuideX = nil
            boundarySnapGuideY = nil
        }

        let rawW = abs(point.x - selectionStart.x)
        let rawH = abs(point.y - selectionStart.y)
        var w = max(1, rawW)
        var h = max(1, rawH)
        if let aspect = activePreSelectionRatio, aspect > 0 {
            if rawW / max(rawH, 1) > aspect {
                w = max(1, rawH * aspect)
                h = max(1, rawH)
            } else {
                w = max(1, rawW)
                h = max(1, rawW / aspect)
            }
        } else if shiftHeld {
            let side = max(1, min(rawW, rawH))
            w = side
            h = side
        }

        let x = selectionStart.x < point.x ? selectionStart.x : selectionStart.x - w
        let y = selectionStart.y < point.y ? selectionStart.y : selectionStart.y - h
        var rect = NSRect(x: x, y: y, width: w, height: h)
        // Space reposition: the rect is moving rigidly, so snap the whole rect to
        // nearby image edges. The snap is applied only to the displayed rect, NOT
        // baked back into selectionStart — the logical anchor stays unsnapped so
        // the rect releases cleanly once the cursor moves past the snap radius.
        if spaceRepositioning {
            rect = boundarySnappedMovedRect(rect, modifiers: modifiers)
        }
        selectionRect = rect
        overlayDelegate?.overlayViewSelectionDidChange(selectionRect)
        needsDisplay = true
    }

    private func fixedPreSelectionRect(centeredAt point: NSPoint, pxW: Int, pxH: Int) -> NSRect {
        let scale = window?.backingScaleFactor ?? 2.0
        var w = CGFloat(max(1, pxW)) / scale
        var h = CGFloat(max(1, pxH)) / scale

        if w > bounds.width || h > bounds.height {
            let s = min(bounds.width / w, bounds.height / h)
            w *= s
            h *= s
        }

        var x = point.x - w / 2
        var y = point.y - h / 2
        x = max(bounds.minX, min(x, bounds.maxX - w))
        y = max(bounds.minY, min(y, bounds.maxY - h))
        return NSRect(x: x, y: y, width: w, height: h)
    }

    /// mouseMoved entry point when the right-click-anchored mode is active.
    /// Kept separate from the drag path so cross-screen tracking and other
    /// mouseDragged-only features don't get accidentally invoked.
    func updateAnchoredSelection(to point: NSPoint, event: NSEvent) {
        updateSelectionRect(to: point, shiftHeld: event.modifierFlags.contains(.shift), modifiers: event.modifierFlags)
    }

    /// Commit an anchored selection — matches the branch in mouseUp that
    /// fires after a drag-to-select, so the same snap-to-window /
    /// fallback-to-fullscreen logic applies when the user confirms with a
    /// tiny (no-move) rectangle.
    func commitAnchoredSelection() {
        isAnchoredSelecting = false
        if selectionRect.width > 5 || selectionRect.height > 5 {
            state = .selected
            applyPreSelectionLockAfterSelection()
            if !autoOCRMode && !autoQuickSaveMode && !autoScrollCaptureMode && !autoConfirmMode {
                showToolbars = true
            }
            overlayDelegate?.overlayViewDidFinishSelection(selectionRect)
        } else if snapMode != .off, let snapRect = hoveredSnapRect, !snapRect.isEmpty {
            selectionRect = snapRect
            selectionIsWindowSnap = snapMode == .window
            snappedWindowID = selectionIsWindowSnap ? hoveredSnapWindowID : nil
            if selectionIsWindowSnap, let wid = hoveredSnapWindowID, let screen = window?.screen {
                Task {
                    if let cgImage = await ScreenCaptureManager.captureWindow(windowID: wid, screen: screen) {
                        self.snappedWindowImage = NSImage(
                            cgImage: cgImage,
                            size: NSSize(
                                width: CGFloat(cgImage.width) / screen.backingScaleFactor,
                                height: CGFloat(cgImage.height) / screen.backingScaleFactor))
                        self.needsDisplay = true
                    }
                }
            }
            state = .selected
            if !autoOCRMode && !autoQuickSaveMode && !autoScrollCaptureMode && !autoConfirmMode {
                showToolbars = true
            }
            overlayDelegate?.overlayViewDidFinishSelection(selectionRect)
        } else {
            selectionRect = bounds
            state = .selected
            if !autoOCRMode && !autoQuickSaveMode && !autoScrollCaptureMode && !autoConfirmMode {
                showToolbars = true
            }
            overlayDelegate?.overlayViewDidFinishSelection(selectionRect)
        }
        hoveredSnapRect = nil
        if let win = window {
            updateCursorForPoint(convert(win.mouseLocationOutsideOfEventStream, from: nil))
        }
        needsDisplay = true
    }

    /// Cancel anchored-selection mode (ESC). Resets back to idle without
    /// leaving a tiny selection behind.
    func cancelAnchoredSelection() {
        guard isAnchoredSelecting else { return }
        isAnchoredSelecting = false
        selectionRect = .zero
        state = .idle
        overlayDelegate?.overlayViewSelectionDidChange(.zero)
        needsDisplay = true
    }

    // MARK: - Selection Resizing

    func resizeSelection(to point: NSPoint, modifiers: NSEvent.ModifierFlags = []) {
        let minSize: CGFloat = 10
        let r = selectionRect
        var newRect = r

        switch resizeHandle {
        case .topLeft:
            let newX = min(point.x, r.maxX - minSize)
            let newMaxY = max(point.y, r.minY + minSize)
            newRect = NSRect(x: newX, y: r.minY, width: r.maxX - newX, height: newMaxY - r.minY)
        case .topRight:
            let newMaxX = max(point.x, r.minX + minSize)
            let newMaxY = max(point.y, r.minY + minSize)
            newRect = NSRect(
                x: r.minX, y: r.minY, width: newMaxX - r.minX, height: newMaxY - r.minY)
        case .bottomLeft:
            let newX = min(point.x, r.maxX - minSize)
            let newY = min(point.y, r.maxY - minSize)
            newRect = NSRect(x: newX, y: newY, width: r.maxX - newX, height: r.maxY - newY)
        case .bottomRight:
            let newMaxX = max(point.x, r.minX + minSize)
            let newY = min(point.y, r.maxY - minSize)
            newRect = NSRect(x: r.minX, y: newY, width: newMaxX - r.minX, height: r.maxY - newY)
        case .top:
            let newMaxY = max(point.y, r.minY + minSize)
            newRect = NSRect(x: r.minX, y: r.minY, width: r.width, height: newMaxY - r.minY)
        case .bottom:
            let newY = min(point.y, r.maxY - minSize)
            newRect = NSRect(x: r.minX, y: newY, width: r.width, height: r.maxY - newY)
        case .left:
            let newX = min(point.x, r.maxX - minSize)
            newRect = NSRect(x: newX, y: r.minY, width: r.maxX - newX, height: r.height)
        case .right:
            let newMaxX = max(point.x, r.minX + minSize)
            newRect = NSRect(x: r.minX, y: r.minY, width: newMaxX - r.minX, height: r.height)
        default:
            break
        }

        // Boundary snap (before aspect, so the locked ratio is preserved): snap
        // the dragged edge(s) to nearby strong image edges. Option bypasses.
        if boundarySnapEnabled, !modifiers.contains(.option), let index = boundarySnapIndex {
            newRect = applyBoundarySnap(to: newRect, handle: resizeHandle, minSize: minSize, index: index)
        } else if boundarySnapGuideX != nil || boundarySnapGuideY != nil {
            boundarySnapGuideX = nil
            boundarySnapGuideY = nil
        }

        if let aspect = lockedAspect, aspect > 0 {
            newRect = constrainToAspect(newRect, aspect: aspect, handle: resizeHandle, minSize: minSize)
        }

        selectionRect = newRect
    }

    /// Snap the dragged edge(s) of `rect` to nearby strong image boundaries.
    /// Each handle drives one or two edges; only those are snapped. Updates the
    /// snap-guide feedback coordinates.
    private func applyBoundarySnap(to rect: NSRect, handle: ResizeHandle, minSize: CGFloat,
                                   index: BoundarySnapIndex) -> NSRect {
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        var guideX: CGFloat?
        var guideY: CGFloat?
        let radius = boundarySnapRadiusPoints

        // Which edges does this handle move?
        let movesLeft = handle == .left || handle == .topLeft || handle == .bottomLeft
        let movesRight = handle == .right || handle == .topRight || handle == .bottomRight
        let movesTop = handle == .top || handle == .topLeft || handle == .topRight
        let movesBottom = handle == .bottom || handle == .bottomLeft || handle == .bottomRight

        if movesLeft, let hit = index.nearestVertical(toViewX: minX, yMinView: minY, yMaxView: maxY, radiusPoints: radius) {
            if hit.viewPosition <= maxX - minSize { minX = hit.viewPosition; guideX = hit.viewPosition }
        }
        if movesRight, let hit = index.nearestVertical(toViewX: maxX, yMinView: minY, yMaxView: maxY, radiusPoints: radius) {
            if hit.viewPosition >= minX + minSize { maxX = hit.viewPosition; guideX = hit.viewPosition }
        }
        if movesBottom, let hit = index.nearestHorizontal(toViewY: minY, xMinView: minX, xMaxView: maxX, radiusPoints: radius) {
            if hit.viewPosition <= maxY - minSize { minY = hit.viewPosition; guideY = hit.viewPosition }
        }
        if movesTop, let hit = index.nearestHorizontal(toViewY: maxY, xMinView: minX, xMaxView: maxX, radiusPoints: radius) {
            if hit.viewPosition >= minY + minSize { maxY = hit.viewPosition; guideY = hit.viewPosition }
        }

        boundarySnapGuideX = guideX
        boundarySnapGuideY = guideY
        return NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Snap a whole rect being MOVED (not resized) to nearby image edges. Unlike
    /// resize snapping, the rect size is fixed: we translate it so an edge lands
    /// on a boundary. Both left/right edges are candidates on X (and top/bottom on
    /// Y); the nearer snap wins per axis. Returns the translated rect and updates
    /// the snap-guide feedback. Returns the rect unchanged when snapping is off /
    /// Option is held / no index is built.
    func boundarySnappedMovedRect(_ rect: NSRect, modifiers: NSEvent.ModifierFlags) -> NSRect {
        guard boundarySnapEnabled, !modifiers.contains(.option), let index = boundarySnapIndex else {
            if boundarySnapGuideX != nil || boundarySnapGuideY != nil {
                boundarySnapGuideX = nil
                boundarySnapGuideY = nil
            }
            return rect
        }
        let radius = boundarySnapRadiusPoints
        var dx: CGFloat = 0
        var guideX: CGFloat?
        // X axis: try snapping the left edge and the right edge; take the smaller
        // shift so the closer boundary wins.
        var bestX: CGFloat = .greatestFiniteMagnitude
        if let hit = index.nearestVertical(toViewX: rect.minX, yMinView: rect.minY, yMaxView: rect.maxY, radiusPoints: radius) {
            let shift = hit.viewPosition - rect.minX
            if abs(shift) < abs(bestX) { bestX = shift; guideX = hit.viewPosition }
        }
        if let hit = index.nearestVertical(toViewX: rect.maxX, yMinView: rect.minY, yMaxView: rect.maxY, radiusPoints: radius) {
            let shift = hit.viewPosition - rect.maxX
            if abs(shift) < abs(bestX) { bestX = shift; guideX = hit.viewPosition }
        }
        if bestX != .greatestFiniteMagnitude { dx = bestX }

        var dy: CGFloat = 0
        var guideY: CGFloat?
        var bestY: CGFloat = .greatestFiniteMagnitude
        if let hit = index.nearestHorizontal(toViewY: rect.minY, xMinView: rect.minX, xMaxView: rect.maxX, radiusPoints: radius) {
            let shift = hit.viewPosition - rect.minY
            if abs(shift) < abs(bestY) { bestY = shift; guideY = hit.viewPosition }
        }
        if let hit = index.nearestHorizontal(toViewY: rect.maxY, xMinView: rect.minX, xMaxView: rect.maxX, radiusPoints: radius) {
            let shift = hit.viewPosition - rect.maxY
            if abs(shift) < abs(bestY) { bestY = shift; guideY = hit.viewPosition }
        }
        if bestY != .greatestFiniteMagnitude { dy = bestY }

        boundarySnapGuideX = guideX
        boundarySnapGuideY = guideY
        return rect.offsetBy(dx: dx, dy: dy)
    }

    /// Snap the moving corner of an in-progress rubber-band selection to nearby
    /// image edges (the anchor corner stays fixed). Returns the adjusted point
    /// and updates the snap-guide feedback.
    private func snapMovingPoint(_ point: NSPoint, anchor: NSPoint,
                                 index: BoundarySnapIndex) -> NSPoint {
        var p = point
        var guideX: CGFloat?
        var guideY: CGFloat?
        let radius = boundarySnapRadiusPoints
        let yMin = min(anchor.y, point.y), yMax = max(anchor.y, point.y)
        let xMin = min(anchor.x, point.x), xMax = max(anchor.x, point.x)
        if let hit = index.nearestVertical(toViewX: point.x, yMinView: yMin, yMaxView: yMax, radiusPoints: radius) {
            p.x = hit.viewPosition
            guideX = hit.viewPosition
        }
        if let hit = index.nearestHorizontal(toViewY: point.y, xMinView: xMin, xMaxView: xMax, radiusPoints: radius) {
            p.y = hit.viewPosition
            guideY = hit.viewPosition
        }
        boundarySnapGuideX = guideX
        boundarySnapGuideY = guideY
        return p
    }

    /// Refine all four edges of an existing selection in one explicit action.
    /// This deliberately does not consult `boundarySnapEnabled` and does not
    /// alter the drag-time snap radius or behavior.
    func autoAdjustSelection() {
        guard state == .selected, !isEditorMode, selectionRect.width >= 4,
              selectionRect.height >= 4 else { return }

        guard let index = boundarySnapIndex else {
            guard screenshotImage?.cgImage(
                forProposedRect: nil, context: nil, hints: nil) != nil else {
                showOverlayError("Could not analyze selection edges")
                return
            }
            if !pendingAutoAdjustSelection {
                pendingAutoAdjustSelection = true
                scheduleBoundarySnapIndexBuild()
            }
            showOverlayError("Detecting nearby edges…")
            return
        }

        pendingAutoAdjustSelection = false
        let original = selectionRect.standardized
        let minimumSize: CGFloat = 4
        // Wider than the normal four-point drag snap: a rough selection can
        // intentionally leave substantial padding around the target. Score
        // against the central span so rounded corners and uneven outer padding
        // do not disqualify otherwise continuous element edges.
        let horizontalSearch = min(160, max(48, original.width * 0.30))
        let verticalSearch = min(160, max(48, original.height * 0.30))
        let verticalSpanInset = original.height * 0.15
        let horizontalSpanInset = original.width * 0.15
        let verticalSpanMin = original.minY + verticalSpanInset
        let verticalSpanMax = original.maxY - verticalSpanInset
        let horizontalSpanMin = original.minX + horizontalSpanInset
        let horizontalSpanMax = original.maxX - horizontalSpanInset

        let left = index.nearestVertical(
            toViewX: original.minX,
            yMinView: verticalSpanMin,
            yMaxView: verticalSpanMax,
            radiusPoints: horizontalSearch)
        let right = index.nearestVertical(
            toViewX: original.maxX,
            yMinView: verticalSpanMin,
            yMaxView: verticalSpanMax,
            radiusPoints: horizontalSearch)
        let bottom = index.nearestHorizontal(
            toViewY: original.minY,
            xMinView: horizontalSpanMin,
            xMaxView: horizontalSpanMax,
            radiusPoints: verticalSearch)
        let top = index.nearestHorizontal(
            toViewY: original.maxY,
            xMinView: horizontalSpanMin,
            xMaxView: horizontalSpanMax,
            radiusPoints: verticalSearch)

        let candidateMinX = left?.viewPosition ?? original.minX
        let candidateMaxX = right?.viewPosition ?? original.maxX
        let candidateMinY = bottom?.viewPosition ?? original.minY
        let candidateMaxY = top?.viewPosition ?? original.maxY

        var adjusted = original
        if candidateMaxX - candidateMinX >= minimumSize {
            adjusted.origin.x = candidateMinX
            adjusted.size.width = candidateMaxX - candidateMinX
        }
        if candidateMaxY - candidateMinY >= minimumSize {
            adjusted.origin.y = candidateMinY
            adjusted.size.height = candidateMaxY - candidateMinY
        }

        let changed = abs(adjusted.minX - original.minX) > 0.25
            || abs(adjusted.maxX - original.maxX) > 0.25
            || abs(adjusted.minY - original.minY) > 0.25
            || abs(adjusted.maxY - original.maxY) > 0.25
        guard changed else {
            let foundEdge = left != nil || right != nil || bottom != nil || top != nil
            showOverlayError(foundEdge ? "Selection is already aligned" : "No nearby edges found")
            return
        }

        selectionRect = adjusted
        lockedAspect = nil
        boundarySnapGuideX = nil
        boundarySnapGuideY = nil
        if selectionIsWindowSnap {
            selectionIsWindowSnap = false
            snappedWindowID = nil
            snappedWindowImage = nil
            rebuildToolbarLayout()
        }
        overlayDelegate?.overlayViewSelectionDidChange(selectionRect)
        refreshResolutionAndToolbarLayout()
        updateCursorForCurrentTool()
        showOverlayError("Selection adjusted")
        needsDisplay = true
    }

    /// Builds the edge index for drag snapping once the pointer is on this
    /// display. The index holds 2 bytes per screenshot pixel (about 40 MB on a
    /// 6K display), so displays the user never points at do not build one.
    func requestBoundarySnapIndexIfNeeded() {
        guard boundarySnapBuiltGeneration != boundarySnapBuildGeneration,
              !boundarySnapBuildInFlight, !isEditorMode, screenshotImage != nil,
              boundarySnapEnabled else { return }
        scheduleBoundarySnapIndexBuild()
    }

    /// Build the boundary-snap edge index for the current screenshot off the
    /// main thread, discarding the result if a newer screenshot arrived.
    private func scheduleBoundarySnapIndexBuild() {
        guard !boundarySnapBuildInFlight, let image = screenshotImage,
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return }
        boundarySnapBuildInFlight = true
        let generation = boundarySnapBuildGeneration
        let drawRect = captureDrawRect
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let index = BoundarySnapIndex.build(from: cgImage, drawRect: drawRect)
            DispatchQueue.main.async {
                guard let self, self.boundarySnapBuildGeneration == generation else { return }
                self.boundarySnapBuildInFlight = false
                self.boundarySnapBuiltGeneration = generation
                self.boundarySnapIndex = index
                if self.pendingAutoAdjustSelection {
                    self.pendingAutoAdjustSelection = false
                    if index != nil {
                        self.autoAdjustSelection()
                    } else {
                        self.showOverlayError("Could not analyze selection edges")
                    }
                }
            }
        }
    }

    /// Adjust `rect` to the locked `aspect` (w/h), keeping the handle's anchor fixed.
    /// Corner handles keep the opposite corner fixed and drive from the dominant
    /// dimension; edge handles drive the dragged axis and center the other.
    private func constrainToAspect(_ rect: NSRect, aspect: CGFloat, handle: ResizeHandle, minSize: CGFloat) -> NSRect {
        var w = rect.width
        var h = rect.height

        // Derive the dependent dimension from the driven one.
        switch handle {
        case .top, .bottom:           w = h * aspect        // height driven
        case .left, .right:           h = w / aspect        // width driven
        default:                                            // corner: dominant axis
            if w / aspect >= h { h = w / aspect } else { w = h * aspect }
        }

        // Enforce min size as a RATIO-PRESERVING pair (scale both up together).
        if w < minSize || h < minSize {
            let s = max(minSize / w, minSize / h)
            w *= s; h *= s
        }
        // Shrink (ratio-preserved) if larger than the screen.
        if w > bounds.width || h > bounds.height {
            let s = min(bounds.width / w, bounds.height / h)
            w *= s; h *= s
        }

        // Anchor: corner handles keep the OPPOSITE corner fixed; edge handles keep
        // the opposite edge fixed and center the derived dimension.
        var x = rect.minX
        var y = rect.minY
        switch handle {
        case .topLeft:      x = rect.maxX - w; y = rect.minY
        case .topRight:     x = rect.minX;     y = rect.minY
        case .bottomLeft:   x = rect.maxX - w; y = rect.maxY - h
        case .bottomRight:  x = rect.minX;     y = rect.maxY - h
        case .top:          x = rect.midX - w / 2; y = rect.minY
        case .bottom:       x = rect.midX - w / 2; y = rect.maxY - h
        case .left:         x = rect.maxX - w; y = rect.midY - h / 2
        case .right:        x = rect.minX;     y = rect.midY - h / 2
        default: break
        }
        // Clamp POSITION into bounds (size already fits) without distorting ratio.
        x = max(bounds.minX, min(x, bounds.maxX - w))
        y = max(bounds.minY, min(y, bounds.maxY - h))
        return NSRect(x: x, y: y, width: w, height: h)
    }
}
