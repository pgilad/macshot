import Cocoa

/// Annotation creation, text editing, copy and paste, undo and redo, and the annotation layer cache.
extension OverlayView {

    // MARK: - Annotation Creation

    func startAnnotation(at point: NSPoint) {
        // Click-to-select: if clicking on an existing annotation, select it instead of
        // starting a new annotation. Pencil and marker use long-press instead (so taps
        // and drags always draw, even single dots).
        let isPencilOrMarker = currentTool == .pencil || currentTool == .marker

        // Option = draw-through: with a drawing tool active, ignore annotations
        // (and their controls) under the cursor so the tool draws/places over
        // them instead of selecting/moving them. The select tool keeps its
        // normal behavior — its whole job is annotation interaction.
        let drawThrough = currentTool != .select && NSEvent.modifierFlags.contains(.option)

        // Multi-select delete button — check before single-select controls
        if !drawThrough && selectedAnnotations.count > 1 && multiSelectDeleteButtonRect.contains(point) {
            for ann in selectedAnnotations {
                if let idx = annotations.firstIndex(where: { $0 === ann }) {
                    annotations.remove(at: idx)
                    undoStack.append(.deleted(ann, idx))
                }
            }
            redoStack.removeAll()
            selectedAnnotations = []
            cachedCompositedImage = nil
            needsDisplay = true
            return
        }

        // Always check selected annotation controls (delete, resize, etc.) for all tools
        if currentTool != .colorSampler && !drawThrough {
            if let selected = selectedAnnotation {
                if handleSelectedAnnotationClick(selected, at: point) { return }
            }
        }

        // Click-to-select body: Ctrl+click adds/removes from multi-selection
        // (consistent with Ctrl+drag for lasso). Shift is reserved for angle/shape
        // constraining during drawing.
        // For pencil/marker, only instant-select when Ctrl is held or a multi-selection
        // already exists (so the user can drag the group without a modifier).
        // Text tool: allow selecting annotations on click; only skip instant-select
        // when clicking empty space (where a new text box should be created).
        let ctrlHeld = NSEvent.modifierFlags.contains(.control)
        let pencilHasMultiSelection = isPencilOrMarker && selectedAnnotations.count > 1
        let textHitsAnnotation = currentTool == .text
            && annotations.reversed().contains(where: { $0.isMovable && $0.hitTest(point: point) })
        let useInstantSelect = !drawThrough
            && currentTool != .colorSampler
            && (currentTool != .text || ctrlHeld || textHitsAnnotation)
            && (!isPencilOrMarker || ctrlHeld || pencilHasMultiSelection)
        if useInstantSelect {
            if let clicked = annotations.reversed().first(where: { $0.isMovable && $0.hitTest(point: point) }) {
                shiftClickPendingDeselect = nil
                if ctrlHeld {
                    if isSelected(clicked) {
                        // Defer deselect to mouseUp — allows dragging the full
                        // multi-selection even when ctrl+clicking a selected item.
                        shiftClickPendingDeselect = clicked
                    } else {
                        selectedAnnotations.append(clicked)
                    }
                } else if !isSelected(clicked) {
                    // Not Ctrl, not already selected: replace selection
                    selectedAnnotation = clicked
                }
                // Two-circle loupe: if the click landed on the small SOURCE circle
                // (and not the lens), drag the source — even on the first click
                // that also selects the loupe. Otherwise the first click would
                // fall through to the lens drag below.
                if clicked.tool == .loupe, let src = clicked.loupeSourceRect, src.width > 4 {
                    let sr = min(src.width, src.height) / 2 + 6
                    let onSource = hypot(point.x - src.midX, point.y - src.midY) <= sr
                    let onLens = NSBezierPath(ovalIn: clicked.loupeLensSquareRect).contains(point)
                    if onSource && !onLens {
                        isDraggingLoupeSource = true
                        didMoveAnnotation = false
                        preMoveSnapshots = [(clicked, clicked.clone())]
                        loupeSourceDragStart = point
                        loupeSourceDragOrig = src
                        cachedAnnotationLayerExcludingSelected = buildAnnotationLayer(excluding: Set(selectedAnnotations.map { ObjectIdentifier($0) }))
                        NSCursor.closedHand.set()
                        needsDisplay = true
                        return
                    }
                }
                // If already selected without Ctrl: keep current selection (allows multi-drag)
                isDraggingAnnotation = true
                didMoveAnnotation = false
                annotationDragStart = point
                // Build cache of non-selected annotations for fast drag rendering
                cachedAnnotationLayerExcludingSelected = buildAnnotationLayer(excluding: Set(selectedAnnotations.map { ObjectIdentifier($0) }))
                NSCursor.closedHand.set()
                needsDisplay = true
                return
            }
        }

        // Ctrl+click on empty space — start lasso marquee selection
        if ctrlHeld {
            isLassoSelecting = true
            lassoStart = point
            lassoRect = .zero
            needsDisplay = true
            return
        }

        // Pencil/marker without Ctrl: start a long-press timer. If the user holds
        // still for 300ms on an annotation, select it. Otherwise drawing starts
        // normally (the timer is cancelled in mouseDragged when movement exceeds 3px).
        if isPencilOrMarker && !ctrlHeld && !drawThrough {
            let hasAnnotationUnder = annotations.reversed().contains(where: { $0.isMovable && $0.hitTest(point: point) })
            if hasAnnotationUnder {
                longPressPoint = point
                longPressTriggered = false
                longPressTimer?.invalidate()
                longPressTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.handleLongPress(at: point) }
                }
            }
        }

        // Clicking empty space — clear selection and start new annotation
        if !selectedAnnotations.isEmpty { selectedAnnotations = [] }

        // Dispatch to extracted tool handler if available
        if let handler = toolHandlers[currentTool] {
            if let annotation = handler.start(at: point, canvas: self) {
                // Apply outline color from settings for supported tools
                let outlineTools: [AnnotationTool] = [.arrow, .line, .rectangle, .ellipse, .number]
                if outlineTools.contains(currentTool) && UserDefaults.standard.bool(forKey: "annotationOutlineEnabled") {
                    annotation.outlineColor = ToolOptionsRowView.savedOutlineColor
                }
                currentAnnotation = annotation
                needsDisplay = true
            }
            return
        }

        // Color sampler: click sets the current drawing color, no annotation created.
        // Note: point is already in canvas space (converted by caller).
        if currentTool == .colorSampler {
            if let result = sampleCanvasColor(at: point) {
                currentColor = result.color
                currentColorOpacity = 1.0
                OverlayView.lastUsedOpacity = 1.0
                UserDefaults.standard.set(1.0, forKey: "lastUsedColorOpacity")
                // Also save to selected custom slot
                if selectedColorSlot >= 0 && selectedColorSlot < customColors.count {
                    customColors[selectedColorSlot] = result.color.withAlphaComponent(1.0)
                    saveCustomColors()
                    // Advance to next slot for rapid collection
                    let nextSlot = selectedColorSlot + 1
                    if nextSlot < customColors.count { selectedColorSlot = nextSlot }
                }
                showOverlayError(String(format: "Set color %@", result.hex))
                needsDisplay = true
            }
            return
        }

        if currentTool == .text && !drawThrough {
            // Click on existing text annotation → select it (double-click enters edit via handleSelectedAnnotationClick)
            if let existingAnn = annotations.reversed().first(where: {
                $0.tool == .text && $0.hitTest(point: point)
            }) {
                selectedAnnotation = existingAnn
                needsDisplay = true
                // If double-click, immediately enter edit mode
                if let event = NSApp.currentEvent, event.clickCount >= 2 {
                    textEditor.editingAnnotation = existingAnn
                    textEditor.restoreState(from: existingAnn)
                    if let idx = annotations.firstIndex(where: { $0 === existingAnn }) {
                        annotations.remove(at: idx)
                        selectedAnnotation = nil
                    }
                    showTextField(
                        at: existingAnn.textDrawRect.origin,
                        existingText: existingAnn.attributedText,
                        existingFrame: existingAnn.textDrawRect)
                    cachedCompositedImage = nil
                }
            } else if !justDismissedTextEditor {
                // Click on empty space → new text annotation, immediately enter
                // edit. Skipped when this same click just dismissed an open editor
                // (clicking out should close it, not place a new field).
                showTextField(at: point)
            }
        }
    }

    func updateAnnotation(at point: NSPoint, shiftHeld: Bool = false) {
        guard let annotation = currentAnnotation else { return }
        if let handler = toolHandlers[annotation.tool] {
            handler.update(to: point, shiftHeld: shiftHeld, canvas: self)
        }
    }

    func finishAnnotation(_ annotation: Annotation) {
        if let handler = toolHandlers[annotation.tool] {
            handler.finish(canvas: self)
        }
    }

    /// Handle click on the selected annotation's controls (resize handles, rotation, delete).
    /// Returns true if the click was consumed. Does NOT check the annotation body — that's
    /// handled by the caller's hit-test loop.
    private func handleSelectedAnnotationClick(_ selected: Annotation, at point: NSPoint) -> Bool {
        // Unrotate point for resize handle hit test
        let handleTestPoint: NSPoint
        if selected.rotation != 0 && selected.supportsRotation {
            let center = NSPoint(x: selected.boundingRect.midX, y: selected.boundingRect.midY)
            let cos_r = cos(-selected.rotation)
            let sin_r = sin(-selected.rotation)
            let dx = point.x - center.x
            let dy = point.y - center.y
            handleTestPoint = NSPoint(
                x: center.x + dx * cos_r - dy * sin_r,
                y: center.y + dx * sin_r + dy * cos_r)
        } else {
            handleTestPoint = point
        }
        // Two-circle loupe: source-circle resize handle (changes zoom).
        if selected.tool == .loupe, loupeSourceHandleRect != .zero,
           loupeSourceHandleRect.insetBy(dx: -6, dy: -6).contains(point) {
            isResizingLoupeSource = true
            didMoveAnnotation = false
            preMoveSnapshots = [(selected, selected.clone())]
            loupeSourceDragStart = point
            loupeSourceDragOrig = selected.loupeSourceRect ?? .zero
            cachedAnnotationLayerExcludingSelected = buildAnnotationLayer(excluding: Set(selectedAnnotations.map { ObjectIdentifier($0) }))
            NSCursor.closedHand.set()
            needsDisplay = true
            return true
        }
        // Check resize handles (populated by drawAnnotationControls)
        for (handleIdx, handleEntry) in annotationResizeHandleRects.enumerated() {
            let (handle, rect) = handleEntry
            if rect.insetBy(dx: -4, dy: -4).contains(handleTestPoint) {
                isResizingAnnotation = true
                // Snapshot for undo + change detection (resize records an edit).
                preMoveSnapshots = [(selected, selected.clone())]
                // Build cache of non-selected annotations for fast resize rendering
                cachedAnnotationLayerExcludingSelected = buildAnnotationLayer(excluding: Set(selectedAnnotations.map { ObjectIdentifier($0) }))
                annotationResizeHandle = handle
                annotationResizeOrigStart = selected.startPoint
                annotationResizeOrigEnd = selected.endPoint
                annotationResizeOrigTextOrigin = selected.textDrawRect.origin
                annotationResizeMouseStart = point
                annotationResizeAnchorIndex = -1
                if let anchors = selected.anchorPoints, anchors.count >= 3, handleIdx >= 2 {
                    let anchorIdx = handleIdx - 2 + 1
                    if anchorIdx > 0 && anchorIdx < anchors.count - 1 {
                        annotationResizeAnchorIndex = anchorIdx
                        annotationResizeOrigControlPoint = anchors[anchorIdx]
                    }
                } else if handle == .none || (handle != .bottomLeft && handle != .topRight) {
                    if annotationResizeAnchorIndex < 0 {
                        annotationResizeOrigControlPoint =
                            selected.controlPoint
                            ?? NSPoint(
                                x: (selected.startPoint.x + selected.endPoint.x) / 2,
                                y: (selected.startPoint.y + selected.endPoint.y) / 2
                            )
                    }
                }
                NSCursor.closedHand.set()
                needsDisplay = true
                return true
            }
        }
        // Check rotation handle
        if annotationRotateHandleRect != .zero
            && annotationRotateHandleRect.insetBy(dx: -6, dy: -6).contains(point)
        {
            isRotatingAnnotation = true
            // Snapshot for undo + change detection (rotate records an edit).
            preMoveSnapshots = [(selected, selected.clone())]
            cachedAnnotationLayerExcludingSelected = buildAnnotationLayer(excluding: Set(selectedAnnotations.map { ObjectIdentifier($0) }))
            let center = NSPoint(x: selected.boundingRect.midX, y: selected.boundingRect.midY)
            rotationStartAngle = atan2(point.x - center.x, point.y - center.y)
            rotationOriginal = selected.rotation
            NSCursor.closedHand.set()
            needsDisplay = true
            return true
        }
        // Check edit button (text annotations only)
        if selected.tool == .text && annotationEditButtonRect != .zero && annotationEditButtonRect.contains(point) {
            textEditor.restoreState(from: selected)
            if let idx = annotations.firstIndex(where: { $0 === selected }) {
                annotations.remove(at: idx)
                selectedAnnotation = nil
            }
            showTextField(
                at: selected.textDrawRect.origin, existingText: selected.attributedText,
                existingFrame: selected.textDrawRect)
            needsDisplay = true
            return true
        }
        // Check delete button
        if annotationDeleteButtonRect.contains(point) {
            if let idx = annotations.firstIndex(where: { $0 === selected }) {
                annotations.remove(at: idx)
                undoStack.append(.deleted(selected, idx))
                redoStack.removeAll()
            }
            selectedAnnotation = nil
            needsDisplay = true
            return true
        }
        // Double-click on text annotation — enter edit mode
        if selected.tool == .text && selected.hitTest(point: point) {
            if let event = NSApp.currentEvent, event.clickCount >= 2 {
                textEditor.editingAnnotation = selected
                textEditor.restoreState(from: selected)
                if let idx = annotations.firstIndex(where: { $0 === selected }) {
                    annotations.remove(at: idx)
                    selectedAnnotation = nil
                }
                showTextField(
                    at: selected.textDrawRect.origin, existingText: selected.attributedText,
                    existingFrame: selected.textDrawRect)
                cachedCompositedImage = nil
                return true
            }
        }
        // Two-circle loupe: pressing the small SOURCE circle drags it
        // independently (re-roots what's magnified), with the connecting line
        // auto-adjusting. Check this BEFORE the lens body so the source wins when
        // the press is over it but not over the lens.
        if selected.tool == .loupe, let src = selected.loupeSourceRect, src.width > 4 {
            let sr = min(src.width, src.height) / 2 + 6
            let onSource = hypot(point.x - src.midX, point.y - src.midY) <= sr
            let onLens = NSBezierPath(ovalIn: selected.loupeLensSquareRect).contains(point)
            if onSource && !onLens {
                isDraggingLoupeSource = true
                didMoveAnnotation = false
                loupeSourceDragStart = point
                loupeSourceDragOrig = src
                cachedAnnotationLayerExcludingSelected = buildAnnotationLayer(excluding: Set(selectedAnnotations.map { ObjectIdentifier($0) }))
                NSCursor.closedHand.set()
                needsDisplay = true
                return true
            }
        }
        // Click on the annotation body — start drag (annotation already selected)
        if selected.hitTest(point: point) {
            isDraggingAnnotation = true
            didMoveAnnotation = false
            annotationDragStart = point
            cachedAnnotationLayerExcludingSelected = buildAnnotationLayer(excluding: Set(selectedAnnotations.map { ObjectIdentifier($0) }))
            NSCursor.closedHand.set()
            needsDisplay = true
            return true
        }
        return false
    }

    // MARK: - Text Field

    private func showTextField(
        at point: NSPoint, existingText: NSAttributedString? = nil, existingFrame: NSRect = .zero
    ) {
        textEditor.show(
            in: self, at: point, color: currentColor,
            existingText: existingText, existingFrame: existingFrame,
            canvas: self)
        textEditor.textView?.delegate = self
        rebuildToolbarLayout()
        needsDisplay = true
    }

    func cancelTextEditing() {
        textToolDoubleClickCopyDeadline = 0
        textEditor.cancel(canvas: self)
        window?.makeFirstResponder(self)
        rebuildToolbarLayout()
        needsDisplay = true
    }

    func commitTextFieldIfNeeded() {
        guard textEditor.isEditing else { return }
        textToolDoubleClickCopyDeadline = 0
        textEditor.commit(canvas: self)
        window?.makeFirstResponder(self)
        rebuildToolbarLayout()
        needsDisplay = true
    }

    // MARK: - Context Menu Actions

    /// Add an anchor point to a line/arrow annotation at the position closest to `canvasPoint`.
    /// Inserts the point between the two nearest existing waypoints.
    func addAnchorPoint(to annotation: Annotation, at canvasPoint: NSPoint) {
        var pts = annotation.waypoints

        // Find which segment the point is closest to, and insert there
        var bestIdx = 1
        var bestDist = CGFloat.greatestFiniteMagnitude
        for i in 1..<pts.count {
            let d = distanceToSegment(point: canvasPoint, from: pts[i - 1], to: pts[i])
            if d < bestDist {
                bestDist = d
                bestIdx = i
            }
        }

        // Project the point onto the segment for exact placement
        let a = pts[bestIdx - 1]
        let b = pts[bestIdx]
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lenSq = dx * dx + dy * dy
        let t: CGFloat =
            lenSq < 0.001
            ? 0.5
            : max(
                0.05, min(0.95, ((canvasPoint.x - a.x) * dx + (canvasPoint.y - a.y) * dy) / lenSq))
        let projected = NSPoint(x: a.x + t * dx, y: a.y + t * dy)

        pts.insert(projected, at: bestIdx)

        // Store as anchorPoints, update startPoint/endPoint to match
        annotation.anchorPoints = pts
        annotation.startPoint = pts.first!
        annotation.endPoint = pts.last!
        // Clear legacy controlPoint since we're using anchorPoints now
        annotation.controlPoint = nil
    }

    private func distanceToSegment(point: NSPoint, from a: NSPoint, to b: NSPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lenSq = dx * dx + dy * dy
        if lenSq < 0.001 { return hypot(point.x - a.x, point.y - a.y) }
        var t = ((point.x - a.x) * dx + (point.y - a.y) * dy) / lenSq
        t = max(0, min(1, t))
        let proj = NSPoint(x: a.x + t * dx, y: a.y + t * dy)
        return hypot(point.x - proj.x, point.y - proj.y)
    }

    @objc func saveAsMenuAction() {
        overlayDelegate?.overlayViewDidRequestSaveAs()
    }

    @objc func saveToFolderMenuAction() {
        overlayDelegate?.overlayViewDidRequestFileSave()
    }

    // MARK: - Annotation Copy/Paste

    static let annotationPasteboardType = NSPasteboard.PasteboardType("com.pgilad.macshot.annotations")

    /// Copy selected annotations to the pasteboard.
    func copySelectedAnnotations() {
        let toCopy = selectedAnnotations.isEmpty ? [] : selectedAnnotations
        guard !toCopy.isEmpty else { return }
        guard let data = AnnotationSerializer.encode(toCopy) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(data, forType: Self.annotationPasteboardType)
    }

    /// Paste annotations from the pasteboard, offset slightly so they're visible.
    func pasteAnnotations() {
        let pb = NSPasteboard.general
        guard let data = pb.data(forType: Self.annotationPasteboardType),
              let pasted = AnnotationSerializer.decode(data) else { return }
        selectedAnnotations = []
        var newAnnotations: [Annotation] = []
        for ann in pasted {
            let copy = ann.clone()
            copy.move(dx: 15, dy: -15)
            annotations.append(copy)
            undoStack.append(.added(copy))
            newAnnotations.append(copy)
        }
        redoStack.removeAll()
        selectedAnnotations = newAnnotations
        cachedCompositedImage = nil
        needsDisplay = true
    }

    /// Duplicate the selected annotations in place (Cmd+D) — same offset behavior
    /// as copy+paste, but the user's clipboard is left untouched.
    func duplicateSelectedAnnotations() {
        let toDuplicate = selectedAnnotations
        guard !toDuplicate.isEmpty else { return }
        // Fresh groupID per action: a multi-duplicate undoes as one step, and the
        // clone doesn't inherit the source's groupID (which would batch its undo
        // with unrelated entries, e.g. auto-redact groups).
        let groupID = toDuplicate.count > 1 ? UUID() : nil
        var newAnnotations: [Annotation] = []
        for ann in toDuplicate {
            let copy = ann.clone()
            copy.groupID = groupID
            copy.move(dx: 15, dy: -15)
            annotations.append(copy)
            undoStack.append(.added(copy))
            newAnnotations.append(copy)
        }
        redoStack.removeAll()
        selectedAnnotations = newAnnotations
        cachedCompositedImage = nil
        needsDisplay = true
    }

    /// Editor only: paste an image from the clipboard as a draggable stamp placed
    /// below the canvas (auto-expands to fit), mirroring the "Add Capture" flow.
    /// Returns true if an image was found and pasted.
    func pasteImageFromClipboard() -> Bool {
        guard isEditorMode else { return false }
        guard let image = NSImage(pasteboard: NSPasteboard.general), image.size.width > 0, image.size.height > 0 else {
            return false
        }
        addCaptureImage(image)
        return true
    }

    /// Push undo entries for a finished drag/resize/rotate manipulation, but only
    /// for annotations whose geometry actually changed vs the pre-manipulation
    /// snapshot. Recording these makes such edits undoable AND makes them count as
    /// a change (so the editor shows "Done" and prompts on close).
    func commitAnnotationManipulationUndo() {
        guard !preMoveSnapshots.isEmpty else { return }
        var pushed = false
        for (ann, snapshot) in preMoveSnapshots where Self.annotationGeometryChanged(ann, snapshot) {
            undoStack.append(.propertyChange(annotation: ann, snapshot: snapshot))
            pushed = true
        }
        preMoveSnapshots = []
        if pushed {
            redoStack.removeAll()
            cachedCompositedImage = nil
        }
    }

    /// Whether two annotations differ in position/size/rotation (the things a
    /// drag/resize/rotate changes).
    private static func annotationGeometryChanged(_ a: Annotation, _ b: Annotation) -> Bool {
        if a.startPoint != b.startPoint || a.endPoint != b.endPoint { return true }
        if abs(a.rotation - b.rotation) > 0.0001 { return true }
        if a.controlPoint != b.controlPoint { return true }
        if (a.points ?? []) != (b.points ?? []) { return true }
        if (a.anchorPoints ?? []) != (b.anchorPoints ?? []) { return true }
        if a.textDrawRect != b.textDrawRect { return true }
        if a.loupeSourceRect != b.loupeSourceRect { return true }
        if abs(a.loupeMagnification - b.loupeMagnification) > 0.0001 { return true }
        return false
    }

    // MARK: - Undo/Redo

    func undo() {
        guard let entry = undoStack.last else { return }
        undoStack.removeLast()
        switch entry {
        case .added(let ann):
            // Undo an addition — handle batch (groupID) or single
            if let groupID = ann.groupID {
                var batch: [UndoEntry] = [.added(ann)]
                while let prev = undoStack.last, prev.annotation.groupID == groupID {
                    undoStack.removeLast()
                    batch.append(prev)
                }
                for e in batch { annotations.removeAll { $0 === e.annotation } }
                if ann.tool == .number { numberCounter = max(0, numberCounter - batch.count) }
                redoStack.append(contentsOf: batch)
                clearHoverIfNeeded(batch.map { $0.annotation })
            } else {
                annotations.removeAll { $0 === ann }
                if ann.tool == .number { numberCounter = max(0, numberCounter - 1) }
                redoStack.append(.added(ann))
                clearHoverIfNeeded([ann])
            }
        case .deleted(let ann, let idx):
            // Undo a deletion — re-insert at original position
            let safeIdx = min(idx, annotations.count)
            annotations.insert(ann, at: safeIdx)
            if ann.tool == .number { numberCounter += 1 }
            redoStack.append(.deleted(ann, idx))
        case .propertyChange(let ann, let snapshot):
            // Undo property change — swap current state with snapshot
            let currentSnapshot = ann.clone()
            ann.copyProperties(from: snapshot)
            redoStack.append(.propertyChange(annotation: ann, snapshot: currentSnapshot))
            cachedCompositedImage = nil
        case .imageTransform(let previousImage, let previousSnapped, _):
            // Undo crop/flip — swap the current image with the saved one
            let currentImage = screenshotImage?.copy() as? NSImage ?? previousImage
            let currentSnapped = previousSnapped != nil ? snappedWindowImage : nil
            redoStack.append(.imageTransform(previousImage: currentImage,
                                             previousSnappedWindowImage: currentSnapped,
                                             annotationOffsets: []))
            screenshotImage = previousImage
            if previousSnapped != nil { snappedWindowImage = previousSnapped }
            // Update selectionRect to match restored image size
            if isEditorMode {
                selectionRect = NSRect(origin: .zero, size: previousImage.size)
                if isInsideScrollView { frame.size = previousImage.size }
            }
            cachedCompositedImage = nil
            resetZoom()
        }
        needsDisplay = true
    }

    private func clearHoverIfNeeded(_ removed: [Annotation]) {
        if let h = hoveredAnnotation, removed.contains(where: { $0 === h }) {
            hoveredAnnotationClearTimer?.invalidate()
            hoveredAnnotationClearTimer = nil
            hoveredAnnotation = nil
        }
        selectedAnnotations.removeAll { ann in removed.contains(where: { $0 === ann }) }
    }

    func redo() {
        guard let entry = redoStack.last else { return }
        isReplayingRedo = true
        defer { isReplayingRedo = false }
        redoStack.removeLast()
        switch entry {
        case .added(let ann):
            if let groupID = ann.groupID {
                var batch: [UndoEntry] = [.added(ann)]
                while let next = redoStack.last, next.annotation.groupID == groupID {
                    redoStack.removeLast()
                    batch.append(next)
                }
                for e in batch { annotations.append(e.annotation) }
                if ann.tool == .number { numberCounter += batch.count }
                undoStack.append(contentsOf: batch)
            } else {
                annotations.append(ann)
                if ann.tool == .number { numberCounter += 1 }
                undoStack.append(.added(ann))
            }
        case .deleted(let ann, let idx):
            // Redo a deletion — remove again
            annotations.removeAll { $0 === ann }
            if ann.tool == .number { numberCounter = max(0, numberCounter - 1) }
            undoStack.append(.deleted(ann, idx))
        case .propertyChange(let ann, let snapshot):
            // Redo property change — swap again
            let currentSnapshot = ann.clone()
            ann.copyProperties(from: snapshot)
            undoStack.append(.propertyChange(annotation: ann, snapshot: currentSnapshot))
            cachedCompositedImage = nil
        case .imageTransform(let redoImage, let redoSnapped, _):
            // Redo crop/flip — swap back
            let currentImage = screenshotImage?.copy() as? NSImage ?? redoImage
            let currentSnapped = redoSnapped != nil ? snappedWindowImage : nil
            undoStack.append(.imageTransform(previousImage: currentImage,
                                             previousSnappedWindowImage: currentSnapped,
                                             annotationOffsets: []))
            screenshotImage = redoImage
            if redoSnapped != nil { snappedWindowImage = redoSnapped }
            if isEditorMode {
                selectionRect = NSRect(origin: .zero, size: redoImage.size)
                if isInsideScrollView { frame.size = redoImage.size }
            }
            cachedCompositedImage = nil
            if !isInsideScrollView { resetZoom() }
        }
        needsDisplay = true
    }

    // MARK: - Annotation layer cache

    /// Render all committed annotations into a transparent bitmap (canvas-space, no zoom).
    /// Reused across frames until annotations change, avoiding per-frame iteration.
    func annotationLayerImage() -> NSImage {
        if let cached = cachedAnnotationLayer { return cached }
        let image = renderAnnotationBitmap(annotations: annotations)
        cachedAnnotationLayer = image
        return image
    }

    var annotationLayerCache: NSImage? { cachedAnnotationLayer }

    /// Incrementally add a newly committed annotation onto a previous cache snapshot.
    /// Avoids a full rebuild which can cause a visible lag (cursor disappears for a frame).
    func appendToAnnotationCache(_ annotation: Annotation, previousCache: NSImage) {
        guard let existingCG = previousCache.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return }

        let size = bounds.size
        let scale = window?.backingScaleFactor ?? 2.0
        let pxW = Int(ceil(size.width * scale))
        let pxH = Int(ceil(size.height * scale))
        let colorSpace = window?.screen?.colorSpace?.cgColorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let cgCtx = CGContext(
            data: nil, width: pxW, height: pxH,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        cgCtx.scaleBy(x: scale, y: scale)

        // Draw existing cache
        cgCtx.draw(existingCG, in: CGRect(origin: .zero, size: size))

        // Draw new annotation on top
        let nsCtx = NSGraphicsContext(cgContext: cgCtx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx
        annotation.draw(in: nsCtx)
        NSGraphicsContext.restoreGraphicsState()

        guard let cgImage = cgCtx.makeImage() else { return }
        cachedAnnotationLayer = NSImage(cgImage: cgImage, size: size)
    }

    /// Build annotation layer excluding specific annotations (used during drag/resize).
    /// Skips the highlight dim: while dragging/resizing, the dim is a moving union
    /// of ALL highlights, so it's drawn live in the draw pass over this static
    /// layer rather than baked here (which would dim using stale positions and
    /// double up with the live pass).
    func buildAnnotationLayer(excluding: Set<ObjectIdentifier>) -> NSImage {
        let filtered = annotations.filter { !excluding.contains(ObjectIdentifier($0)) }
        return renderAnnotationBitmap(annotations: filtered, skipHighlightDim: true)
    }

    /// Render annotations into a fixed bitmap at the current backing scale.
    /// Uses CGBitmapContext with the window's color space so colors match exactly.
    /// Returns an NSImage backed by a CGImage so AppKit never re-invokes a
    /// drawing handler when the image is drawn into a zoomed context.
    private func renderAnnotationBitmap(annotations: [Annotation], skipHighlightDim: Bool = false) -> NSImage {
        let size = bounds.size
        let scale = window?.backingScaleFactor ?? 2.0
        let pxW = Int(ceil(size.width * scale))
        let pxH = Int(ceil(size.height * scale))
        let colorSpace = window?.screen?.colorSpace?.cgColorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let cgCtx = CGContext(
            data: nil, width: pxW, height: pxH,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return NSImage(size: size) }
        // Scale so drawing in points maps to pixels
        cgCtx.scaleBy(x: scale, y: scale)

        let nsCtx = NSGraphicsContext(cgContext: cgCtx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx
        for annotation in annotations where annotation.tool == .pixelate {
            annotation.draw(in: nsCtx)
        }
        // Spotlight dim: a single union pass over all highlight rects, after the
        // censor effects and before the shape annotations (so shapes stay
        // readable over the dimming). Highlights' own draw() only adds a border.
        if !skipHighlightDim {
            Annotation.drawHighlightDim(for: annotations, in: highlightDimBounds)
        }
        for annotation in annotations where annotation.tool != .pixelate {
            annotation.draw(in: nsCtx)
        }
        NSGraphicsContext.restoreGraphicsState()

        guard let cgImage = cgCtx.makeImage() else { return NSImage(size: size) }
        return NSImage(cgImage: cgImage, size: size)
    }
}
