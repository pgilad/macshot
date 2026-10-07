import Cocoa

/// Toolbar layout, toolbar actions and the tool options API used by ToolOptionsRowView.
extension OverlayView {

    // MARK: - Custom Color Persistence

    func saveCustomColors() {
        let hexArray = customColors.map { color -> String in
            guard let c = color else { return "" }
            return colorToHexString(c)
        }
        UserDefaults.standard.set(hexArray, forKey: "customColors")
    }

    // MARK: - Toolbar Layout

    /// Rebuild toolbar button content. Call when tool, color, or state changes — NOT on every draw.
    func rebuildToolbarLayout() {
        // Clear tooltip before rebuilding — old button views are about to be destroyed
        hoveredTooltip = nil
        hoveredTooltipButtonView = nil

        let movableAnnotations = annotations.contains { $0.isMovable }
        bottomButtons = ToolbarLayout.bottomButtons(
            selectedTool: currentTool, selectedColor: currentColor,
            beautifyEnabled: beautifyEnabled, beautifyStyleIndex: beautifyStyleIndex,
            hasAnnotations: movableAnnotations,
            effectsActive: effectsActive
        )
        if showBeautifyInOptionsRow {
            for i in bottomButtons.indices {
                if case .tool = bottomButtons[i].action {
                    bottomButtons[i].isSelected = false
                } else if case .beautify = bottomButtons[i].action {
                    bottomButtons[i].isSelected = true
                }
            }
        }
        rightButtons = ToolbarLayout.rightButtons(
            beautifyEnabled: beautifyEnabled, beautifyStyleIndex: beautifyStyleIndex,
            hasAnnotations: movableAnnotations,
            isEditorMode: isEditorMode)

        // Create strip views if needed — add to chrome parent (window content) when in scroll view
        let parent = chromeParentView ?? self
        if bottomStripView == nil {
            let strip = ToolbarStripView(orientation: .horizontal)
            parent.addSubview(strip)
            bottomStripView = strip
        }
        if rightStripView == nil {
            let strip = ToolbarStripView(orientation: .vertical)
            parent.addSubview(strip)
            rightStripView = strip
        }

        // Update existing buttons if count matches, rebuild only if structure changed
        if bottomStripView?.buttonViews.count == bottomButtons.count && bottomStripView?.buttonViews.count ?? 0 > 0 {
            bottomStripView?.updateState(from: bottomButtons)
        } else {
            bottomStripView?.setButtons(bottomButtons)
            bottomStripView?.onClick = { [weak self] action in self?.handleToolbarAction(action) }
            bottomStripView?.onRightClick = { [weak self] action, view in
                self?.handleToolbarButtonRightClick(action, anchorView: view)
            }
            bottomStripView?.onHover = { [weak self] action, hovered in
                self?.handleToolbarButtonHover(action, hovered: hovered, strip: self?.bottomStripView)
            }
        }
        if rightStripView?.buttonViews.count == rightButtons.count && rightStripView?.buttonViews.count ?? 0 > 0 {
            rightStripView?.updateState(from: rightButtons)
        } else {
            rightStripView?.setButtons(rightButtons)
            rightStripView?.onClick = { [weak self] action in self?.handleToolbarAction(action) }
            rightStripView?.onRightClick = { [weak self] action, view in
                self?.handleToolbarButtonRightClick(action, anchorView: view)
            }
            rightStripView?.onHover = { [weak self] action, hovered in
                self?.handleToolbarButtonHover(action, hovered: hovered, strip: self?.rightStripView)
            }
        }
        // Move button needs onMouseDown for press-and-drag (synchronous tracking loop)
        for bv in rightStripView?.buttonViews ?? [] {
            if case .moveSelection = bv.action, bv.onMouseDown == nil {
                bv.onMouseDown = { [weak self] _ in self?.handleToolbarAction(.moveSelection) }
            }
        }

        // Rebuild options row content
        if toolHasOptionsRow {
            if toolOptionsRowView == nil {
                let row = ToolOptionsRowView()
                row.overlayView = self
                parent.addSubview(row)
                toolOptionsRowView = row
            }
            // Don't overwrite annotation-specific options when editing a selected annotation
            if let ann = selectedAnnotation, toolOptionsRowView?.editingAnnotation === ann {
                // Already showing this annotation's options — skip rebuild
            } else {
                toolOptionsRowView?.rebuild(for: currentTool)
            }
        }

        repositionToolbars()
        updateResolutionBox()
    }

    /// Reposition toolbar strips based on current selection/bounds. Cheap — safe to call from draw().
    func repositionToolbars() {
        guard let bottomStrip = bottomStripView, let rightStrip = rightStripView else { return }

        // In editor mode, let toolbar gap clicks pass through to the image beneath
        bottomStrip.passesThrough = isEditorMode
        rightStrip.passesThrough = isEditorMode

        let visible = showToolbars && state == .selected && !isScrollCapturing
        let bottomHasButtons = bottomStrip.buttonViews.count > 0
        bottomStrip.isHidden = !visible || !bottomHasButtons
        let rightHasButtons = rightStrip.buttonViews.count > 0
        rightStrip.isHidden = !visible || !rightHasButtons
        toolOptionsRowView?.isHidden = !visible || !toolHasOptionsRow || !bottomHasButtons
        guard visible else {
            // Toolbars hidden (deselected / scroll capture): dismiss the
            // resolution box and clear the chrome rects so isPointOnChrome
            // doesn't see stale areas.
            dismissResolutionBox()
            optionsRowRect = .zero
            return
        }

        // Anchor rect: beautify-expanded when active, selection otherwise
        let config = beautifyConfig
        let bPad = config.padding
        let titleBarH: CGFloat = config.mode == .window ? 28 : 0
        let expandedAnchor = NSRect(
            x: selectionRect.minX - bPad, y: selectionRect.minY - bPad,
            width: selectionRect.width + bPad * 2,
            height: selectionRect.height + titleBarH + bPad * 2)
        let anchorRect: NSRect
        if beautifyToolbarAnimProgress < 1.0 {
            let t = beautifyToolbarAnimProgress
            let eased = 1.0 - (1.0 - t) * (1.0 - t)
            let fromRect = beautifyToolbarAnimTarget ? selectionRect : expandedAnchor
            let toRect = beautifyToolbarAnimTarget ? expandedAnchor : selectionRect
            anchorRect = NSRect(
                x: fromRect.minX + (toRect.minX - fromRect.minX) * eased,
                y: fromRect.minY + (toRect.minY - fromRect.minY) * eased,
                width: fromRect.width + (toRect.width - fromRect.width) * eased,
                height: fromRect.height + (toRect.height - fromRect.height) * eased
            )
        } else if beautifyEnabled && !isScrollCapturing {
            anchorRect = expandedAnchor
        } else {
            anchorRect = selectionRect
        }

        let rightSize = rightStrip.frame.size

        let bottomSize = bottomStrip.frame.size

        if isEditorMode {
            let cb = chromeParentView?.bounds ?? bounds
            bottomStrip.frame.origin = NSPoint(x: cb.midX - bottomSize.width / 2, y: 20)
            bottomStrip.autoresizingMask = [.minXMargin, .maxXMargin, .maxYMargin]
            rightStrip.frame.origin = NSPoint(
                x: cb.maxX - rightSize.width - 20, y: cb.maxY - rightSize.height - 36)
            rightStrip.autoresizingMask = [.minXMargin, .minYMargin]
        } else {
            let optRowH: CGFloat = 38  // options row height + gap

            // ── 1. Position right bar (anchored to selection edge) ──
            let rightMargin: CGFloat = 50
            let rightFitsRight = anchorRect.maxX < bounds.maxX - rightMargin
            let rightFitsLeft = anchorRect.minX > bounds.minX + rightMargin

            // For very narrow selections, put the right bar below instead of to the side
            let selectionTooNarrow = !rightFitsRight && !rightFitsLeft
                && anchorRect.width < bounds.width * 0.5

            var rx: CGFloat
            var ry: CGFloat

            if selectionTooNarrow {
                // Place right bar below the selection, right-aligned
                rx = anchorRect.maxX - rightSize.width
                rx = max(bounds.minX + 4, min(rx, bounds.maxX - rightSize.width - 4))
                ry = anchorRect.minY - rightSize.height - 6
                ry = max(bounds.minY + 4, min(ry, bounds.maxY - rightSize.height - 4))
            } else {
                if rightFitsRight {
                    rx = anchorRect.maxX + 6
                } else if rightFitsLeft {
                    rx = anchorRect.minX - rightSize.width - 6
                } else {
                    rx = selectionRect.maxX - rightSize.width - 6
                }
                rx = max(bounds.minX + 4, min(rx, bounds.maxX - rightSize.width - 4))

                ry = anchorRect.maxY - rightSize.height
                ry = max(bounds.minY + 4, min(ry, bounds.maxY - rightSize.height - 4))
            }

            // ── 2. Choose bottom bar Y, preferring positions that don't overlap right bar ──
            let belowY = anchorRect.minY - bottomSize.height - 6
            let belowFits = (belowY - optRowH) >= bounds.minY + 4
            let aboveY = anchorRect.maxY + optRowH + 6
            let aboveFits = (aboveY + bottomSize.height) <= bounds.maxY - 4

            // Helper: does a bottom bar at candidate Y (centered) overlap the right bar?
            let centeredBx = anchorRect.midX - bottomSize.width / 2
            let clampedCenteredBx = max(bounds.minX + 4, min(centeredBx, bounds.maxX - bottomSize.width - 4))
            func wouldOverlapRight(candidateY: CGFloat) -> Bool {
                let bMinY = candidateY - optRowH
                let bMaxY = candidateY + bottomSize.height
                guard bMaxY > ry && bMinY < ry + rightSize.height else { return false }
                let bMaxX = clampedCenteredBx + bottomSize.width
                let bMinX = clampedCenteredBx
                return bMaxX > rx && bMinX < rx + rightSize.width
            }

            var by: CGFloat
            if belowFits && !wouldOverlapRight(candidateY: belowY) {
                by = belowY
            } else if aboveFits && !wouldOverlapRight(candidateY: aboveY) {
                by = aboveY
            } else if belowFits {
                by = belowY  // overlaps but at least fits vertically
            } else if aboveFits {
                by = aboveY
            } else {
                by = selectionRect.minY + optRowH + 6
                by = max(bounds.minY + optRowH + 4, min(by, bounds.maxY - bottomSize.height - 4))
            }

            // ── 3. Position bottom bar X, avoiding right bar if they overlap vertically ──
            var bx = clampedCenteredBx
            let bottomMinY = by - optRowH
            let bottomMaxY = by + bottomSize.height
            let overlapsVertically = bottomMaxY > ry && bottomMinY < ry + rightSize.height

            if overlapsVertically {
                // Check if centered bottom bar already clears the right bar horizontally
                if bx + bottomSize.width <= rx - 4 || bx >= rx + rightSize.width + 4 {
                    // No overlap — keep both as-is
                } else {
                    // Overlap: move the RIGHT bar out of the way, keep bottom bar centered.
                    // Try pushing right bar further right (past bottom bar's right edge).
                    let pushRight = bx + bottomSize.width + 4
                    // Try pushing right bar to the left (before bottom bar's left edge).
                    let pushLeft = bx - rightSize.width - 4

                    if pushRight + rightSize.width <= bounds.maxX - 4 {
                        rx = pushRight
                    } else if pushLeft >= bounds.minX + 4 {
                        rx = pushLeft
                    } else {
                        // Right bar can't dodge horizontally — push it vertically.
                        // Try below the bottom bar + options row zone.
                        let rightPushDown = by - optRowH - rightSize.height - 4
                        if rightPushDown >= bounds.minY + 4 {
                            ry = rightPushDown
                        } else {
                            // Try above the bottom bar
                            let rightPushUp = by + bottomSize.height + 4
                            if rightPushUp + rightSize.height <= bounds.maxY - 4 {
                                ry = rightPushUp
                            }
                            // else: truly no room, accept overlap
                        }
                    }
                }
            }

            // The resolution box is positioned independently from the toolbar
            // strips. During live selection/annotation resizing it can already
            // be visible when this method runs, so make the side toolbar treat
            // it as an obstacle too. Prefer moving the side toolbar farther to
            // the right; that preserves the user's mental model of "actions sit
            // beside the selection" when there is still room on that side.
            if shouldShowResolutionBox(), resolutionBoxRect.width > 1, resolutionBoxRect.height > 1 {
                let gap: CGFloat = 6
                let avoidRect = resolutionBoxRect.insetBy(dx: -gap, dy: -gap)
                let candidate = NSRect(x: rx, y: ry, width: rightSize.width, height: rightSize.height)
                if candidate.intersects(avoidRect) {
                    let pushRight = avoidRect.maxX + gap
                    let pushLeft = avoidRect.minX - rightSize.width - gap
                    let pushUp = avoidRect.maxY + gap
                    let pushDown = avoidRect.minY - rightSize.height - gap

                    if pushRight + rightSize.width <= bounds.maxX - 4 {
                        rx = pushRight
                    } else if pushLeft >= bounds.minX + 4 {
                        rx = pushLeft
                    } else if pushUp + rightSize.height <= bounds.maxY - 4 {
                        ry = pushUp
                    } else if pushDown >= bounds.minY + 4 {
                        ry = pushDown
                    }
                }
            }

            bx = max(bounds.minX + 4, min(bx, bounds.maxX - bottomSize.width - 4))
            rx = max(bounds.minX + 4, min(rx, bounds.maxX - rightSize.width - 4))
            ry = max(bounds.minY + 4, min(ry, bounds.maxY - rightSize.height - 4))

            // Keep the right bar clear of the notch / camera housing. The
            // resolution box already does this (loweredBelowTopObstructions); the
            // right strip had no such limit, so its top button could land under
            // the notch. Push it down so its top edge sits below any top
            // obstruction it would overlap (using the final rx so the horizontal
            // overlap test matches the placed strip).
            let topObstructions = screenTopObstructionRects().map { $0.insetBy(dx: -4, dy: -2) }
            for obstruction in topObstructions {
                let rightFrame = NSRect(x: rx, y: ry, width: rightSize.width, height: rightSize.height)
                guard rightFrame.intersects(obstruction) else { continue }
                ry = min(ry, obstruction.minY - rightSize.height - 2)
            }
            ry = max(bounds.minY + 4, ry)

            bottomStrip.frame.origin = NSPoint(x: bx, y: by)
            rightStrip.frame.origin = NSPoint(x: rx, y: ry)
        }

        // bottomBarRect is the intended OVERLAY-space rect. Build it from the
        // strip's size + the origin we just set (rather than reading back the
        // live frame, which is panel-local when the strip is glass-panel-hosted).
        bottomBarRect = NSRect(origin: bottomStrip.frame.origin, size: bottomStrip.frame.size)
        rightBarRect = rightStrip.frame

        // Position options row — above bottom bar in editor, below in overlay
        if let row = toolOptionsRowView, !row.isHidden {
            // Use the wider of the bottom bar and the row's natural content width
            let rowW = max(bottomBarRect.width, row.contentWidth)
            row.frame.size.width = rowW
            let rowY: CGFloat
            if isEditorMode {
                // In editor mode, center the options row the same way as the bottom bar
                let cb = chromeParentView?.bounds ?? bounds
                let rowX = max(4, cb.midX - rowW / 2)
                row.frame.origin = NSPoint(x: rowX, y: bottomBarRect.maxY + 2)
                row.autoresizingMask = [.minXMargin, .maxXMargin, .maxYMargin]
            } else {
                // Center the options row relative to the bottom bar, clamped to view bounds
                var rowX = bottomBarRect.midX - rowW / 2
                rowX = max(4, min(rowX, bounds.maxX - rowW - 4))
                rowY = bottomBarRect.minY - row.frame.height - 2
                row.frame.origin = NSPoint(x: rowX, y: rowY)
            }
            optionsRowRect = NSRect(origin: row.frame.origin, size: row.frame.size)
        } else {
            optionsRowRect = .zero
        }
    }

    /// Liquid Glass: lift each toolbar surface (bottom strip, right strip, tool
    /// options row) into a floating child panel above the overlay window,
    /// positioned at its screen rect, so its glass refracts the overlay
    /// (screenshot + dim) beneath. `repositionToolbars` has just set the intended
    /// OVERLAY-space frames; we use those (not the live panel-local frames).
    /// Dismiss the resolution box. It is recreated on demand by
    /// updateResolutionBox(), so it's fully disposed (not just hidden) on
    /// deselect to avoid leaving a stray box behind.
    func dismissResolutionBox() {
        resolutionBox?.removeFromSuperview()
        resolutionBox = nil
        resolutionBoxRect = .zero
    }

    // MARK: - Toolbar Actions

    /// Handle right-click on a toolbar button (context menus, popovers).
    private func handleToolbarButtonHover(_ action: ToolbarButtonAction, hovered: Bool, strip: ToolbarStripView?) {
        if isToolbarMoveDragActive { return }
        if hovered {
            let btn = strip?.buttonViews.first { bv in
                // Compare by identity — find the button that triggered the hover
                if case .tool(let t1) = bv.action, case .tool(let t2) = action { return t1 == t2 }
                // For non-tool actions, compare string representation
                return "\(bv.action)" == "\(action)"
            }
            hoveredTooltip = toolbarTooltipText(for: action, base: btn?.tooltipText)
            hoveredTooltipButtonView = btn
        } else {
            hoveredTooltip = nil
            hoveredTooltipButtonView = nil
        }
        needsDisplay = true
    }

    private func toolbarTooltipText(for action: ToolbarButtonAction, base: String?) -> String? {
        guard let base, !base.isEmpty else { return base }
        guard tooltipShortcutDisplayEnabled,
              let shortcut = ToolShortcutManager.tooltipShortcut(for: action)
        else { return base }
        return "\(base) (\(shortcut))"
    }

    func clearToolbarHoverState(
        suppressUntilMouseMoved: Bool = false,
        clearTooltip: Bool = true,
        clearPressed: Bool = true
    ) {
        if clearTooltip {
            hoveredTooltip = nil
            hoveredTooltipButtonView = nil
        }
        bottomStripView?.clearInteractionState(
            suppressHoverUntilMouseMoved: suppressUntilMouseMoved,
            clearPressed: clearPressed)
        rightStripView?.clearInteractionState(
            suppressHoverUntilMouseMoved: suppressUntilMouseMoved,
            clearPressed: clearPressed)
        needsDisplay = true
    }

    func showMoveDragTooltip(anchor moveButton: ToolbarButtonView?) {
        hoveredTooltip = "Release to finish"
        hoveredTooltipButtonView = moveButton
        needsDisplay = true
    }

    func moveSelectionButtonView() -> ToolbarButtonView? {
        rightStripView?.buttonViews.first {
            if case .moveSelection = $0.action { return true }
            return false
        }
    }

    func eventEndsKeyboardMoveSelection(_ event: NSEvent) -> Bool {
        if keyboardMoveSelectionShortcut == " " {
            return event.keyCode == 49
        }
        return !keyboardMoveSelectionShortcut.isEmpty
            && KeyboardShortcutMatcher.toolCharacters(for: event).contains(keyboardMoveSelectionShortcut)
    }

    func canStartKeyboardMoveSelection() -> Bool {
        state == .selected
            && !isEditorMode
            && textEditView == nil
            && !isScrollCapturing
            && !isAnchoredSelecting
            && !isResizingSelection
            && !isDraggingSelection
            && currentAnnotation == nil
            && !isDraggingAnnotation
            && !isResizingAnnotation
            && !isRotatingAnnotation
            && !isCropDragging
            && !isResizingTextBox
            && !PopoverHelper.isVisible
    }

    func updateKeyboardMoveSelection(to point: NSPoint, modifiers: NSEvent.ModifierFlags) {
        guard isKeyboardMoveSelectionActive else { return }
        var moved = selectionRect
        moved.origin = NSPoint(
            x: point.x - keyboardMoveSelectionOffset.x,
            y: point.y - keyboardMoveSelectionOffset.y)
        selectionRect = boundarySnappedMovedRect(moved, modifiers: modifiers)
        updateResolutionBox()
        repositionToolbars()
        showMoveDragTooltip(anchor: moveSelectionButtonView())
        needsDisplay = true
    }

    func endKeyboardMoveSelection() {
        guard isKeyboardMoveSelectionActive else { return }
        isKeyboardMoveSelectionActive = false
        keyboardMoveSelectionShortcut = ""
        boundarySnapGuideX = nil
        boundarySnapGuideY = nil
        let moveButton = moveSelectionButtonView()
        moveButton?.isPressed = false
        moveButton?.needsDisplay = true
        moveButton?.displayIfNeeded()
        clearToolbarHoverState(suppressUntilMouseMoved: true)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.clearToolbarHoverState(suppressUntilMouseMoved: true)
            self.setToolbarHoverSuppressed(false)
            self.isToolbarMoveDragActive = false
        }
    }

    func setToolbarHoverSuppressed(_ suppressed: Bool) {
        bottomStripView?.suppressesHover = suppressed
        rightStripView?.suppressesHover = suppressed
    }

    /// True if `btn` belongs to `strip` (direct subview or via the strip's view
    /// tree — covers both in-overlay and glass-chrome-panel hosting).
    private func isButton(_ btn: NSView, inStrip strip: ToolbarStripView?) -> Bool {
        guard let strip else { return false }
        var v: NSView? = btn
        while let cur = v {
            if cur === strip { return true }
            v = cur.superview
        }
        return strip.buttonViews.contains { $0 === btn }
    }

    func drawHoveredTooltip() {
        // In editor mode, tooltips are drawn via a floating NSView in the chrome parent
        if isEditorMode {
            updateEditorTooltipView()
            return
        }

        guard let tooltip = hoveredTooltip, !tooltip.isEmpty,
              let btn = hoveredTooltipButtonView,
              !PopoverHelper.isVisible else { return }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: ToolbarLayout.iconColor,
        ]
        let str = tooltip as NSString
        let textSize = str.size(withAttributes: attrs)
        let pad: CGFloat = 6
        let tipW = textSize.width + pad * 2
        let tipH = textSize.height + pad

        // Convert the button's rect to OverlayView coordinates. The button may
        // live in a separate glass chrome panel (different window), so go through
        // screen coordinates rather than a same-window convert (which would
        // misplace the tooltip far off, e.g. screen-left).
        let btnFrame: NSRect
        if let btnWindow = btn.window, let selfWindow = window, btnWindow !== selfWindow {
            let inBtnWindow = btn.convert(btn.bounds, to: nil)
            let screenRect = btnWindow.convertToScreen(inBtnWindow)
            let inSelfWindow = selfWindow.convertFromScreen(screenRect)
            btnFrame = convert(inSelfWindow, from: nil)
        } else {
            btnFrame = btn.convert(btn.bounds, to: self)
        }
        // The button is hosted in a strip; find which strip via the panel chain.
        let isBottomBar = isButton(btn, inStrip: bottomStripView)
        let tipRect: NSRect

        if isBottomBar {
            // Above bottom bar, or below if no room
            var tipY = bottomBarRect.maxY + 4
            if tipY + tipH > bounds.maxY - 2 { tipY = bottomBarRect.minY - tipH - 4 }
            tipRect = NSRect(x: btnFrame.midX - tipW / 2, y: tipY, width: tipW, height: tipH)
        } else {
            // Left of right bar
            tipRect = NSRect(x: btnFrame.minX - tipW - 6, y: btnFrame.midY - tipH / 2, width: tipW, height: tipH)
        }

        // Clamp to bounds
        let clamped = NSRect(
            x: max(bounds.minX + 2, min(tipRect.minX, bounds.maxX - tipW - 2)),
            y: max(bounds.minY + 2, min(tipRect.minY, bounds.maxY - tipH - 2)),
            width: tipW, height: tipH)

        ToolbarLayout.bgColor.setFill()
        NSBezierPath(roundedRect: clamped, xRadius: 4, yRadius: 4).fill()
        str.draw(at: NSPoint(x: clamped.minX + pad, y: clamped.minY + pad / 2), withAttributes: attrs)
    }

    /// In editor mode, show tooltip as a floating NSView in the chrome parent (container),
    /// since EditorView's draw() can only paint within the image bounds.
    private func updateEditorTooltipView() {
        guard let parent = chromeParentView else {
            editorTooltipView?.removeFromSuperview()
            editorTooltipView = nil
            return
        }

        guard let tooltip = hoveredTooltip, !tooltip.isEmpty,
              let btn = hoveredTooltipButtonView,
              !PopoverHelper.isVisible else {
            editorTooltipView?.removeFromSuperview()
            editorTooltipView = nil
            return
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let str = tooltip as NSString
        let textSize = str.size(withAttributes: attrs)
        let pad: CGFloat = 6
        let tipW = textSize.width + pad * 2
        let tipH = textSize.height + pad

        let btnFrame = btn.convert(btn.bounds, to: parent)
        let isBottomBar = btn.superview === bottomStripView
        let tipRect: NSRect

        if isBottomBar {
            let stripFrame = bottomStripView?.frame ?? .zero
            var tipY = stripFrame.maxY + 4
            if tipY + tipH > parent.bounds.maxY - 2 { tipY = stripFrame.minY - tipH - 4 }
            tipRect = NSRect(x: btnFrame.midX - tipW / 2, y: tipY, width: tipW, height: tipH)
        } else {
            tipRect = NSRect(x: btnFrame.minX - tipW - 6, y: btnFrame.midY - tipH / 2, width: tipW, height: tipH)
        }

        let clamped = NSRect(
            x: max(parent.bounds.minX + 2, min(tipRect.minX, parent.bounds.maxX - tipW - 2)),
            y: max(parent.bounds.minY + 2, min(tipRect.minY, parent.bounds.maxY - tipH - 2)),
            width: tipW, height: tipH)

        let tip: TooltipBackgroundView
        if let existing = editorTooltipView as? TooltipBackgroundView {
            tip = existing
        } else {
            editorTooltipView?.removeFromSuperview()
            tip = TooltipBackgroundView(frame: clamped)
            parent.addSubview(tip)
            editorTooltipView = tip
        }
        tip.frame = clamped
        tip.text = tooltip
        tip.needsDisplay = true
    }

    private func handleToolbarButtonRightClick(_ action: ToolbarButtonAction, anchorView: NSView) {
        switch action {
        case .autoRedact:
            showRedactTypePopover(
                anchorRect: anchorView.convert(anchorView.bounds, to: self), anchorView: anchorView)
        case .save:
            let menu = NSMenu()
            switch SaveActionPreference.current {
            case .saveToFolder:
                let saveAsItem = NSMenuItem(
                    title: "Save As...", action: #selector(saveAsMenuAction), keyEquivalent: "")
                saveAsItem.target = self
                menu.addItem(saveAsItem)
            case .askWhereToSave:
                let folderName = URL(fileURLWithPath: SaveDirectoryAccess.displayPath).lastPathComponent
                let saveToFolderItem = NSMenuItem(
                    title: "Save to \(folderName)",
                    action: #selector(saveToFolderMenuAction),
                    keyEquivalent: "")
                saveToFolderItem.target = self
                menu.addItem(saveToFolderItem)
            }
            menu.popUp(
                positioning: nil, at: NSPoint(x: 0, y: anchorView.bounds.height), in: anchorView)
        default:
            break
        }
    }

    /// Update the color swatch on the main toolbar's color button without a full rebuild.
    func updateToolbarColorSwatch() {
        if let idx = bottomButtons.firstIndex(where: { if case .color = $0.action { return true } else { return false } }) {
            bottomButtons[idx].bgColor = currentColor
            bottomStripView?.updateState(from: bottomButtons)
            // Schedule button redraw on next run loop iteration so it happens after
            // the overlay's own draw pass (which can paint over button subviews).
            if idx < (bottomStripView?.buttonViews.count ?? 0) {
                let buttonView = bottomStripView?.buttonViews[idx]
                DispatchQueue.main.async {
                    buttonView?.needsDisplay = true
                }
            }
        }
    }

    func handleToolbarAction(_ action: ToolbarButtonAction, mousePoint: NSPoint = .zero) {
        switch action {
        case .tool(let tool):
            commitTextFieldIfNeeded()
            showBeautifyInOptionsRow = false  // switch back to tool options
            currentTool = tool
            // Auto-select first emoji when switching to stamp tool with nothing selected
            if tool == .stamp && currentStampImage == nil {
                currentStampImage = StampEmojis.renderEmoji(StampEmojis.common[0])
                currentStampEmoji = StampEmojis.common[0]
            }
            needsDisplay = true
        case .loupe:
            currentTool = .loupe
            needsDisplay = true
        case .color:
            if PopoverHelper.toggleClosedIfOpen() { break }
            let colorBtn = bottomStripView?.buttonViews.first { if case .color = $0.action { return true }; return false }
            showColorPickerPopover(target: .drawColor, anchorView: colorBtn)
        case .sizeDisplay:
            break
        case .adjustSelection:
            autoAdjustSelection()
        case .moveSelection:
            guard let win = window else { break }
            isToolbarMoveDragActive = true
            var moveButton = rightStripView?.buttonViews.first {
                if case .moveSelection = $0.action { return true }
                return false
            }
            setToolbarHoverSuppressed(true)
            clearToolbarHoverState(suppressUntilMouseMoved: true, clearPressed: false)
            // Moving breaks window snap — revert to normal beautify mode
            if selectionIsWindowSnap {
                selectionIsWindowSnap = false
                snappedWindowID = nil
                snappedWindowImage = nil
                rebuildToolbarLayout()
                setToolbarHoverSuppressed(true)
                moveButton = rightStripView?.buttonViews.first {
                    if case .moveSelection = $0.action { return true }
                    return false
                }
            }
            moveButton?.isPressed = true
            moveButton?.needsDisplay = true
            moveButton?.displayIfNeeded()
            showMoveDragTooltip(anchor: moveButton)
            needsDisplay = true
            displayIfNeeded()
            // Synchronous drag loop: tracks mouse from button press until release.
            // Convert the current mouse via screen coords (the move button may
            // live in a glass chrome panel, so events target that window, not the
            // overlay — we read app-wide events and map by screen location).
            func overlayPoint(fromScreen screen: NSPoint) -> NSPoint {
                convert(win.convertPoint(fromScreen: screen), from: nil)
            }
            let startPoint = overlayPoint(fromScreen: NSEvent.mouseLocation)
            let offset = NSPoint(x: startPoint.x - selectionRect.origin.x, y: startPoint.y - selectionRect.origin.y)
            while true {
                guard let event = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp],
                                                  until: .distantFuture, inMode: .eventTracking, dequeue: true) else { break }
                let point = overlayPoint(fromScreen: NSEvent.mouseLocation)
                var moved = selectionRect
                moved.origin = NSPoint(x: point.x - offset.x, y: point.y - offset.y)
                // Snap the moved selection to nearby image edges (Option bypasses).
                selectionRect = boundarySnappedMovedRect(moved, modifiers: event.modifierFlags)
                updateResolutionBox()  // track the box live during the move drag
                repositionToolbars()
                showMoveDragTooltip(anchor: moveButton)
                needsDisplay = true
                displayIfNeeded()
                if event.type == .leftMouseUp { break }
            }
            // Clear any boundary-snap guide lines left from the move.
            boundarySnapGuideX = nil
            boundarySnapGuideY = nil
            needsDisplay = true
            moveButton?.isPressed = false
            moveButton?.needsDisplay = true
            moveButton?.displayIfNeeded()
            clearToolbarHoverState(suppressUntilMouseMoved: true)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.clearToolbarHoverState(suppressUntilMouseMoved: true)
                self.setToolbarHoverSuppressed(false)
                self.isToolbarMoveDragActive = false
            }
        case .undo:
            undo()
        case .redo:
            redo()
        case .copy:
            overlayDelegate?.overlayViewDidConfirm()
        case .save:
            overlayDelegate?.overlayViewDidRequestSave()
        case .share:
            // Show share picker anchored to the share button, then dismiss on selection
            let shareBtn = rightStripView?.buttonViews.first { if case .share = $0.action { return true }; return false }
            overlayDelegate?.overlayViewDidRequestShare(anchorView: shareBtn)
        case .pin:
            overlayDelegate?.overlayViewDidRequestPin()
        case .ocr:
            overlayDelegate?.overlayViewDidRequestOCR()
        case .autoRedact:
            performAutoRedact()
        case .removeBackground:
            overlayDelegate?.overlayViewDidRequestRemoveBackground()
        case .invertColors:
            invertImageColors()
        case .effects:
            let btn = bottomStripView?.buttonViews.first { if case .effects = $0.action { return true }; return false }
            showEffectsPopover(anchorView: btn)
        case .beautify:
            commitTextFieldIfNeeded()
            stampPreviewPoint = nil
            loupeCursorPoint = .zero
            // Load the custom background eagerly if that style is selected (the
            // beautifyConfig getter no longer does this as a side effect).
            ensureCustomBeautifyBackgroundLoaded()
            showBeautifyInOptionsRow = true
            needsDisplay = true
        case .beautifyStyle:
            beautifyStyleIndex = (beautifyStyleIndex + 1) % BeautifyRenderer.styles.count
            UserDefaults.standard.set(beautifyStyleIndex, forKey: "beautifyStyleIndex")
            needsDisplay = true
        case .delayCapture:
            break
        case .cancel:
            overlayDelegate?.overlayViewDidCancel()
        case .detach:
            overlayDelegate?.overlayViewDidRequestDetach()
        case .scrollCapture:
            overlayDelegate?.overlayViewDidRequestScrollCapture(rect: selectionRect)
        case .addCapture:
            overlayDelegate?.overlayViewDidRequestAddCapture()
        }

        // Rebuild toolbars to reflect new state (selected tool, color, etc.)
        rebuildToolbarLayout()
    }

    func applyColorToTextIfEditing() {
        if textEditor.isEditing {
            textEditor.applyColorToLiveText(color: annotationColor)
        }
    }

    /// Push a property change undo entry. Called by ToolOptionsRowView when editing completes.
    func updateBeautifySwatch(styleIndex: Int) {
        toolOptionsRowView?.updateBeautifySwatch(styleIndex: styleIndex)
    }

    func pushPropertyChangeUndo(annotation: Annotation, snapshot: Annotation) {
        undoStack.append(.propertyChange(annotation: annotation, snapshot: snapshot))
        redoStack.removeAll()
        cachedCompositedImage = nil
    }

    func applyColorToSelectedAnnotation() {
        guard !selectedAnnotations.isEmpty else { return }
        for ann in selectedAnnotations {
            ann.color = opacityAppliedColor(for: ann.tool)
        }
        cachedCompositedImage = nil
        needsDisplay = true
    }

    /// Apply current text formatting from textEditor to selected text annotations (when not actively editing).
    func applyTextFormattingToSelectedAnnotations() {
        guard textEditor.textView == nil else { return }  // skip if actively editing
        var changed = false
        for ann in selectedAnnotations where ann.tool == .text {
            ann.fontSize = textEditor.fontSize
            ann.isBold = textEditor.bold
            ann.isItalic = textEditor.italic
            ann.isUnderline = textEditor.underline
            ann.isStrikethrough = textEditor.strikethrough
            ann.fontFamilyName = textEditor.fontFamily == "System" ? nil : textEditor.fontFamily
            ann.textAlignment = textEditor.alignment
            ann.reRenderTextImage()
            changed = true
        }
        if changed {
            cachedCompositedImage = nil
            needsDisplay = true
        }
    }

    /// Apply current glyph-stroke state to the live NSTextView (if open).
    /// Touches existing text + future typing so the change is visible immediately.
    func applyGlyphStrokeToLiveTextView() {
        guard let tv = textEditor.textView, let storage = tv.textStorage else { return }
        let range = NSRange(location: 0, length: storage.length)
        let enabled = textEditor.glyphStrokeEnabled
        if range.length > 0 {
            OutlineTextRenderer.applyOutline(enabled ? textEditor.glyphStrokeColor : nil,
                                             to: storage, range: range)
        }
        if enabled {
            tv.typingAttributes[.macshotOutlineColor] = textEditor.glyphStrokeColor
        } else {
            tv.typingAttributes.removeValue(forKey: .macshotOutlineColor)
        }
        tv.needsDisplay = true
    }

    /// Apply text background/outline toggle to selected text annotations.
    func applyTextBgOutlineToSelectedAnnotations() {
        guard textEditor.textView == nil else { return }
        var changed = false
        for ann in selectedAnnotations where ann.tool == .text {
            ann.textBgColor = textEditor.bgEnabled ? textEditor.bgColor : nil
            ann.textOutlineColor = textEditor.outlineEnabled ? textEditor.outlineColor : nil
            ann.textGlyphStrokeColor = textEditor.glyphStrokeEnabled ? textEditor.glyphStrokeColor : nil
            ann.reRenderTextImage()
            changed = true
        }
        if changed {
            cachedCompositedImage = nil
        }
    }

    /// Returns currentColor with opacity applied for tools that respect it.
    /// Marker uses a fixed alpha in its draw method; loupe/measure/pixelate/blur are color-independent.
    func opacityAppliedColor(for tool: AnnotationTool) -> NSColor {
        switch tool {
        case .marker, .loupe, .measure, .pixelate, .blur:
            return currentColor
        default:
            return annotationColor
        }
    }

    // MARK: - Tool options API (used by ToolOptionsRowView)

    func activeStrokeWidthForTool(_ tool: AnnotationTool) -> CGFloat {
        switch tool {
        case .number: return currentNumberSize
        case .marker: return currentMarkerSize
        case .loupe: return currentLoupeSize
        default: return currentStrokeWidth
        }
    }

    func setActiveStrokeWidth(_ value: CGFloat, for tool: AnnotationTool) {
        switch tool {
        case .number:
            currentNumberSize = value
            UserDefaults.standard.set(Double(value), forKey: "numberStrokeWidth")
        case .marker:
            currentMarkerSize = value
            UserDefaults.standard.set(Double(value), forKey: "markerStrokeWidth")
        case .loupe:
            currentLoupeSize = value
            UserDefaults.standard.set(Double(value), forKey: "loupeSize")
        default:
            currentStrokeWidth = value
            UserDefaults.standard.set(Double(value), forKey: "currentStrokeWidth")
        }
        needsDisplay = true
    }

    func setActiveStampSize(_ value: CGFloat) {
        currentStampSize = min(256, max(16, value))
        UserDefaults.standard.set(Double(currentStampSize), forKey: "stampSize")
    }

    func setActiveLoupeMagnification(_ value: CGFloat) {
        currentLoupeMagnification = min(6.0, max(1.1, value))
        UserDefaults.standard.set(Double(currentLoupeMagnification), forKey: "loupeMagnification")
        needsDisplay = true
    }

    /// Invalidate the cached layers so loupe appearance changes (outline color/
    /// toggle) repaint immediately.
    func invalidateLoupeCaches() {
        cachedAnnotationLayer = nil
        cachedAnnotationLayerExcludingSelected = nil
        cachedCompositedImage = nil
    }

    func showColorPickerPopover(target: ColorPickerTarget, anchorView: NSView? = nil, anchorRect: NSRect = .zero) {
        colorPickerTarget = target
        let picker = ColorPickerView()
        let initialColor: NSColor
        switch target {
        case .drawColor: initialColor = currentColor
        case .textBg: initialColor = textEditor.bgColor
        case .textOutline: initialColor = textEditor.outlineColor
        case .textGlyphStroke: initialColor = textEditor.glyphStrokeColor
        case .annotationOutline:
            if let data = UserDefaults.standard.data(forKey: "annotationOutlineColor"),
               let c = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) {
                initialColor = c
            } else {
                initialColor = .white
            }
        case .loupeOutline:
            let editingLoupe = toolOptionsRowView?.editingAnnotation.flatMap { $0.tool == .loupe ? $0 : nil }
            initialColor = (editingLoupe ?? selectedAnnotations.first { $0.tool == .loupe })?.outlineColor
                ?? currentLoupeOutlineColor
        }
        picker.setColor(initialColor, opacity: currentColorOpacity)
        picker.customColors = customColors
        picker.selectedColorSlot = selectedColorSlot

        picker.onColorChanged = { [weak self] color in
            guard let self = self else { return }
            self.applyPickedColor(color)
            picker.saveToSelectedSlot(color)
            // Update toolbar color swatches without rebuilding (which destroys the popover anchor)
            self.toolOptionsRowView?.updateSwatchColors()
            self.needsDisplay = true
        }
        picker.onOpacityChanged = { [weak self] opacity in
            guard let self = self else { return }
            self.currentColorOpacity = opacity
            OverlayView.lastUsedOpacity = opacity
            UserDefaults.standard.set(Double(opacity), forKey: "lastUsedColorOpacity")
            self.applyColorToSelectedAnnotation()
            self.needsDisplay = true
        }
        picker.onCustomSlotSelected = { [weak self] idx in
            self?.selectedColorSlot = idx
        }
        picker.onCustomColorsChanged = { [weak self] colors in
            self?.customColors = colors
            self?.saveCustomColors()
        }

        let size = picker.preferredSize
        if let anchor = anchorView {
            PopoverHelper.show(picker, size: size, relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        } else if anchorRect != .zero {
            PopoverHelper.showAtPoint(picker, size: size, at: NSPoint(x: anchorRect.midX, y: anchorRect.midY), in: self, preferredEdge: .minY)
        } else {
            PopoverHelper.showAtPoint(picker, size: size, at: NSPoint(x: bounds.midX, y: bounds.midY), in: self, preferredEdge: .minY)
        }
    }

    private func applyPickedColor(_ color: NSColor) {
        switch colorPickerTarget {
        case .drawColor:
            currentColor = color
            applyColorToTextIfEditing()
            applyColorToSelectedAnnotation()
        case .textBg:
            textEditor.bgColor = color
            if let data = try? NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: false) {
                UserDefaults.standard.set(data, forKey: "textBgColor")
            }
        case .textOutline:
            textEditor.outlineColor = color
            if let data = try? NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: false) {
                UserDefaults.standard.set(data, forKey: "textOutlineColor")
            }
        case .textGlyphStroke:
            textEditor.glyphStrokeColor = color
            if let data = try? NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: false) {
                UserDefaults.standard.set(data, forKey: "textGlyphStrokeColor")
            }
            applyGlyphStrokeToLiveTextView()
            applyTextBgOutlineToSelectedAnnotations()
        case .annotationOutline:
            if let data = try? NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: false) {
                UserDefaults.standard.set(data, forKey: "annotationOutlineColor")
            }
            // Apply to selected annotations
            for ann in selectedAnnotations {
                ann.outlineColor = color
            }
            cachedCompositedImage = nil
        case .loupeOutline:
            currentLoupeOutlineColor = color
            currentLoupeOutlineEnabled = true
            if let data = try? NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: false) {
                UserDefaults.standard.set(data, forKey: "loupeOutlineColor")
            }
            UserDefaults.standard.set(true, forKey: "loupeOutlineEnabled")
            // Apply to the loupe being edited / selected loupes.
            var targets = selectedAnnotations.filter { $0.tool == .loupe }
            if let editing = toolOptionsRowView?.editingAnnotation, editing.tool == .loupe,
               !targets.contains(where: { $0 === editing }) {
                targets.append(editing)
            }
            for ann in targets {
                ann.outlineColor = color
                ann.loupeOutlineEnabled = true
            }
            cachedAnnotationLayer = nil
            cachedAnnotationLayerExcludingSelected = nil
            cachedCompositedImage = nil
            toolOptionsRowView?.updateSwatchColors()
        }
        needsDisplay = true
    }
}

/// Small rounded-rect tooltip view used for editor mode toolbar hover labels.
private class TooltipBackgroundView: NSView {
    var text: String = ""

    override func draw(_ dirtyRect: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: ToolbarLayout.iconColor,
        ]
        ToolbarLayout.bgColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        let pad: CGFloat = 6
        (text as NSString).draw(at: NSPoint(x: pad, y: pad / 2), withAttributes: attrs)
    }
}

