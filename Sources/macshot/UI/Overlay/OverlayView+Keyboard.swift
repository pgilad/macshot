import Cocoa

/// Keyboard shortcuts and key events.
extension OverlayView {

    // MARK: - Keyboard

    override func flagsChanged(with event: NSEvent) {
        // Re-apply shift constraint immediately when Shift is pressed/released during annotation drag
        if currentAnnotation != nil, let lastPoint = lastDragPoint {
            let shiftHeld = event.modifierFlags.contains(.shift)
            updateAnnotation(at: lastPoint, shiftHeld: shiftHeld)
            needsDisplay = true
        }
    }

    /// Called by the Character Palette when the user selects an emoji.
    override func insertText(_ insertString: Any) {
        guard currentTool == .stamp, let str = insertString as? String, !str.isEmpty else { return }
        currentStampImage = StampEmojis.renderEmoji(str)
        currentStampEmoji = str
        needsDisplay = true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Text editing: forward standard commands to the active text view.
        if let tv = textEditView {
            if let action = EditorCommandShortcutManager.action(for: event) {
                if action == .undo { tv.undoManager?.undo() } else { tv.undoManager?.redo() }
                return true
            }
            if KeyboardShortcutMatcher.matches(event, character: "c", modifiers: .command) {
                if tv.selectedRange().length > 0 {
                    tv.copy(nil)
                } else {
                    // No text selected — commit, copy annotation, then deselect
                    // so the purple selection chrome doesn't flash.
                    commitTextFieldIfNeeded()
                    if selectedAnnotations.isEmpty, let last = annotations.last, last.tool == .text {
                        selectedAnnotation = last
                    }
                    copySelectedAnnotations()
                    selectedAnnotations = []
                    needsDisplay = true
                }
                return true
            }
            if KeyboardShortcutMatcher.matches(event, character: "v", modifiers: .command) {
                if NSPasteboard.general.data(forType: Self.annotationPasteboardType) != nil {
                    commitTextFieldIfNeeded()
                    pasteAnnotations()
                    selectedAnnotations = []
                    needsDisplay = true
                } else if NSPasteboard.general.canReadObject(forClasses: [NSString.self], options: nil) {
                    tv.paste(nil)
                } else if isEditorMode {
                    commitTextFieldIfNeeded()
                    _ = pasteImageFromClipboard()
                } else {
                    tv.paste(nil)
                }
                return true
            }
            if KeyboardShortcutMatcher.matches(event, character: "x", modifiers: .command) {
                tv.cut(nil)
                return true
            }
            if KeyboardShortcutMatcher.matches(event, character: "a", modifiers: .command) {
                tv.selectAll(nil)
                return true
            }
        }

        // Annotation copy/paste/duplicate (no text editing active).
        if state == .selected {
            if KeyboardShortcutMatcher.matches(event, character: "c", modifiers: .command) {
                if !selectedAnnotations.isEmpty {
                    copySelectedAnnotations()
                } else {
                    overlayDelegate?.overlayViewDidConfirm()
                }
                return true
            }
            if KeyboardShortcutMatcher.matches(event, character: "v", modifiers: .command) {
                if NSPasteboard.general.data(forType: Self.annotationPasteboardType) != nil {
                    pasteAnnotations()
                    return true
                }
                if pasteImageFromClipboard() { return true }
            }
            if KeyboardShortcutMatcher.matches(event, character: "d", modifiers: .command),
               !selectedAnnotations.isEmpty {
                duplicateSelectedAnnotations()
                return true
            }
            if let action = EditorCommandShortcutManager.action(for: event) {
                if action == .undo { undo() } else { redo() }
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        // Character-based so the shortcut follows QWERTZ/AZERTY/Dvorak.
        if state == .idle && snapMode != .off
            && KeyboardShortcutMatcher.matches(event, character: "f", modifiers: []) {
            selectionRect = bounds
            state = .selected
            hoveredSnapRect = nil
            if autoQuickSaveMode {
                autoQuickSaveMode = false
                overlayDelegate?.overlayViewDidRequestQuickSave()
            } else {
                showToolbars = true
                overlayDelegate?.overlayViewDidFinishSelection(selectionRect)
                needsDisplay = true
            }
            return
        }

        // R restores the previous capture region while the overlay is still
        // waiting for a selection. Once selected, R keeps its normal Rectangle
        // tool shortcut behavior.
        if state == .idle, !isEditorMode, textEditView == nil,
           KeyboardShortcutMatcher.matches(event, character: "r", modifiers: []) {
            overlayDelegate?.overlayViewDidRequestRestoreLastSelection()
            return
        }

        // Space: reposition shape/selection mid-drag (design tool convention).
        // When it is not actionable, still consume it so key repeat never falls
        // through to AppKit's "unhandled key" beep while the overlay is focused.
        if event.keyCode == 49 && textEditView == nil
            && !event.modifierFlags.contains(.command)
            && !event.modifierFlags.contains(.option)
            && !event.modifierFlags.contains(.control) {
            // Swallow all repeats while repositioning to prevent system beep
            if spaceRepositioning { return }

            if !event.isARepeat {
                let isDrawingAnnotation =
                    currentAnnotation != nil && currentAnnotation!.tool != .pencil
                    && currentAnnotation!.tool != .marker
                let isResizingExistingAnnotation = isResizingAnnotation && selectedAnnotation != nil
                let isResizingCaptureSelection = isResizingSelection
                let isDraggingNewSelection = state == .selecting

                if isDrawingAnnotation || isResizingExistingAnnotation
                    || isResizingCaptureSelection || isDraggingNewSelection {
                    spaceRepositioning = true
                    if isDrawingAnnotation {
                        spaceRepositionLast = lastDragPoint ?? currentCanvasMousePoint ?? .zero
                    } else if isResizingExistingAnnotation {
                        spaceRepositionLast = currentCanvasMousePoint ?? annotationResizeMouseStart
                    } else if isResizingCaptureSelection, let windowPoint = window?.mouseLocationOutsideOfEventStream {
                        spaceRepositionLast = convert(windowPoint, from: nil)
                    } else if let windowPoint = window?.mouseLocationOutsideOfEventStream {
                        spaceRepositionLast = convert(windowPoint, from: nil)
                    }
                    return
                }
            }
            // Space may be a user-configured action shortcut (Copy, Save, Pin, …).
            // The reposition feature only owns Space during an active drag, so an
            // idle press must go through the same dispatch as every other key (#292).
            if !event.isARepeat, state == .selected,
               let action = ToolShortcutManager.lookupAction(for: " ") {
                switch action {
                case .moveSelection:
                    if !isKeyboardMoveSelectionActive {
                        _ = startKeyboardMoveSelection()
                    }
                case .detach:
                    if shouldAllowDetach() { handleToolbarAction(.detach) }
                case .pin, .scrollCapture:
                    if !isEditorMode { handleToolbarAction(action) }
                default:
                    handleToolbarAction(action)
                }
                return
            }
            // Unbound Space is still consumed so key repeat never falls through
            // to AppKit's "unhandled key" beep while the overlay is focused.
            return
        }

        switch event.keyCode {
        case 53:  // Escape
            if isScrollCapturing {
                overlayDelegate?.overlayViewDidRequestCancelScrollCapture()
                return
            }
            if isAnchoredSelecting {
                cancelAnchoredSelection()
                return
            }
            if colorWheel.isVisible && colorWheel.isSticky {
                colorWheel.dismiss()
                needsDisplay = true
            } else if textEditView != nil {
                cancelTextEditing()
            } else if PopoverHelper.isVisible {
                PopoverHelper.dismiss()
            } else if !selectedAnnotations.isEmpty {
                selectedAnnotations = []
                needsDisplay = true
            } else {
                overlayDelegate?.overlayViewDidCancel()
            }
        case 48:  // Tab
            if state == .idle {
                // Cycle capture snapping: window -> off -> element.
                snapMode = snapMode.next
                hoveredSnapRect = nil
                hoveredSnapWindowID = nil
                needsDisplay = true
                // Notify other overlays to redraw (for multi-monitor setups)
                overlayDelegate?.overlayViewDidChangeSnapMode()
                // Element mode stays selected so it works on the next capture once granted.
                if snapMode == .element && !AXIsProcessTrusted() {
                    showOverlayError("\(Permissions.accessibilityName) permission required")
                    overlayDelegate?.overlayViewDidRequestAccessibilityPermission()
                    return
                }
                if snapMode != .off {
                    querySnapTarget(at: NSEvent.mouseLocation)
                }
            }
        case 36, 76:  // Return / numpad Enter — quick capture (respects quickCaptureMode setting)
            if textEditView == nil, state == .selected {
                overlayDelegate?.overlayViewDidRequestQuickSave()
            }
        case 51, 117:  // Backspace / Forward-Delete — remove selected annotation(s)
            guard textEditView == nil, state == .selected, !selectedAnnotations.isEmpty else { break }
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
        default:
            // Auto-measure: hold "1" = vertical preview, hold "2" = horizontal preview
            if state == .selected && currentTool == .measure && textEditView == nil
                && !event.modifierFlags.contains(.command) {
                if let char = event.charactersIgnoringModifiers {
                    if char == "1" || char == "2" {
                        autoMeasureVertical = (char == "1")
                        if !autoMeasureKeyHeld {
                            autoMeasureKeyHeld = true
                            updateAutoMeasurePreview()
                        }
                        return
                    }
                }
            }
            // Single-key tool shortcuts (only when selected, not editing text, no modifiers)
            if state == .selected && textEditView == nil && !event.modifierFlags.contains(.command)
                && !event.modifierFlags.contains(.option) && !event.modifierFlags.contains(.control) {
                let action = KeyboardShortcutMatcher.toolCharacters(for: event)
                    .lazy
                    .compactMap { ToolShortcutManager.lookupAction(for: $0) }
                    .first
                if let action {
                    switch action {
                    case .moveSelection:
                        if !isKeyboardMoveSelectionActive {
                            _ = startKeyboardMoveSelection()
                        }
                    case .detach:
                        if shouldAllowDetach() { handleToolbarAction(.detach) }
                    case .pin, .scrollCapture:
                        if !isEditorMode { handleToolbarAction(action) }
                    default:
                        handleToolbarAction(action)
                    }
                    return
                }
            }
            if event.modifierFlags.contains(.command) {
                // Editing and history commands are handled in performKeyEquivalent.
                // Only Cmd+S and zoom shortcuts remain here.
                if KeyboardShortcutMatcher.matches(event, character: "s", modifiers: .command) {
                    if state == .selected {
                        overlayDelegate?.overlayViewDidRequestSave()
                    }
                    return
                }
                let commandModifiers = KeyboardShortcutMatcher.modifiers(in: event)
                let isCommandCharacter = commandModifiers == .command
                    || commandModifiers == [.command, .shift]
                let commandCharacter = KeyboardShortcutMatcher.semanticCharacter(for: event)
                if isCommandCharacter && commandCharacter == "0" {
                    // Cmd+0 resets zoom in the editor only; the capture overlay
                    // doesn't zoom.
                    if isInsideScrollView, let sv = enclosingScrollView {
                        sv.magnification = 1.0
                        findTopBar()?.updateZoom(1.0)
                    }
                    return
                }
                if isInsideScrollView {
                    if isCommandCharacter && (commandCharacter == "=" || commandCharacter == "+") {
                        if let sv = enclosingScrollView, let doc = sv.documentView {
                            let newMag = min(sv.maxMagnification, sv.magnification * 1.25)
                            sv.setMagnification(newMag, centeredAt: NSPoint(x: doc.bounds.midX, y: doc.bounds.midY))
                            findTopBar()?.updateZoom(newMag)
                        }
                        return
                    }
                    if isCommandCharacter && commandCharacter == "-" {
                        if let sv = enclosingScrollView, let doc = sv.documentView {
                            let newMag = max(sv.minMagnification, sv.magnification / 1.25)
                            sv.setMagnification(newMag, centeredAt: NSPoint(x: doc.bounds.midX, y: doc.bounds.midY))
                            findTopBar()?.updateZoom(newMag)
                        }
                        return
                    }
                    if isCommandCharacter && commandCharacter == "1" {
                        if let sv = enclosingScrollView, let doc = sv.documentView {
                            let unscaledW = doc.frame.width / sv.magnification
                            let unscaledH = doc.frame.height / sv.magnification
                            guard unscaledW > 0, unscaledH > 0 else { return }
                            let clipSize = sv.contentView.bounds.size
                            let fitMag = min(clipSize.width / unscaledW, clipSize.height / unscaledH)
                            let clamped = max(sv.minMagnification, min(sv.maxMagnification, fitMag))
                            sv.magnification = clamped
                            findTopBar()?.updateZoom(clamped)
                        }
                        return
                    }
                }
            }
            super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        if isKeyboardMoveSelectionActive && eventEndsKeyboardMoveSelection(event) {
            endKeyboardMoveSelection()
            return
        }
        if event.keyCode == 49 && spaceRepositioning {
            spaceRepositioning = false
            return
        }
        if event.keyCode == 49 && textEditView == nil
            && !event.modifierFlags.contains(.command)
            && !event.modifierFlags.contains(.option)
            && !event.modifierFlags.contains(.control) {
            return
        }
        // Clear auto-measure preview on key release (click to commit instead)
        if let char = event.charactersIgnoringModifiers, char == "1" || char == "2" {
            if autoMeasureKeyHeld {
                autoMeasureKeyHeld = false
                autoMeasurePreview = nil
                autoMeasureBitmapCtx = nil  // free cached bitmap
                needsDisplay = true
                return
            }
        }
        super.keyUp(with: event)
    }
}
