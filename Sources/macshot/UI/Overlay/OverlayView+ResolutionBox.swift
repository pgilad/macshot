import Cocoa

/// The size box, ratio and resolution presets, and the locked aspect ratio.
extension OverlayView {

    // MARK: - Resolution box and presets

    /// Compute where the resolution box sits relative to the selection. Aligns
    /// the box's W↔H midpoint (the "×") with the selection's horizontal center,
    /// so the dimensions read as centered on the selection — the trailing presets
    /// button just overhangs to the right (not counted in the centering).
    private func resolutionBoxFrame(size: NSSize, dimsCenterX: CGFloat) -> NSRect {
        let x = selectionRect.midX - dimsCenterX
        let clampedX = max(bounds.minX + 2, min(x, bounds.maxX - size.width - 2))
        let edgeGap = handleSize / 2 + 3
        let above = selectionRect.maxY + edgeGap
        let below = selectionRect.minY - size.height - edgeGap
        let minY = bounds.minY + 2
        let maxY = bounds.maxY - 2

        func rect(at y: CGFloat) -> NSRect {
            NSRect(x: clampedX, y: y, width: size.width, height: size.height)
        }
        func fits(_ rect: NSRect) -> Bool {
            rect.minY >= minY && rect.maxY <= maxY
        }
        let toolbarAvoidanceRects = resolutionBoxAvoidanceRects().map { $0.insetBy(dx: -4, dy: -4) }
        let topObstructionRects = screenTopObstructionRects().map { $0.insetBy(dx: -4, dy: -2) }
        let avoidanceRects = toolbarAvoidanceRects + topObstructionRects
        func loweredBelowTopObstructions(_ rect: NSRect) -> NSRect {
            var adjusted = rect
            for obstruction in topObstructionRects where adjusted.intersects(obstruction) {
                adjusted.origin.y = min(adjusted.origin.y, obstruction.minY - adjusted.height - 2)
            }
            return adjusted
        }
        func overlapArea(_ rect: NSRect) -> CGFloat {
            avoidanceRects.reduce(CGFloat(0)) { total, occupied in
                let hit = rect.intersection(occupied)
                guard !hit.isNull else { return total }
                return total + max(0, hit.width) * max(0, hit.height)
            }
        }

        let aboveRect = loweredBelowTopObstructions(rect(at: above))
        let belowRect = loweredBelowTopObstructions(rect(at: below))
        let outsideCandidates = [aboveRect, belowRect]
        if let clear = outsideCandidates.first(where: { fits($0) && overlapArea($0) == 0 }) {
            return clear
        }

        let insideTop = loweredBelowTopObstructions(rect(at: selectionRect.maxY - size.height - edgeGap))
        let insideBottom = loweredBelowTopObstructions(rect(at: selectionRect.minY + edgeGap))
        func fitsInsideSelection(_ rect: NSRect) -> Bool {
            rect.minY >= selectionRect.minY + 2 && rect.maxY <= selectionRect.maxY - 2
        }
        let insideCandidates: [NSRect]
        if !fits(aboveRect) && fits(belowRect) {
            insideCandidates = [insideTop, insideBottom]
        } else if !fits(belowRect) && fits(aboveRect) {
            insideCandidates = [insideBottom, insideTop]
        } else {
            insideCandidates = [insideTop, insideBottom]
        }
        let clearInsideCandidates = insideCandidates.filter { fits($0) && fitsInsideSelection($0) }
        if let clearInside = clearInsideCandidates.first(where: { overlapArea($0) == 0 }) {
            return clearInside
        }

        let candidates = outsideCandidates + clearInsideCandidates
        if let leastBlocked = candidates.filter(fits).min(by: { overlapArea($0) < overlapArea($1) }) {
            return leastBlocked
        }
        let clampedY = max(minY, min(above, maxY - size.height))
        let clampedRect = loweredBelowTopObstructions(rect(at: clampedY))
        return fits(clampedRect) ? clampedRect : rect(at: clampedY)
    }

    /// Notched displays expose the unobscured top-left/right menu-bar areas via
    /// NSScreen. The remaining top band is the camera housing area; keep small
    /// floating chrome out of that rect while still allowing it in the safe side
    /// areas on MacBooks with a notch.
    func screenTopObstructionRects() -> [NSRect] {
        guard let screen = window?.screen,
              screen.safeAreaInsets.top > 0 else { return [] }

        let topBandScreen = NSRect(
            x: screen.frame.minX,
            y: screen.frame.maxY - screen.safeAreaInsets.top,
            width: screen.frame.width,
            height: screen.safeAreaInsets.top)

        let topBand = overlayRect(fromScreenRect: topBandScreen)
        guard topBand.width > 1, topBand.height > 1 else { return [] }

        let unobscuredTopAreas = [screen.auxiliaryTopLeftArea, screen.auxiliaryTopRightArea].compactMap { $0 }
            .map { overlayRect(fromScreenRect: $0).intersection(topBand) }
            .filter { !$0.isNull && $0.width > 1 && $0.height > 1 }

        return unobscuredTopAreas.reduce([topBand]) { blockedRects, unobscured in
            blockedRects.flatMap { subtract(unobscured, from: $0) }
        }.filter { $0.width > 1 && $0.height > 1 }
    }

    private func overlayRect(fromScreenRect rect: NSRect) -> NSRect {
        guard rect.width > 0, rect.height > 0 else { return .zero }
        if let win = window {
            return convert(win.convertFromScreen(rect), from: nil)
        }
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) }) {
            return rect.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        }
        return rect
    }

    private func subtract(_ cut: NSRect, from source: NSRect) -> [NSRect] {
        let hit = source.intersection(cut)
        guard !hit.isNull, hit.width > 0, hit.height > 0 else { return [source] }

        var pieces: [NSRect] = []
        if hit.maxY < source.maxY {
            pieces.append(NSRect(x: source.minX, y: hit.maxY, width: source.width, height: source.maxY - hit.maxY))
        }
        if hit.minY > source.minY {
            pieces.append(NSRect(x: source.minX, y: source.minY, width: source.width, height: hit.minY - source.minY))
        }
        if hit.minX > source.minX {
            pieces.append(NSRect(x: source.minX, y: hit.minY, width: hit.minX - source.minX, height: hit.height))
        }
        if hit.maxX < source.maxX {
            pieces.append(NSRect(x: hit.maxX, y: hit.minY, width: source.maxX - hit.maxX, height: hit.height))
        }
        return pieces
    }

    private func resolutionBoxAvoidanceRects() -> [NSRect] {
        guard showToolbars && !isEditorMode && state == .selected && !isScrollCapturing else { return [] }

        var rects: [NSRect] = []
        if bottomStripView?.isHidden == false {
            rects.append(bottomBarRect)
        }
        if toolOptionsRowView?.isHidden == false, optionsRowRect.width > 1, optionsRowRect.height > 1 {
            rects.append(optionsRowRect)
        }
        if rightStripView?.isHidden == false {
            rects.append(rightBarRect)
        }
        return rects.filter { $0.width > 1 && $0.height > 1 }
    }

    /// Create/position/update or remove the resolution box for the current state.
    /// In the Liquid Glass theme the box is hosted in a glass chrome panel (like
    /// the toolbars); otherwise it's a solid-bg overlay subview.
    func updateResolutionBox() {
        guard shouldShowResolutionBox() else {
            dismissResolutionBox()
            return
        }
        // While a W/H field is being edited, leave the box exactly where it is.
        // Re-laying-out mid-edit disturbs the field editor / first responder,
        // which makes typing beep. The selection isn't changing during editing,
        // so there's nothing to update.
        if let editing = resolutionBox, editing.isActivelyEditing { return }

        let box: ResolutionBoxView
        if let existing = resolutionBox {
            box = existing
        } else {
            box = ResolutionBoxView()
            box.onCommit = { [weak self] w, h, edited in
                guard let self else { return }
                if self.applyDisplaySize(w: w, h: h, edited: edited) {
                    self.clearStaleExactPreSelectionPresetIfNeeded()
                }
            }
            box.onFinishEditing = { [weak self] in
                guard let self else { return }
                self.window?.makeKey()
                self.window?.makeFirstResponder(self)
                self.updateResolutionBox()
            }
            box.onPresets = { [weak self] anchor in self?.showResolutionPresets(from: anchor) }
            resolutionBox = box
        }
        let frame = resolutionBoxFrame(size: box.preferredSize, dimsCenterX: box.dimensionsCenterX)
        resolutionBoxRect = frame  // overlay-space rect (for chrome/cursor/zoom anchor)
        let px = selectionDisplaySize
        box.setDimensions(w: px.w, h: px.h)
        box.setActivePresetLabel(preSelectionPresetDisplayLabel)

        // Inline: a solid-bg overlay subview at the overlay-space frame.
        if box.superview !== self { box.removeFromSuperview(); addSubview(box) }
        box.frame = frame
    }

    func refreshResolutionAndToolbarLayout() {
        updateResolutionBox()
        repositionToolbars()
        updateResolutionBox()
    }

    /// Human label of the currently locked aspect ratio, if any.
    private var activeRatioLabel: String? {
        guard let a = lockedAspect else { return nil }
        return ResolutionPresetCatalog.ratios.first {
            if case .ratio(_, let v) = $0 { return abs(v - a) < 0.001 }
            return false
        }?.label
    }

    /// True if a non-nil locked aspect doesn't match any named ratio preset —
    /// i.e. it's a custom ratio (e.g. locked from a typed W×H).
    private var lockedAspectIsCustom: Bool {
        guard let a = lockedAspect, a > 0 else { return false }
        return !ResolutionPresetCatalog.ratios.contains {
            if case .ratio(_, let v) = $0 { return abs(v - a) < 0.001 }
            return false
        }
    }

    /// A compact aspect-ratio label that always fits the popover column. Uses a
    /// small reduced "W : H" only when it reduces cleanly to short numbers
    /// (e.g. 16 : 9, 3 : 1); otherwise a short decimal like "1.62 : 1". Never
    /// shows raw multi-digit pixel dims (which overflowed the column).
    private func ratioLabel(for aspect: CGFloat) -> String {
        guard aspect > 0 else { return "-" }
        let px = selectionPixelSize
        if px.w > 0, px.h > 0, abs(CGFloat(px.w) / CGFloat(px.h) - aspect) < 0.01 {
            let g = Self.gcd(px.w, px.h)
            let rw = px.w / g, rh = px.h / g
            if rw <= 32 && rh <= 32 { return "\(rw) : \(rh)" }
        }
        // Decimal fallback — compact and bounded width.
        if abs(aspect.rounded() - aspect) < 0.001 { return "\(Int(aspect.rounded())) : 1" }
        return String(format: "%.2f : 1", aspect)
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        var a = abs(a), b = abs(b)
        while b != 0 { (a, b) = (b, a % b) }
        return max(a, 1)
    }

    /// The current selection's aspect ratio (w/h) in pixel space, or nil when
    /// there's no usable selection.
    private var currentSelectionAspect: CGFloat? {
        let px = selectionPixelSize
        guard px.w > 0, px.h > 0 else { return nil }
        return CGFloat(px.w) / CGFloat(px.h)
    }

    /// Toggle the presets popover (aspect ratios + common resolutions) from `anchor`.
    private func showResolutionPresets(from anchor: NSView) {
        // Clicking the button while the popover is open should close it.
        if PopoverHelper.toggleClosedIfOpen() { return }
        let activePreset = activePreSelectionPreset
        let view = ResolutionPresetsView()

        let customLocked = lockedAspectIsCustom
        var ratioRows = ResolutionPresetCatalog.ratios.map { preset -> ResolutionPresetsView.Row in
            // When a custom ratio is locked, no named preset (including Freeform)
            // is the active one — the Custom row owns the checkmark.
            let selected = !customLocked && preSelectionPreset(activePreset, selects: preset)
            return ResolutionPresetsView.Row(title: preset.label, isSelected: selected) { [weak self] in
                PopoverHelper.dismiss()
                guard let self else { return }
                // A choice made on an active selection only persists into the
                // next capture when "keep ratio for next captures" is on. When
                // it's off, apply to the current selection but clear any
                // pre-selection preset so the next capture starts freeform.
                if self.keepRatioForNextCaptures {
                    if let aspect = preset.aspectValue {
                        self.setPreSelectionPreset(.ratio(aspect))
                    } else {
                        self.setPreSelectionPreset(.freeform)
                    }
                } else {
                    self.setPreSelectionPreset(.freeform)
                }
                self.applyLockedAspect(preset.aspectValue)
                self.persistRatioIfNeeded()
            }
        }

        // "Custom" row: lock the CURRENT selection's aspect ratio (e.g. one you
        // just set by typing W and H). Shows the live ratio and is checked when a
        // non-preset ratio is locked. Lets you resize while keeping that ratio.
        if let curAspect = currentSelectionAspect {
            let customSelected = customLocked
            let customTitle = customSelected
                ? String(format: "Custom · %@", ratioLabel(for: lockedAspect ?? curAspect))
                : String(format: "Custom · %@", ratioLabel(for: curAspect))
            let customRow = ResolutionPresetsView.Row(title: customTitle, isSelected: customSelected) { [weak self] in
                PopoverHelper.dismiss()
                guard let self else { return }
                let aspect = self.currentSelectionAspect ?? curAspect
                // Persist for the next capture only when keep-ratio is on.
                if self.keepRatioForNextCaptures {
                    self.setPreSelectionPreset(.ratio(aspect))
                } else {
                    self.setPreSelectionPreset(.freeform)
                }
                self.applyLockedAspect(aspect)
                self.persistRatioIfNeeded()
            }
            // Place Custom right after Freeform (index 0) so it sits at the top
            // of the real ratios.
            ratioRows.insert(customRow, at: 1)
        }
        view.ratioRows = ratioRows
        view.resolutionRows = ResolutionPresetCatalog.resolutions.map { preset in
            guard case .resolution(_, let w, let h) = preset else {
                return ResolutionPresetsView.Row(title: preset.label, isSelected: false, action: {})
            }
            return ResolutionPresetsView.Row(title: preset.label, isSelected: preSelectionPreset(activePreset, selects: preset)) { [weak self] in
                PopoverHelper.dismiss()
                guard let self else { return }
                // Same rule for fixed resolutions: only persist for the next
                // capture when keep-ratio is on; otherwise this resolution
                // applies to the current selection only.
                if self.keepRatioForNextCaptures {
                    self.setPreSelectionPreset(.resolution(w: w, h: h))
                } else {
                    self.setPreSelectionPreset(.freeform)
                }
                self.applyLockedAspect(nil)
                self.applyPixelSize(w: w, h: h)
                self.persistRatioIfNeeded()
            }
        }
        view.keepRatioOn = keepRatioForNextCaptures
        view.onToggleKeepRatio = { [weak self] on in
            guard let self else { return }
            self.keepRatioForNextCaptures = on
            self.persistRatioIfNeeded()
            self.refreshResolutionAndToolbarLayout()  // refresh the enforced-icon tint
        }
        view.unitIndex = resolutionUnitIsPoints ? 1 : 0
        view.onPickUnit = { [weak self] idx in
            self?.resolutionUnitIsPoints = (idx == 1)
            self?.refreshResolutionAndToolbarLayout()  // re-display W/H in the new unit
        }
        view.showsAutoAdjustButton = !isEditorMode
        view.autoAdjustShortcut = ToolShortcutManager.tooltipShortcut(for: .adjustSelection)
        view.onAutoAdjust = { [weak self] in
            PopoverHelper.dismiss()
            self?.autoAdjustSelection()
        }
        view.build()
        PopoverHelper.show(view, size: view.preferredSize,
                           relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }

    private var preSelectionPresetStorageKind: PreSelectionPresetStorageKind {
        get {
            PreSelectionPresetStorageKind(
                rawValue: UserDefaults.standard.integer(forKey: Self.preSelectionPresetKindKey))
                ?? .inherited
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Self.preSelectionPresetKindKey) }
    }

    var activePreSelectionPreset: PreSelectionPreset {
        switch preSelectionPresetStorageKind {
        case .freeform:
            return .freeform
        case .ratio:
            let aspect = CGFloat(UserDefaults.standard.double(forKey: Self.preSelectionPresetAspectKey))
            return aspect > 0 ? .ratio(aspect) : .freeform
        case .resolution:
            let w = UserDefaults.standard.integer(forKey: Self.preSelectionPresetWidthKey)
            let h = UserDefaults.standard.integer(forKey: Self.preSelectionPresetHeightKey)
            return w > 0 && h > 0 ? .resolution(w: w, h: h) : .freeform
        case .inherited:
            return keepRatioForNextCaptures && persistedAspect > 0 ? .ratio(persistedAspect) : .freeform
        }
    }

    var activePreSelectionRatio: CGFloat? {
        if case .ratio(let aspect) = activePreSelectionPreset, aspect > 0 { return aspect }
        return nil
    }

    private var preSelectionPresetDisplayLabel: String? {
        switch activePreSelectionPreset {
        case .freeform:
            // A custom ratio can be locked for the current selection even when
            // it isn't persisted for the next capture (keep-ratio off). Surface
            // it so the box/button still shows the active lock.
            if lockedAspectIsCustom, let a = lockedAspect {
                return ratioLabel(for: a)
            }
            return nil
        case .ratio(let aspect):
            return ResolutionPresetCatalog.ratios.first {
                if case .ratio(_, let value) = $0 { return abs(value - aspect) < 0.001 }
                return false
            }?.label ?? ratioLabel(for: aspect)
        case .resolution(let w, let h):
            return ResolutionPresetCatalog.resolutions.first {
                if case .resolution(_, let presetW, let presetH) = $0 {
                    return presetW == w && presetH == h
                }
                return false
            }?.label ?? "\(w) × \(h)"
        }
    }

    private func preSelectionPreset(_ activePreset: PreSelectionPreset, selects preset: ResolutionPreset) -> Bool {
        switch (activePreset, preset) {
        case (.freeform, .freeform):
            return true
        case (.ratio(let active), .ratio(_, let value)):
            return abs(active - value) < 0.001
        case (.resolution(let activeW, let activeH), .resolution(_, let w, let h)):
            return activeW == w && activeH == h
        default:
            return false
        }
    }

    private func clearStaleExactPreSelectionPresetIfNeeded() {
        guard case .resolution(let presetW, let presetH) = activePreSelectionPreset else { return }
        let px = selectionPixelSize
        if px.w != presetW || px.h != presetH {
            setPreSelectionPreset(.freeform)
        }
    }

    var shouldShowPreSelectionPresetButton: Bool {
        state == .idle
            && screenshotImage != nil
            && !isEditorMode
            && !autoOCRMode
            && remoteSelectionRect.width < 1
            && remoteSelectionRect.height < 1
    }

    func showPreSelectionPresetButton(frame: NSRect) {
        let button: PreSelectionPresetButton
        if let existing = preSelectionPresetButton {
            button = existing
        } else {
            button = PreSelectionPresetButton()
            button.target = self
            button.action = #selector(preSelectionPresetButtonClicked(_:))
            preSelectionPresetButton = button
        }

        if button.superview !== self {
            button.removeFromSuperview()
            addSubview(button)
        }

        preSelectionPresetButtonRect = frame
        button.frame = frame
        let label = preSelectionPresetDisplayLabel
        let title = "Aspect ratio & resolution presets"
        button.update(active: label != nil, tooltip: label.map { "\(title): \($0)" } ?? title)
        button.isHidden = false
    }

    func hidePreSelectionPresetButton() {
        preSelectionPresetButton?.isHidden = true
        preSelectionPresetButtonRect = .zero
    }

    @objc private func preSelectionPresetButtonClicked(_ sender: NSButton) {
        showPreSelectionResolutionPresets(from: sender)
    }

    private func setPreSelectionPreset(_ preset: PreSelectionPreset) {
        switch preset {
        case .freeform:
            preSelectionPresetStorageKind = .freeform
            lockedAspect = nil
        case .ratio(let aspect):
            preSelectionPresetStorageKind = .ratio
            UserDefaults.standard.set(Double(aspect), forKey: Self.preSelectionPresetAspectKey)
            lockedAspect = aspect
        case .resolution(let w, let h):
            preSelectionPresetStorageKind = .resolution
            UserDefaults.standard.set(w, forKey: Self.preSelectionPresetWidthKey)
            UserDefaults.standard.set(h, forKey: Self.preSelectionPresetHeightKey)
            lockedAspect = nil
        }
        if state == .selected {
            refreshResolutionAndToolbarLayout()
        }
        preSelectionPresetButton?.update(
            active: preSelectionPresetDisplayLabel != nil,
            tooltip: preSelectionPresetDisplayLabel.map {
                "Aspect ratio & resolution presets: \($0)"
            } ?? "Aspect ratio & resolution presets")
        needsDisplay = true
    }

    private func showPreSelectionResolutionPresets(from anchor: NSView) {
        if PopoverHelper.toggleClosedIfOpen() { return }

        let activePreset = activePreSelectionPreset
        let view = ResolutionPresetsView()
        view.showsKeepRatioToggle = true
        view.showsUnitSelector = false
        view.ratioRows = ResolutionPresetCatalog.ratios.map { preset in
            let selected = preSelectionPreset(activePreset, selects: preset)
            return ResolutionPresetsView.Row(title: preset.label, isSelected: selected) { [weak self] in
                PopoverHelper.dismiss()
                guard let self else { return }
                switch preset {
                case .freeform:
                    self.setPreSelectionPreset(.freeform)
                case .ratio(_, let value):
                    self.setPreSelectionPreset(.ratio(value))
                default:
                    break
                }
            }
        }
        view.resolutionRows = ResolutionPresetCatalog.resolutions.map { preset in
            guard case .resolution(_, let w, let h) = preset else {
                return ResolutionPresetsView.Row(title: preset.label, isSelected: false, action: {})
            }
            let selected = preSelectionPreset(activePreset, selects: preset)
            return ResolutionPresetsView.Row(title: preset.label, isSelected: selected) { [weak self] in
                PopoverHelper.dismiss()
                self?.setPreSelectionPreset(.resolution(w: w, h: h))
            }
        }
        view.keepRatioOn = keepRatioForNextCaptures
        view.onToggleKeepRatio = { [weak self] on in
            guard let self else { return }
            self.keepRatioForNextCaptures = on
            if on, case .ratio(let aspect) = self.activePreSelectionPreset {
                self.persistedAspect = aspect
            } else if !on {
                self.persistedAspect = 0
            }
            self.refreshResolutionAndToolbarLayout()
        }
        view.build()
        PopoverHelper.show(view, size: view.preferredSize,
                           relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }

    /// Persist (or clear) the current locked ratio for future captures, per the
    /// "keep ratio" toggle.
    private func persistRatioIfNeeded() {
        guard keepRatioForNextCaptures else { return }
        persistedAspect = lockedAspect ?? 0
    }

    /// Apply the persisted aspect ratio to a freshly started selection, if the
    /// "keep ratio for next captures" toggle is on. Call when a new capture
    /// overlay/selection begins.
    func applyPersistedRatioIfNeeded() {
        guard keepRatioForNextCaptures, persistedAspect > 0 else { return }
        lockedAspect = persistedAspect
    }

    /// Current selection size in device pixels (rounded, not truncated).
    var selectionPixelSize: (w: Int, h: Int) {
        let scale = window?.backingScaleFactor ?? 2.0
        return (Int((selectionRect.width * scale).rounded()),
                Int((selectionRect.height * scale).rounded()))
    }

    /// Whether the resolution box shows/accepts points (true) or device pixels.
    var resolutionUnitIsPoints: Bool {
        get { UserDefaults.standard.bool(forKey: "resolutionUnitIsPoints") }
        set { UserDefaults.standard.set(newValue, forKey: "resolutionUnitIsPoints") }
    }

    /// Selection size in the user's chosen display unit (px or pt).
    var selectionDisplaySize: (w: Int, h: Int) {
        if resolutionUnitIsPoints {
            return (Int(selectionRect.width.rounded()), Int(selectionRect.height.rounded()))
        }
        return selectionPixelSize
    }

    /// Resize from values typed in the current display unit.
    @discardableResult
    func applyDisplaySize(
        w inputW: Int,
        h inputH: Int,
        edited: ResolutionBoxView.EditedDimension = .both
    ) -> Bool {
        var w = inputW
        var h = inputH
        if let aspect = lockedAspect, aspect > 0 {
            switch edited {
            case .width:
                h = max(1, Int((CGFloat(w) / aspect).rounded()))
            case .height:
                w = max(1, Int((CGFloat(h) * aspect).rounded()))
            case .both:
                break
            }
        }
        if resolutionUnitIsPoints {
            let scale = window?.backingScaleFactor ?? 2.0
            return applyPixelSize(w: Int((CGFloat(w) * scale).rounded()),
                                  h: Int((CGFloat(h) * scale).rounded()))
        }
        return applyPixelSize(w: w, h: h)
    }

    /// Resize the selection to an exact pixel size (W×H in device pixels),
    /// center-anchored and clamped to the screen. Used by the resolution box
    /// fields and resolution presets. Returns true if it fit exactly (no clamp).
    @discardableResult
    func applyPixelSize(w pxW: Int, h pxH: Int) -> Bool {
        guard pxW > 0, pxH > 0 else { return false }
        let scale = window?.backingScaleFactor ?? 2.0
        var newW = CGFloat(pxW) / scale
        var newH = CGFloat(pxH) / scale

        // Clamp to the overlay bounds, preserving aspect so presets don't distort.
        let maxW = bounds.width
        let maxH = bounds.height
        var fits = true
        if newW > maxW || newH > maxH {
            fits = false
            let s = min(maxW / newW, maxH / newH)
            newW *= s
            newH *= s
        }

        // Center on the current selection (or screen center if no selection yet),
        // then shift fully on-screen.
        let cx = selectionRect.width > 0 ? selectionRect.midX : bounds.midX
        let cy = selectionRect.height > 0 ? selectionRect.midY : bounds.midY
        var rect = NSRect(x: cx - newW / 2, y: cy - newH / 2, width: newW, height: newH)
        rect.origin.x = max(bounds.minX, min(rect.origin.x, bounds.maxX - newW))
        rect.origin.y = max(bounds.minY, min(rect.origin.y, bounds.maxY - newH))

        selectionIsWindowSnap = false
        selectionRect = rect
        refreshResolutionAndToolbarLayout()
        refreshCursorAfterSelectionChange()
        needsDisplay = true
        return fits
    }

    /// After a programmatic selection-rect change (typed size, ratio lock,
    /// preset) the cursor is managed imperatively, so re-evaluate it for the
    /// current mouse position — otherwise the resize cursor over a handle isn't
    /// updated until the user moves the mouse.
    private func refreshCursorAfterSelectionChange() {
        guard let win = window else { return }
        let p = convert(win.mouseLocationOutsideOfEventStream, from: nil)
        updateCursorForPoint(p)
    }

    /// Lock (or clear, when nil) the selection's aspect ratio and immediately
    /// reshape the current selection to match (center-anchored, clamped).
    func applyLockedAspect(_ aspect: CGFloat?) {
        lockedAspect = aspect
        selectionIsWindowSnap = false
        guard let aspect, aspect > 0, selectionRect.width > 1 else {
            refreshResolutionAndToolbarLayout()
            needsDisplay = true
            return
        }
        // Reshape to the locked ratio, keeping area roughly similar, centered.
        let cur = selectionRect
        var w = cur.width
        var h = w / aspect
        if h > bounds.height || w > bounds.width {
            let s = min(bounds.width / w, bounds.height / h)
            w *= s; h *= s
        }
        var rect = NSRect(x: cur.midX - w / 2, y: cur.midY - h / 2, width: w, height: h)
        rect.origin.x = max(bounds.minX, min(rect.origin.x, bounds.maxX - w))
        rect.origin.y = max(bounds.minY, min(rect.origin.y, bounds.maxY - h))
        selectionRect = rect
        refreshResolutionAndToolbarLayout()
        refreshCursorAfterSelectionChange()
        needsDisplay = true
    }
}

/// Compact icon-only control shown in the pre-selection helper. It opens the
/// same ratio/resolution presets as the selected-area size control without
/// turning the idle helper into a full toolbar.
final class PreSelectionPresetButton: NSButton {
    private var hovered = false
    private var activePreset = false
    private var trackingArea: NSTrackingArea?

    init() {
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        focusRingType = .none
        setButtonType(.momentaryChange)
        let symbol = NSImage(systemSymbolName: "aspectratio", accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "rectangle.dashed", accessibilityDescription: nil)
        symbol?.isTemplate = true
        image = symbol
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(active: Bool, tooltip: String) {
        activePreset = active
        toolTip = tooltip
        contentTintColor = active ? ToolbarLayout.accentColor : ToolbarLayout.iconColor.withAlphaComponent(0.88)
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        needsDisplay = true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let bg: NSColor
        if isHighlighted {
            bg = ToolbarLayout.accentColor.withAlphaComponent(0.28)
        } else if hovered {
            bg = ToolbarLayout.iconColor.withAlphaComponent(0.14)
        } else {
            bg = NSColor.white.withAlphaComponent(0.07)
        }
        bg.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()

        let stroke = activePreset
            ? ToolbarLayout.accentColor.withAlphaComponent(0.85)
            : ToolbarLayout.iconColor.withAlphaComponent(0.18)
        stroke.setStroke()
        let border = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        border.lineWidth = activePreset ? 1.3 : 1.0
        border.stroke()

        super.draw(dirtyRect)
    }
}
