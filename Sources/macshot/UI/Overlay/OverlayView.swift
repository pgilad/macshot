import Cocoa

@MainActor
protocol OverlayViewDelegate: AnyObject {
    func overlayViewDidFinishSelection(_ rect: NSRect)
    func overlayViewSelectionDidChange(_ rect: NSRect)
    func overlayViewDidCancel()
    func overlayViewDidConfirm()
    func overlayViewDidRequestSave()
    func overlayViewDidRequestSaveAs()
    func overlayViewDidRequestPin()
    func overlayViewDidRequestOCR()
    func overlayViewDidRequestQuickSave()
    func overlayViewDidRequestFileSave()
    func overlayViewDidRequestShare(anchorView: NSView?)
    func overlayViewDidRequestRemoveBackground()
    func overlayViewDidRequestDetach()
    func overlayViewDidRequestScrollCapture(rect: NSRect)
    func overlayViewDidRequestStopScrollCapture()
    func overlayViewDidRequestCancelScrollCapture()
    func overlayViewDidRequestToggleAutoScroll()
    func overlayViewDidRequestAccessibilityPermission()
    func overlayViewDidBeginSelection()
    func overlayViewRemoteSelectionDidChange(_ rect: NSRect)
    func overlayViewDidChangeSnapMode()
    func overlayViewRemoteSelectionDidFinish(_ rect: NSRect)
    func overlayViewDidRequestAddCapture()
    func overlayViewDidRequestRestoreLastSelection()
}

extension OverlayViewDelegate {
    func overlayViewDidRequestRestoreLastSelection() {}
}

/// An entry in the undo/redo history.
enum UndoEntry {
    case added(Annotation)  // annotation was added; undo removes it
    case deleted(Annotation, Int)  // annotation was deleted at index; undo re-inserts it
    /// Image transform (crop/flip): stores the previous image and annotation offsets to restore.
    /// `previousSnappedWindowImage` is non-nil only for transforms that also
    /// changed the separately-captured window image beautify's window-snap
    /// mode draws from.
    case imageTransform(previousImage: NSImage, previousSnappedWindowImage: NSImage?,
                        annotationOffsets: [(Annotation, CGFloat, CGFloat)])
    /// Property change: stores the annotation and a snapshot taken before the edit.
    case propertyChange(annotation: Annotation, snapshot: Annotation)

    var annotation: Annotation {
        switch self {
        case .added(let a), .deleted(let a, _): return a
        case .propertyChange(let a, _): return a
        case .imageTransform:
            return Annotation(
                tool: .measure, startPoint: .zero, endPoint: .zero, color: .clear, strokeWidth: 0)  // dummy
        }
    }
}

/// Snapshot of the mutable editor state.
struct OverlayEditorState {
    var screenshotImage: NSImage?
    var selectionRect: NSRect
    var annotations: [Annotation]
    var undoStack: [UndoEntry]
    var redoStack: [UndoEntry]
    var currentTool: AnnotationTool
    var currentColor: NSColor
    var currentStrokeWidth: CGFloat
    var currentMarkerSize: CGFloat
    var currentNumberSize: CGFloat
    var numberCounter: Int
    var beautifyEnabled: Bool
    var beautifyStyleIndex: Int
    var effectsPreset: ImageEffectPreset
    var effectsBrightness: Float
    var effectsContrast: Float
    var effectsSaturation: Float
    var effectsSharpness: Float
}

class OverlayView: NSView {

    // MARK: - Properties

    weak var overlayDelegate: OverlayViewDelegate?

    override var isOpaque: Bool {
        !usesExternalScreenshotPreview && screenshotImage != nil && !isScrollCapturing && !isEditorMode
    }

    /// When true, hides overlay-only toolbar buttons (delay, cancel, move, scroll capture).
    /// Override point for subclasses. EditorView returns true.
    var isEditorMode: Bool { false }
    /// When true, NSScrollView handles zoom/pan/centering. Coordinate transforms become identity.
    var isInsideScrollView: Bool { false }
    /// When in scroll view mode, toolbar strips are added to this view (window content) instead of self.
    weak var chromeParentView: NSView?

    var screenshotImage: NSImage? {
        didSet {
            cachedCompositedImage = nil
            cachedEffectsScreenshot = nil
            cachedOpaqueRect = nil
            // Load the custom beautify background at session start. reset() only
            // runs at session teardown, so the FIRST capture of a freshly-created
            // pooled controller would otherwise render with no custom background
            // (and fall through to a gradient) if beautify was left on with the
            // custom-image style. The beautifyConfig getter is now side-effect-free,
            // so this must be done eagerly. Idempotent.
            if screenshotImage != nil { ensureCustomBeautifyBackgroundLoaded() }
            if captureSourceImage != nil {
                captureSourceImage = screenshotImage
            }
            if usesExternalScreenshotPreview {
                let cgImage = screenshotImage?.cgImage(forProposedRect: nil, context: nil, hints: nil)
                externalScreenshotPreviewUpdater?(cgImage)
            }
            needsDisplay = true
            // Screenshot just arrived (async capture) — enable snap queries now.
            if screenshotImage != nil && windowSnapCooldown {
                windowSnapCooldown = false
                if window?.isVisible == true,
                   state == .idle && snapMode != .off && !snapQueryInFlight {
                    querySnapTarget(at: NSEvent.mouseLocation)
                }
            }
            // Invalidate the boundary-snap edge index. Only the display under the
            // pointer builds a new one now; the others build on first mouse move.
            boundarySnapBuildGeneration += 1
            boundarySnapIndex = nil
            boundarySnapBuildInFlight = false
            boundarySnapGuideX = nil
            boundarySnapGuideY = nil
            pendingAutoAdjustSelection = false
            if let frame = window?.frame, frame.contains(NSEvent.mouseLocation) {
                requestBoundarySnapIndexIfNeeded()
            }
        }
    }
    var captureSourceImage: NSImage?
    var externalScreenshotPreviewUpdater: ((CGImage?) -> Void)?
    var usesExternalScreenshotPreview = false {
        didSet { needsDisplay = true }
    }

    // State
    enum State {
        case idle
        case selecting
        case selected
    }

    var state: State = .idle

    // Zoom — the capture overlay no longer zooms (scroll/pinch zoom was
    // removed). These remain fixed at the identity values so the shared
    // coordinate transforms (viewToCanvas / canvasToView / applyZoomTransform)
    // stay pure pass-throughs; the editor zooms via NSScrollView magnification
    // instead, which doesn't touch these.
    var zoomLevel: CGFloat = 1.0
    var zoomAnchorCanvas: NSPoint = .zero
    var zoomAnchorView: NSPoint = .zero

    // Selection
    var selectionRect: NSRect = .zero
    /// Selection rect from another overlay (in this view's local coords), drawn during cross-screen drag.
    var remoteSelectionRect: NSRect = .zero
    /// The full (unclipped) remote selection in this view's local coords — used for resize anchor calculation.
    var remoteSelectionFullRect: NSRect = .zero
    var isResizingRemoteSelection: Bool = false
    var remoteResizeHandle: ResizeHandle = .none
    var remoteResizeAnchor: NSPoint = .zero  // the fixed corner during remote resize
    var selectionStart: NSPoint = .zero
    /// Trackpad/mouse QoL: when the user right-clicks in the empty overlay
    /// (state == .idle), we anchor a selection at that point and let the
    /// cursor resize it with no button held. A subsequent left-click
    /// finalizes, ESC cancels. This mirrors the drag flow but removes the
    /// need to keep pressing — big usability win for large selections on
    /// trackpads.
    var isAnchoredSelecting: Bool = false
    var isDraggingSelection: Bool = false
    var isResizingSelection: Bool = false
    var resizeHandle: ResizeHandle = .none
    var dragOffset: NSPoint = .zero
    var lastDragPoint: NSPoint?  // for shift constraint on flagsChanged
    var spaceRepositioning: Bool = false  // Space held during drag to reposition
    var spaceRepositionLast: NSPoint = .zero  // last mouse position when space reposition started

    /// Snapshot of `undoStack.count` taken at the start of a fresh click in `selected` state.
    /// Used by the "double-click to copy" feature to rewind annotations that the first click
    /// (and any in-progress second click) added before triggering the confirm path.
    var doubleClickUndoBaseline: Int?
    /// Short-lived marker for the Text tool case where the first click opens an empty editor.
    var textToolDoubleClickCopyDeadline: TimeInterval = 0

    // Annotations
    var annotations: [Annotation] = [] {
        didSet {
            cachedCompositedImage = nil
            cachedEffectsScreenshot = nil
            // Update move button enabled state when annotations change
            if showToolbars { rebuildToolbarLayout() }
        }
    }
    // An undo depth is not a document identity: undo + a different edit can
    // return to the same depth. Keep identities for the current undo/redo
    // branch so returning to a saved state is clean, but replacing it is not.
    private var undoStateIdentities = [UUID()]
    var isReplayingRedo = false
    var undoStateIdentity: UUID { undoStateIdentities[undoStack.count] }
    var undoStack: [UndoEntry] = [] {
        didSet {
            if undoStack.count > oldValue.count {
                if !isReplayingRedo {
                    undoStateIdentities.removeSubrange((oldValue.count + 1)...)
                }
                while undoStateIdentities.count <= undoStack.count { undoStateIdentities.append(UUID()) }
            } else if undoStack.count == oldValue.count {
                // Whole-stack replacement (for example, restored annotations).
                undoStateIdentities = (0...undoStack.count).map { _ in UUID() }
            }
            onContentChanged?()
        }
    }
    var redoStack: [UndoEntry] = []
    /// Fired when editable content changes (undo stack, or beautify/effects).
    /// The detached editor uses this to reveal "Done" only once there's an edit.
    var onContentChanged: (() -> Void)?
    var currentAnnotation: Annotation?
    /// Whether the user is actively drawing/dragging a new annotation.
    var isActivelyDrawing: Bool { currentAnnotation != nil }

    // MARK: - Tool handlers
    lazy var toolHandlers: [AnnotationTool: AnnotationToolHandler] = {
        let handlers: [AnnotationToolHandler] = [
            PencilToolHandler(),
            MarkerToolHandler(),
            LineToolHandler(),
            ArrowToolHandler(),
            RectangleToolHandler(),
            FilledRectangleToolHandler(),
            EllipseToolHandler(),
            PixelateToolHandler(),
            LoupeToolHandler(),
            MeasureToolHandler(),
            NumberToolHandler(),
            StampToolHandler(),
            HighlightToolHandler(),
        ]
        return Dictionary(uniqueKeysWithValues: handlers.map { ($0.tool, $0) })
    }()
    /// Last tool the user explicitly picked — persisted across app launches.
    private static var lastUsedTool: AnnotationTool = {
        if let raw = UserDefaults.standard.object(forKey: "lastUsedTool") as? Int,
           let tool = AnnotationTool(rawValue: raw) {
            return tool
        }
        return .arrow
    }()
    private static var shouldRememberLastTool: Bool {
        Preferences.rememberLastTool
    }
    private static var initialTool: AnnotationTool {
        shouldRememberLastTool ? lastUsedTool : .arrow
    }
    static func resetRememberedTool() {
        lastUsedTool = .arrow
        UserDefaults.standard.removeObject(forKey: "lastUsedTool")
    }
    var currentTool: AnnotationTool = {
        OverlayView.initialTool
    }() {
        didSet {
            // Persist drawing tool choices; skip transient/mode tools
            if OverlayView.shouldRememberLastTool && currentTool != .select && currentTool != .loupe {
                OverlayView.lastUsedTool = currentTool
                UserDefaults.standard.set(currentTool.rawValue, forKey: "lastUsedTool")
            }
        }
    }
    var currentColor: NSColor = {
        if let data = UserDefaults.standard.data(forKey: "lastUsedColor"),
           let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) {
            return color
        }
        return .systemRed
    }() {
        didSet {
            if let data = try? NSKeyedArchiver.archivedData(withRootObject: currentColor, requiringSecureCoding: true) {
                UserDefaults.standard.set(data, forKey: "lastUsedColor")
            }
            updateToolbarColorSwatch()
        }
    }
    /// currentColor with opacity applied — used for all tools except marker, loupe, measure, pixelate, blur
    var annotationColor: NSColor { currentColor.withAlphaComponent(currentColorOpacity) }
    var currentStrokeWidth: CGFloat = {
        let saved = UserDefaults.standard.object(forKey: "currentStrokeWidth") as? Double
        return saved != nil ? CGFloat(saved!) : 3.0
    }()
    var currentNumberSize: CGFloat = {
        let saved = UserDefaults.standard.object(forKey: "numberStrokeWidth") as? Double
        return saved != nil ? CGFloat(saved!) : 3.0
    }()
    var currentMarkerSize: CGFloat = {
        let saved = UserDefaults.standard.object(forKey: "markerStrokeWidth") as? Double
        return saved != nil ? CGFloat(saved!) : 3.0
    }()
    var numberCounter: Int = 0
    var numberStartAt: Int = {
        UserDefaults.standard.object(forKey: "numberStartAt") as? Int ?? 1
    }()
    /// Next number value, derived from the annotations currently on the canvas
    /// (issue #211): one past the highest existing number, or `numberStartAt`
    /// when no number annotations exist. Deriving from canvas state means the
    /// sequence resets correctly after any delete, multi-delete, or undo —
    /// no separate counter to keep in sync.
    var nextNumberValue: Int {
        let maxExisting = annotations
            .filter { $0.tool == .number }
            .compactMap { $0.number }
            .max()
        if let maxExisting { return maxExisting + 1 }
        return numberStartAt
    }
    var currentNumberFormat: NumberFormat = {
        NumberFormat(rawValue: UserDefaults.standard.integer(forKey: "numberFormat")) ?? .decimal
    }()

    // Select/move mode
    /// All currently selected annotations (supports multi-select via Shift+Click).
    var selectedAnnotations: [Annotation] = [] {
        didSet {
            let oldSingle = oldValue.first
            let newSingle = selectedAnnotations.first
            if newSingle !== oldSingle || oldValue.count != selectedAnnotations.count {
                toolOptionsRowView?.clearEditingAnnotation()

                if selectedAnnotations.count == 1, let ann = newSingle {
                    // Load text annotation properties into textEditor so toolbar shows correct state
                    if ann.tool == .text {
                        textEditor.restoreState(from: ann)
                    }
                    toolOptionsRowView?.rebuild(forAnnotation: ann)
                    repositionToolbars()
                } else if selectedAnnotations.isEmpty {
                    if let tool = currentTool as AnnotationTool? {
                        toolOptionsRowView?.rebuild(for: tool)
                        repositionToolbars()
                    }
                } else {
                    // Multi-select: revert to tool options (no per-annotation editing)
                    if let tool = currentTool as AnnotationTool? {
                        toolOptionsRowView?.rebuild(for: tool)
                        repositionToolbars()
                    }
                }
            }
        }
    }

    /// Convenience: the single selected annotation (nil if 0 or 2+ selected).
    var selectedAnnotation: Annotation? {
        get { selectedAnnotations.count == 1 ? selectedAnnotations.first : nil }
        set {
            if let ann = newValue {
                selectedAnnotations = [ann]
            } else {
                selectedAnnotations = []
            }
        }
    }

    /// Whether an annotation is in the current selection.
    func isSelected(_ annotation: Annotation) -> Bool {
        selectedAnnotations.contains(where: { $0 === annotation })
    }
    var isDraggingAnnotation: Bool = false
    var didMoveAnnotation: Bool = false
    /// Pre-move clones of the annotations being dragged, captured on the first
    /// move so the drag can be pushed as an undo entry (and counts as an edit).
    var preMoveSnapshots: [(annotation: Annotation, snapshot: Annotation)] = []
    var annotationDragStart: NSPoint = .zero
    /// Two-circle loupe: dragging the small SOURCE circle (re-roots what's
    /// magnified) independently of the lens.
    var isDraggingLoupeSource: Bool = false
    var loupeSourceDragStart: NSPoint = .zero
    var loupeSourceDragOrig: NSRect = .zero
    /// Two-circle loupe: resizing the SOURCE circle (changes the zoom).
    var isResizingLoupeSource: Bool = false
    /// When ctrl+clicking an already-selected annotation, defer the deselect
    /// to mouseUp so the user can still drag the full multi-selection.
    weak var shiftClickPendingDeselect: Annotation?
    /// Lasso selection: Ctrl+drag on empty space draws a marquee rectangle.
    var isLassoSelecting: Bool = false
    var lassoStart: NSPoint = .zero
    var lassoRect: NSRect = .zero
    // Long-press-to-select for pencil/marker tools
    var longPressTimer: Timer?
    var longPressPoint: NSPoint = .zero
    var longPressTriggered: Bool = false
    /// Annotation under the cursor when using a non-select drawing tool — enables on-the-fly move without switching tools.
    var hoveredAnnotation: Annotation?
    /// Delays clearing hoveredAnnotation so the cursor can travel to handles/buttons that sit outside the hit area.
    var hoveredAnnotationClearTimer: Timer?

    // Text editing — state managed by TextEditingController
    let textEditor = TextEditingController()
    var textEditView: NSTextView? { textEditor.textView }
    /// True for the duration of a single mouseDown that committed an open text
    /// editor, so the text tool dismisses it without placing a new field at the
    /// click point. Reset at the end of mouseDown.
    var justDismissedTextEditor = false

    // Text box resize state (stays here — tied to mouse drag handling)
    var isResizingTextBox: Bool = false
    var textBoxResizeHandle: ResizeHandle = .none
    var textBoxResizeStart: NSPoint = .zero
    var textBoxOrigFrame: NSRect = .zero
    // (Text box move handle removed — standard annotation chrome handles movement)

    // Toolbars (drawn inline)
    var bottomButtons: [ToolbarButton] = []
    var rightButtons: [ToolbarButton] = []
    var bottomBarRect: NSRect = .zero
    var rightBarRect: NSRect = .zero
    var showToolbars: Bool = false {
        didSet {
            if showToolbars && !oldValue {
                rebuildToolbarLayout()
            } else if !showToolbars && oldValue {
                bottomStripView?.isHidden = true
                rightStripView?.isHidden = true
                toolOptionsRowView?.isHidden = true
                dismissResolutionBox()
                optionsRowRect = .zero
            }
        }
    }
    var bottomStripView: ToolbarStripView?
    var rightStripView: ToolbarStripView?
    var toolOptionsRowView: ToolOptionsRowView?

    /// Intended overlay-space rect of the options row. .zero when the row is hidden.
    var optionsRowRect: NSRect = .zero
    // Resolution box (W × H fields + presets). Replaces the old drawn size badge.
    var resolutionBox: ResolutionBoxView?
    /// Overlay-space frame of the resolution box (for chrome hit-test / cursor /
    /// zoom-badge anchoring). .zero when not shown.
    var resolutionBoxRect: NSRect = .zero
    var preSelectionPresetButton: PreSelectionPresetButton?
    var preSelectionPresetButtonRect: NSRect = .zero

    // Beautify
    var beautifyEnabled: Bool = UserDefaults.standard.bool(forKey: "beautifyEnabled")
    var beautifyStyleIndex: Int = UserDefaults.standard.integer(
        forKey: "beautifyStyleIndex")
    var beautifyMode: BeautifyMode =
        BeautifyMode(rawValue: UserDefaults.standard.integer(forKey: "beautifyMode")) ?? .window
    var beautifyPadding: CGFloat = {
        let v = UserDefaults.standard.object(forKey: "beautifyPadding") as? Double
        return v != nil ? CGFloat(v!) : 48
    }()
    var beautifyCornerRadius: CGFloat = {
        let v = UserDefaults.standard.object(forKey: "beautifyCornerRadius") as? Double
        return v != nil ? CGFloat(v!) : 10
    }()
    var beautifyShadowRadius: CGFloat = {
        let v = UserDefaults.standard.object(forKey: "beautifyShadowRadius") as? Double
        return v != nil ? CGFloat(v!) : 20
    }()
    private(set) var beautifyBgRadius: CGFloat = {
        let v = UserDefaults.standard.object(forKey: "beautifyBgRadius") as? Double
        return v != nil ? CGFloat(v!) : 8
    }()

    var customBeautifyBackground: NSImage? {
        didSet { cachedBeautifyBgCGImage = nil }
    }
    var beautifyBackgroundBlur: CGFloat = UserDefaults.standard.object(forKey: "beautifyBgBlur") as? CGFloat ?? 0 {
        didSet {
            cachedBeautifyBgCGImage = nil
            prepareBeautifyBackgroundCache()
        }
    }
    private var cachedBeautifyBgCGImage: CGImage?

    func prepareBeautifyBackgroundCache() {
        guard let bg = customBeautifyBackground else { return }
        var cfg = BeautifyConfig(customBackgroundImage: bg, backgroundBlur: beautifyBackgroundBlur)
        cfg.prepareBackgroundCache()
        cachedBeautifyBgCGImage = cfg.cachedBackgroundCGImage
    }

    /// Load the custom beautify background from UserDefaults if the custom style
    /// is selected but the image isn't in memory yet. MUST be called explicitly
    /// (not from the `beautifyConfig` getter) — a getter that mutates state caused
    /// the editor's "Save changes?" prompt to fire on reopen even with no edits,
    /// because the lazy load changed `customBeautifyBackground` after the editor's
    /// clean-state signature was captured. Safe to call repeatedly.
    func ensureCustomBeautifyBackgroundLoaded() {
        guard beautifyStyleIndex == -1, customBeautifyBackground == nil else { return }
        if let img = CustomBeautifyBackground.load() {
            customBeautifyBackground = img
            prepareBeautifyBackgroundCache()
        }
    }

    var beautifyConfig: BeautifyConfig {
        return BeautifyConfig(
            mode: beautifyMode,
            styleIndex: beautifyStyleIndex,
            padding: beautifyPadding,
            cornerRadius: beautifyCornerRadius,
            shadowRadius: beautifyShadowRadius,
            bgRadius: 0,
            isWindowSnap: selectionIsWindowSnap,
            customBackgroundImage: beautifyStyleIndex == -1 ? customBeautifyBackground : nil,
            backgroundBlur: beautifyBackgroundBlur,
            cachedBackgroundCGImage: beautifyStyleIndex == -1 ? cachedBeautifyBgCGImage : nil
        )
    }

    var showBeautifyInOptionsRow: Bool = false

    // Image effects
    var effectsPreset: ImageEffectPreset =
        ImageEffectPreset(rawValue: UserDefaults.standard.integer(forKey: "effectsPreset")) ?? .none
    var effectsBrightness: Float = {
        let v = UserDefaults.standard.object(forKey: "effectsBrightness") as? Double
        return v != nil ? Float(v!) : 0
    }()
    var effectsContrast: Float = {
        let v = UserDefaults.standard.object(forKey: "effectsContrast") as? Double
        return v != nil ? Float(v!) : 1.0
    }()
    var effectsSaturation: Float = {
        let v = UserDefaults.standard.object(forKey: "effectsSaturation") as? Double
        return v != nil ? Float(v!) : 1.0
    }()
    var effectsSharpness: Float = {
        let v = UserDefaults.standard.object(forKey: "effectsSharpness") as? Double
        return v != nil ? Float(v!) : 0
    }()

    var effectsConfig: ImageEffectsConfig {
        ImageEffectsConfig(
            preset: effectsPreset,
            brightness: effectsBrightness,
            contrast: effectsContrast,
            saturation: effectsSaturation,
            sharpness: effectsSharpness
        )
    }
    var effectsActive: Bool { !effectsConfig.isIdentity }

    /// Cached effects-processed screenshot for live preview. Invalidated when effects or annotations change.
    var cachedEffectsScreenshot: NSImage?

    // Color picker target
    enum ColorPickerTarget { case drawColor, textBg, textOutline, textGlyphStroke, annotationOutline, loupeOutline }
    var colorPickerTarget: ColorPickerTarget = .drawColor

    // Beautify toolbar animation
    var beautifyToolbarAnimProgress: CGFloat = 1.0  // 0..1, 1 = fully settled
    var beautifyToolbarAnimTimer: Timer?
    var beautifyToolbarAnimTarget: Bool = false  // target beautify state

    // Tool options row (second row below bottom bar)
    var currentMeasureInPoints: Bool = UserDefaults.standard.bool(forKey: "measureInPoints")
    // Default ON: measuring outside the capture area is almost always an accident (#212)
    var currentMeasureClampToSelection: Bool = UserDefaults.standard.object(forKey: "measureClampToSelection") as? Bool ?? true
    var currentLineStyle: LineStyle =
        LineStyle(rawValue: UserDefaults.standard.integer(forKey: "currentLineStyle")) ?? .solid
    var currentArrowStyle: ArrowStyle =
        ArrowStyle(rawValue: UserDefaults.standard.integer(forKey: "currentArrowStyle")) ?? .single
    var arrowReversed: Bool =
        UserDefaults.standard.bool(forKey: "arrowReversed")
    var currentRectFillStyle: RectFillStyle =
        RectFillStyle(rawValue: UserDefaults.standard.integer(forKey: "currentRectFillStyle"))
        ?? .stroke
    var currentStampImage: NSImage?  // selected emoji/image for stamp tool
    var currentStampEmoji: String?  // emoji string for highlight tracking
    var currentStampSize: CGFloat = {
        let v = UserDefaults.standard.object(forKey: "stampSize") as? Double
        return v != nil ? CGFloat(v!) : 64
    }()
    var stampPreviewPoint: NSPoint?  // mouse position for stamp cursor preview
    var currentRectCornerRadius: CGFloat = {
        let v = UserDefaults.standard.object(forKey: "currentRectCornerRadius") as? Double
        return v != nil ? CGFloat(v!) : 0
    }()

    // Stroke width picker popover

    var pencilSmoothMode: Int = {
        // Migrate old bool to new mode: true → 1 (Smooth), false → 0 (None)
        if let old = UserDefaults.standard.object(forKey: "pencilSmoothEnabled") as? Bool {
            UserDefaults.standard.removeObject(forKey: "pencilSmoothEnabled")
            let mode = old ? 1 : 0
            UserDefaults.standard.set(mode, forKey: "pencilSmoothMode")
            return mode
        }
        return UserDefaults.standard.object(forKey: "pencilSmoothMode") as? Int ?? 1
    }()
    var pencilPressureEnabled: Bool =
        UserDefaults.standard.object(forKey: "pencilPressureEnabled") as? Bool ?? false
    var currentPressure: CGFloat = 1.0
    var smartMarkerEnabled: Bool =
        UserDefaults.standard.object(forKey: "smartMarkerEnabled") as? Bool ?? false

    var currentLoupeSize: CGFloat = {
        let saved = UserDefaults.standard.object(forKey: "loupeSize") as? Double
        return saved != nil ? CGFloat(saved!) : 120.0
    }()
    var currentLoupeMagnification: CGFloat = {
        let saved = UserDefaults.standard.object(forKey: "loupeMagnification") as? Double
        return saved != nil ? CGFloat(saved!) : 2.0
    }()
    var currentLoupeOutlineColor: NSColor = {
        if let data = UserDefaults.standard.data(forKey: "loupeOutlineColor"),
           let c = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) {
            return c
        }
        return .systemRed
    }()
    var currentLoupeOutlineEnabled: Bool =
        UserDefaults.standard.object(forKey: "loupeOutlineEnabled") as? Bool ?? false
    var loupeCursorPoint: NSPoint = .zero
    var drawingCursorPoint: NSPoint = .zero
    var smartMarkerLineHeight: CGFloat?  // detected text line height at cursor (smart marker)
    var colorSamplerPoint: NSPoint = .zero  // canvas space, for color picker tool
    var colorSamplerBitmap: NSBitmapImageRep?  // cached bitmap for fast pixel sampling
    // Auto-measure preview (live while holding 1 or 2 key)
    var autoMeasurePreview: Annotation?  // temporary, drawn but not in annotations[]
    var autoMeasureVertical: Bool = true  // true = "1" key, false = "2" key
    var autoMeasureKeyHeld: Bool = false  // true while 1 or 2 is held down
    var autoMeasureBitmapCtx: CGContext?  // cached pixel data for fast scanning
    var autoMeasureBitmapW: Int = 0
    var autoMeasureBitmapH: Int = 0
    // Snap/alignment guides
    var snapGuideX: CGFloat? = nil  // vertical guide line X
    var snapGuideY: CGFloat? = nil  // horizontal guide line Y
    let snapThreshold: CGFloat = 5
    var snapGuidesEnabled: Bool {
        Preferences.snapGuidesEnabled
    }
    var selectionOutsideShadowDisabled: Bool {
        Preferences.disableSelectionOutsideShadow
    }
    var tooltipShortcutDisplayEnabled: Bool {
        Preferences.showToolShortcutsInTooltips
    }

    var cachedCompositedImage: NSImage? = nil {  // invalidated when annotations change
        didSet { if !isDraggingAnnotation && !isResizingAnnotation && !isRotatingAnnotation { cachedAnnotationLayer = nil } }
    }
    /// Cached transparent image of committed annotations only (no screenshot).
    /// Drawn with applyCanvasTransform so zoom works correctly. Invalidated alongside cachedCompositedImage.
    var cachedAnnotationLayer: NSImage? = nil
    /// During drag/resize, this holds a cache of all annotations EXCEPT the ones being manipulated.
    var cachedAnnotationLayerExcludingSelected: NSImage? = nil
    var cachedOpaqueRect: NSRect?  // cached opaque content bounds of screenshotImage

    // Crop tool state
    var isCropDragging: Bool = false
    var cropDragStart: NSPoint = .zero
    var cropDragRect: NSRect = .zero

    // Annotation selection/resize controls
    var isResizingAnnotation: Bool = false
    var annotationResizeHandle: ResizeHandle = .none
    var annotationResizeAnchorIndex: Int = -1  // index into anchorPoints for multi-anchor drag
    var isRotatingAnnotation: Bool = false
    var rotationStartAngle: CGFloat = 0
    var rotationOriginal: CGFloat = 0
    var annotationRotateHandleRect: NSRect = .zero
    var annotationResizeOrigStart: NSPoint = .zero
    var annotationResizeOrigEnd: NSPoint = .zero
    var annotationResizeOrigTextOrigin: NSPoint = .zero
    var annotationResizeOrigControlPoint: NSPoint = .zero
    var annotationResizeMouseStart: NSPoint = .zero
    var annotationDeleteButtonRect: NSRect = .zero
    var annotationEditButtonRect: NSRect = .zero
    /// Resize handle on a two-circle loupe's SOURCE circle (.zero when none).
    var loupeSourceHandleRect: NSRect = .zero
    var annotationResizeHandleRects: [(ResizeHandle, NSRect)] = []
    var multiSelectDeleteButtonRect: NSRect = .zero  // consolidated delete for multi-selection

    // Overlay error message
    var overlayErrorMessage: String? = nil

    // Instant tooltip for hovered toolbar button
    var hoveredTooltip: String?
    var hoveredTooltipButtonView: ToolbarButtonView?
    var isToolbarMoveDragActive = false
    var isKeyboardMoveSelectionActive = false
    var keyboardMoveSelectionOffset: NSPoint = .zero
    var keyboardMoveSelectionShortcut: String = ""

    var currentCanvasMousePoint: NSPoint? {
        guard let windowPoint = window?.mouseLocationOutsideOfEventStream else { return nil }
        return viewToCanvas(convert(windowPoint, from: nil))
    }
    var editorTooltipView: NSView?
    private var overlayErrorTimer: Timer? = nil

    var autoOCRMode: Bool = false  // set by "Capture OCR & QR" menu — triggers OCR immediately after selection
    var autoQuickSaveMode: Bool = false  // set by "Quick Capture" menu — quick-saves immediately after selection
    var autoScrollCaptureMode: Bool = false  // set by "Scroll Capture" menu — triggers scroll capture immediately after selection
    var autoConfirmMode: Bool = false  // set by "Add Capture" — auto-confirms selection (no toolbars, no save)

    // Scroll capture state
    var isScrollCapturing: Bool = false
    var scrollCaptureStripCount: Int = 0
    var scrollCapturePixelSize: CGSize = .zero
    var scrollCaptureMaxHeight: Int = 0
    var scrollCaptureAutoScrolling: Bool = false
    private var scrollCaptureHUDPanel: ScrollCaptureHUDPanel?
    private var scrollCaptureMouseTap: CFMachPort?
    private var scrollCaptureMouseTapSource: CFRunLoopSource?
    private var scrollCaptureKeyMonitor: Any?
    private var scrollCaptureLocalKeyMonitor: Any?
    /// Activate the app visible under the selection rect so the user doesn't need a warmup click.
    private func activateAppUnderSelection() {
        guard selectionRect.width > 0, let win = window else { return }
        // Convert selection center to global screen coords
        let centerLocal = NSPoint(x: selectionRect.midX, y: selectionRect.midY)
        let centerScreen = win.convertToScreen(NSRect(origin: centerLocal, size: .zero)).origin

        guard
            let windowList = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
            ) as? [[String: Any]]
        else { return }

        let overlayWindowNumber = win.windowNumber
        let screenH = NSScreen.screens.first?.frame.height ?? 0

        for info in windowList {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat],
                let winNum = info[kCGWindowNumber as String] as? Int,
                let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                winNum != overlayWindowNumber
            else { continue }

            let cgX = boundsDict["X"] ?? 0
            let cgY = boundsDict["Y"] ?? 0
            let cgW = boundsDict["Width"] ?? 0
            let cgH = boundsDict["Height"] ?? 0
            let appKitRect = NSRect(x: cgX, y: screenH - cgY - cgH, width: cgW, height: cgH)

            if appKitRect.contains(centerScreen) {
                NSRunningApplication(processIdentifier: pid)?.activate(options: [])
                return
            }
        }
    }

    func startScrollCaptureMode() {
        isScrollCapturing = true
        updateResolutionBox()  // hide the box during scroll capture
        scrollCaptureStripCount = 0
        scrollCapturePixelSize = .zero
        scrollCaptureAutoScrolling = false

        activateAppUnderSelection()
        window?.ignoresMouseEvents = true

        // Suppress mouse-moved events via CGEvent tap so hover effects in the
        // target app don't break stitch detection. Requires Accessibility permission
        // (checked before entering scroll capture mode).
        if AXIsProcessTrusted() {
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: CGEventMask(1 << CGEventType.mouseMoved.rawValue),
                callback: { _, _, _, _ in nil },
                userInfo: nil)
            if let tap = tap {
                let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
                CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
                CGEvent.tapEnable(tap: tap, enable: true)
                scrollCaptureMouseTap = tap
                scrollCaptureMouseTapSource = source
            }
        }

        // Escape key monitor — global catches when another app has focus; local when macshot has focus.
        let handleScrollKey: (NSEvent) -> Void = { [weak self] event in
            guard let self = self, self.isScrollCapturing else { return }
            if event.keyCode == 53 {  // Escape
                self.overlayDelegate?.overlayViewDidRequestCancelScrollCapture()
            }
        }
        scrollCaptureKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            handleScrollKey(event)
        }
        scrollCaptureLocalKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleScrollKey(event)
            if event.keyCode == 53 { return nil }  // consume
            return event
        }

        // Show real NSPanel-based HUD (receives clicks independently of overlay window)
        let panel = ScrollCaptureHUDPanel()
        panel.hudView.onStop = { [weak self] in
            self?.overlayDelegate?.overlayViewDidRequestStopScrollCapture()
        }
        panel.hudView.onToggleAutoScroll = { [weak self] in
            self?.overlayDelegate?.overlayViewDidRequestToggleAutoScroll()
        }
        panel.hudView.update(
            stripCount: 0, pixelSize: .zero,
            backingScale: window?.backingScaleFactor ?? 2,
            maxScrollHeight: scrollCaptureMaxHeight,
            autoScrolling: scrollCaptureAutoScrolling)
        if let win = window {
            panel.position(relativeTo: selectionRect, in: win)
        }
        panel.orderFront(nil)
        scrollCaptureHUDPanel = panel

        needsDisplay = true
    }

    func stopScrollCaptureMode() {
        isScrollCapturing = false
        scrollCaptureStripCount = 0
        scrollCapturePixelSize = .zero
        scrollCaptureAutoScrolling = false

        if let m = scrollCaptureKeyMonitor { NSEvent.removeMonitor(m); scrollCaptureKeyMonitor = nil }
        if let m = scrollCaptureLocalKeyMonitor { NSEvent.removeMonitor(m); scrollCaptureLocalKeyMonitor = nil }
        if let tap = scrollCaptureMouseTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = scrollCaptureMouseTapSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
            scrollCaptureMouseTap = nil
            scrollCaptureMouseTapSource = nil
        }
        scrollCaptureHUDPanel?.close()
        scrollCaptureHUDPanel = nil
        window?.ignoresMouseEvents = false

        needsDisplay = true
    }

    /// Update the scroll capture HUD with new strip count and pixel size.
    func updateScrollCaptureHUD() {
        scrollCaptureHUDPanel?.hudView.update(
            stripCount: scrollCaptureStripCount,
            pixelSize: scrollCapturePixelSize,
            backingScale: window?.backingScaleFactor ?? 2,
            maxScrollHeight: scrollCaptureMaxHeight,
            autoScrolling: scrollCaptureAutoScrolling)
        if let win = window {
            scrollCaptureHUDPanel?.position(relativeTo: selectionRect, in: win)
        }
    }

    // Capture-target snapping. Preserve the old Boolean preference as a
    // migration fallback for existing users.
    var snapMode: SnapMode {
        get {
            let defaults = UserDefaults.standard
            if defaults.object(forKey: "captureSnapMode") != nil,
               let mode = SnapMode(rawValue: defaults.integer(forKey: "captureSnapMode")) {
                return mode
            }
            return (defaults.object(forKey: "windowSnapEnabled") as? Bool ?? true) ? .window : .off
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "captureSnapMode")
            UserDefaults.standard.set(newValue != .off, forKey: "windowSnapEnabled")
        }
    }

    // Boundary snapping — snap the selection's dragged edges to strong color
    // edges in the captured image (UI lines, window borders, etc.). On by
    // default. Hold Option while dragging to bypass.
    var boundarySnapEnabled: Bool {
        Preferences.boundarySnapEnabled
    }
    var boundarySnapIndex: BoundarySnapIndex?
    var boundarySnapBuildGeneration = 0
    var boundarySnapBuildInFlight = false
    /// The generation the last finished build was for. A build that returns
    /// nil is not retried on every mouse move.
    var boundarySnapBuiltGeneration = -1
    var pendingAutoAdjustSelection = false
    /// Snap radius in overlay points.
    let boundarySnapRadiusPoints: CGFloat = 4
    /// Overlay-space coordinates of the active snapped edge(s), for the guide
    /// line feedback. nil when not snapping that axis.
    var boundarySnapGuideX: CGFloat?
    var boundarySnapGuideY: CGFloat?
    var hoveredSnapRect: NSRect? = nil
    var hoveredSnapWindowID: CGWindowID? = nil
    var windowSnapCooldown: Bool = true  // true until overlay has rendered
    /// True when the current selection was made via window snap (click without drag).
    /// Cleared when the user manually resizes the selection.
    var selectionIsWindowSnap: Bool = false
    /// Locked aspect ratio (width / height) for the selection, or nil for freeform.
    /// When set, drag-resize and the resolution box maintain this ratio.
    var lockedAspect: CGFloat? = nil
    /// When true, the locked aspect ratio persists across captures (and launches).
    /// Stored in UserDefaults so a new selection starts already constrained.
    var keepRatioForNextCaptures: Bool {
        get { UserDefaults.standard.bool(forKey: "keepAspectRatio") }
        set { UserDefaults.standard.set(newValue, forKey: "keepAspectRatio") }
    }
    /// The persisted ratio value. Zero means freeform/no locked ratio.
    var persistedAspect: CGFloat {
        get { CGFloat(UserDefaults.standard.double(forKey: "keepAspectRatioValue")) }
        set { UserDefaults.standard.set(Double(newValue), forKey: "keepAspectRatioValue") }
    }
    enum PreSelectionPreset {
        case freeform
        case ratio(CGFloat)
        case resolution(w: Int, h: Int)
    }
    enum PreSelectionPresetStorageKind: Int {
        case inherited = 0
        case freeform = 1
        case ratio = 2
        case resolution = 3
    }
    static let preSelectionPresetKindKey = "preSelectionResolutionPresetKind"
    static let preSelectionPresetAspectKey = "preSelectionResolutionPresetAspect"
    static let preSelectionPresetWidthKey = "preSelectionResolutionPresetWidth"
    static let preSelectionPresetHeightKey = "preSelectionResolutionPresetHeight"
    var snappedWindowID: CGWindowID? = nil
    /// Independently captured window image (with transparent corners) for beautify snap mode.
    var snappedWindowImage: NSImage? = nil
    private var snapQueryInFlight: Bool = false
    private var pendingSnapQueryPoint: NSPoint?
    private var browserAccessibilityRetryWorkItems: [DispatchWorkItem] = []

    /// Find the window or accessibility element under the given AppKit screen point.
    func querySnapTarget(at screenPoint: NSPoint) {
        let requestedMode = snapMode
        guard state == .idle && requestedMode != .off,
            !(remoteSelectionRect.width >= 1 && remoteSelectionRect.height >= 1),
            let viewWindow = window
        else { return }
        if snapQueryInFlight {
            pendingSnapQueryPoint = screenPoint
            return
        }
        let overlayWindowNumber = viewWindow.windowNumber
        let windowOrigin = viewWindow.frame.origin
        let viewBounds = bounds
        let screenH = NSScreen.screens.first?.frame.height ?? NSScreen.main?.frame.height ?? 0
        let accessibilitySessionToken = requestedMode == .element
            ? Self.currentBrowserAccessibilitySessionToken()
            : 0
        snapQueryInFlight = true
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            let windowResult = Self.windowRectOnBackground(
                screenPoint: screenPoint,
                overlayWindowNumber: overlayWindowNumber,
                windowOrigin: windowOrigin,
                viewBounds: viewBounds,
                screenH: screenH
            )
            let result: WindowSnapResult?
            var didPrepareBrowserAccessibility = false
            if requestedMode == .element, let windowResult {
                let elementResult = Self.elementSnapResult(
                    screenPoint: screenPoint,
                    windowResult: windowResult,
                    windowOrigin: windowOrigin,
                    viewBounds: viewBounds,
                    screenH: screenH,
                    accessibilitySessionToken: accessibilitySessionToken)
                result = elementResult.result
                didPrepareBrowserAccessibility = elementResult.didPrepareBrowserAccessibility
            } else {
                result = windowResult
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.snapQueryInFlight = false
                if self.snapMode == requestedMode {
                    let newRect = result?.rect
                    let newWindowID = result?.windowID
                    if newRect != self.hoveredSnapRect || newWindowID != self.hoveredSnapWindowID {
                        self.hoveredSnapRect = newRect
                        self.hoveredSnapWindowID = newWindowID
                        self.needsDisplay = true
                    }
                }
                if didPrepareBrowserAccessibility {
                    self.scheduleBrowserAccessibilityRetry()
                }
                if let pendingPoint = self.pendingSnapQueryPoint {
                    self.pendingSnapQueryPoint = nil
                    self.querySnapTarget(at: pendingPoint)
                } else if self.snapMode != requestedMode {
                    self.querySnapTarget(at: NSEvent.mouseLocation)
                }
            }
        }
    }

    private func scheduleBrowserAccessibilityRetry() {
        for workItem in browserAccessibilityRetryWorkItems {
            workItem.cancel()
        }
        browserAccessibilityRetryWorkItems = [0.1, 0.5, 2.1].map { delay in
            let workItem = DispatchWorkItem { [weak self] in
                guard let self, self.state == .idle, self.snapMode == .element,
                      self.window?.isVisible == true
                else { return }
                self.querySnapTarget(at: NSEvent.mouseLocation)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
            return workItem
        }
    }

    var customColors: [NSColor?] = Array(repeating: nil, count: 7)
    var selectedColorSlot: Int = 0  // which custom slot is selected for saving colors
    static var lastUsedOpacity: CGFloat = {
        let saved = UserDefaults.standard.object(forKey: "lastUsedColorOpacity") as? Double
        return saved != nil ? CGFloat(saved!) : 1.0
    }()
    var currentColorOpacity: CGFloat = OverlayView.lastUsedOpacity

    // Radial color wheel (right-click in drawing mode)
    let colorWheel = ColorWheelRenderer()

    // Handle
    let handleSize: CGFloat = 10

    enum ResizeHandle {
        case none
        case topLeft, topRight, bottomLeft, bottomRight
        case top, bottom, left, right
        case move
    }

    // MARK: - Setup

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isFlipped: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        window?.acceptsMouseMovedEvents = true
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)

        // Don't run the initial snap query here — it fires before the screenshot
        // arrives (async capture). The snap query is triggered when screenshotImage
        // is set (via didSet → needsDisplay → mouseMoved), or we kick it off
        // explicitly in the screenshotImage setter below.
        // Skip cooldown in editor mode — screenshotImage is set before the view
        // moves to the window, so the didSet won't clear it. Window snap is
        // irrelevant in editor anyway.
        if !isEditorMode {
            windowSnapCooldown = true
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleToolbarColorsChanged),
            name: .toolbarColorsDidChange, object: nil)
    }

    @objc private func handleToolbarColorsChanged() {
        // Rebuild toolbars and options row with new colors.
        if let row = toolOptionsRowView {
            row.layer?.backgroundColor = ToolbarLayout.bgColor.cgColor
        }
        toolOptionsRowView?.appearance = ToolbarLayout.appearance
        rebuildToolbarLayout()
        if let tool = toolOptionsRowView?.currentTool {
            toolOptionsRowView?.rebuild(for: tool)
        }
        needsDisplay = true
    }

    /// Invalidate only the rect around a cursor preview (old + new position) instead of the whole view.
    func invalidateCursorPreview(oldCanvas: NSPoint, newCanvas: NSPoint, radius: CGFloat) {
        let margin: CGFloat = 4
        // Scale canvas-space radius to view-space pixels (zoom factor)
        let r = (radius + margin) * zoomLevel
        if oldCanvas != .zero {
            let oldView = canvasToView(oldCanvas)
            setNeedsDisplay(NSRect(x: oldView.x - r, y: oldView.y - r, width: r * 2, height: r * 2))
        }
        guard newCanvas != .zero else { return }
        let newView = canvasToView(newCanvas)
        setNeedsDisplay(NSRect(x: newView.x - r, y: newView.y - r, width: r * 2, height: r * 2))
    }

    // MARK: - Subclass override points

    /// Override to handle cursor for editor chrome (top bar). Base returns false.
    func updateCursorForChrome(at point: NSPoint) -> Bool { return false }

    /// Check if a view-space point is within the image/selection area.
    /// In overlay mode, compares directly. In editor mode, converts to canvas space first.
    func pointIsInSelection(_ viewPoint: NSPoint) -> Bool {
        if isEditorMode {
            let canvasPoint = viewToCanvas(viewPoint)
            return selectionRect.contains(canvasPoint)
        }
        return selectionRect.contains(viewPoint)
    }

    /// Override point for editor background drawing. Base does nothing (overlay has no editor background).
    func drawEditorBackground(context: NSGraphicsContext) {
    }

    /// Override to clip the selection image in overlay mode. Base returns true when not in editor mode.
    func shouldClipSelectionImage() -> Bool { !isEditorMode }

    /// Override to control selection border drawing. Base returns true when not in editor mode.
    func shouldDrawSelectionBorder() -> Bool { !isEditorMode }

    /// Override to control size label drawing. Base returns true when not scrolling/editing.
    func shouldShowResolutionBox() -> Bool {
        state == .selected && !isScrollCapturing && !isEditorMode
            && selectionRect.width > 1 && selectionRect.height > 1
    }

    /// Override to draw top chrome (e.g. editor top bar). Base draws editor top bar when in editor mode.    /// Override to adjust a view-space point for editor canvas offset. Base returns point unchanged.
    func adjustPointForEditor(_ p: NSPoint) -> NSPoint { p }

    /// Override point for editor-specific graphics context transform. Base does nothing.
    func applyEditorTransform(to context: NSGraphicsContext) {}

    /// Override to control whether selection resize handles are active. Base returns true when not in editor mode or scroll capturing.
    func shouldAllowSelectionResize() -> Bool { !isEditorMode && !isScrollCapturing }

    /// Override to control whether a new selection can be started. Base returns true when not in editor mode.
    func shouldAllowNewSelection() -> Bool { !isEditorMode }

    /// Override to change the rect used when drawing the screenshot in `captureSelectedRegion`. Base returns bounds.
    var captureDrawRect: NSRect { isEditorMode ? selectionRect : bounds }

    /// Bounds the spotlight dim is clipped to: only the screenshot SELECTION
    /// region should dim, never the dark area outside it. In editor mode the
    /// drawn region is the whole document (selectionRect); in overlay mode the
    /// selection is a sub-rect of the full-screen overlay.
    var highlightDimBounds: NSRect { isEditorMode ? captureDrawRect : selectionRect }

    /// Override to position toolbars for editor mode. Base pins bottom bar centered at bottom, right bar at top-right.    /// Override to control whether detach (open in editor) is allowed. Base returns true when not in editor mode.
    func shouldAllowDetach() -> Bool { !isEditorMode }

    /// Override to handle clicks on chrome areas. Base returns false.
    func handleTopChromeClick(at point: NSPoint) -> Bool { false }

    /// Starts moving the selection with the pointer. Tests override it to check
    /// the key routing without a window.
    @discardableResult
    func startKeyboardMoveSelection() -> Bool {
        guard canStartKeyboardMoveSelection(), let win = window else { return false }
        var moveButton = moveSelectionButtonView()

        isKeyboardMoveSelectionActive = true
        isToolbarMoveDragActive = true
        keyboardMoveSelectionShortcut = ToolShortcutManager.key(for: .moveSelection).lowercased()
        setToolbarHoverSuppressed(true)
        clearToolbarHoverState(suppressUntilMouseMoved: true, clearPressed: false)

        if selectionIsWindowSnap {
            selectionIsWindowSnap = false
            snappedWindowID = nil
            snappedWindowImage = nil
            rebuildToolbarLayout()
            setToolbarHoverSuppressed(true)
            moveButton = moveSelectionButtonView()
        }

        let point = convert(win.mouseLocationOutsideOfEventStream, from: nil)
        keyboardMoveSelectionOffset = NSPoint(
            x: point.x - selectionRect.origin.x,
            y: point.y - selectionRect.origin.y)

        moveButton?.isPressed = true
        moveButton?.needsDisplay = true
        moveButton?.displayIfNeeded()
        showMoveDragTooltip(anchor: moveButton)
        needsDisplay = true
        return true
    }

    // MARK: - Overlay Error

    func showOverlayError(_ message: String) {
        overlayErrorTimer?.invalidate()
        overlayErrorMessage = message
        needsDisplay = true
        overlayErrorTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: false) {
            [weak self] _ in
            MainActor.assumeIsolated {
                self?.overlayErrorMessage = nil
                self?.needsDisplay = true
            }
        }
    }

    // MARK: - Editor zoom state

    var editorZoomRedrawTimer: Timer?
    // Animated zoom state for smooth mouse wheel zooming
    var editorZoomTarget: CGFloat = 1.0
    var editorZoomAnimTimer: Timer?
    var editorZoomCursorDoc: NSPoint = .zero

    // MARK: - Cleanup

    /// Pre-set a selection (used by delay capture to restore the previous region)
    func snapshotEditorState() -> OverlayEditorState {
        return OverlayEditorState(
            screenshotImage: screenshotImage,
            selectionRect: selectionRect,
            annotations: annotations,
            undoStack: undoStack,
            redoStack: redoStack,
            currentTool: currentTool,
            currentColor: currentColor,
            currentStrokeWidth: currentStrokeWidth,
            currentMarkerSize: currentMarkerSize,
            currentNumberSize: currentNumberSize,
            numberCounter: numberCounter,
            beautifyEnabled: beautifyEnabled,
            beautifyStyleIndex: beautifyStyleIndex,
            effectsPreset: effectsPreset,
            effectsBrightness: effectsBrightness,
            effectsContrast: effectsContrast,
            effectsSaturation: effectsSaturation,
            effectsSharpness: effectsSharpness
        )
    }

    /// Restore editor state.
    /// Translates annotation coordinates by `offset` (the selection origin in the original view).
    func setAnnotations(_ anns: [Annotation]) {
        // Set sourceImage on loupe annotations so they can re-bake from the editor's image.
        // Also set it on pixelate/blur without a baked result (shouldn't happen, but defensive).
        if let img = screenshotImage {
            let bounds = captureDrawRect
            for ann in anns {
                if ann.tool == .loupe || ((ann.tool == .pixelate || ann.tool == .blur) && ann.bakedBlurNSImage == nil) {
                    ann.sourceImage = img
                    ann.sourceImageBounds = bounds
                    if ann.tool == .loupe { ann.bakeLoupe() }
                    if ann.tool == .pixelate { ann.bakePixelate() }
                }
            }
        }
        annotations = anns
        undoStack = anns.map { .added($0) }
        redoStack = []
        cachedCompositedImage = nil
        needsDisplay = true
    }

    func applySelection(_ rect: NSRect) {
        selectionRect = rect
        selectionStart = rect.origin
        state = .selected
        showToolbars = true
        needsDisplay = true
    }

    func applyFullScreenSelection() {
        selectionRect = bounds
        selectionStart = bounds.origin
        state = .selected
        showToolbars = true
        overlayDelegate?.overlayViewDidFinishSelection(selectionRect)
        needsDisplay = true
    }

    func clearSelection() {
        state = .idle
        selectionRect = .zero
        remoteSelectionRect = .zero
        remoteSelectionFullRect = .zero
        showToolbars = false
        updateResolutionBox()  // remove the box (no selection)
        needsDisplay = true
    }

    // MARK: - Reset

    func reset() {
        state = .idle
        selectionRect = .zero
        selectionIsWindowSnap = false
        snappedWindowID = nil
        snappedWindowImage = nil
        remoteSelectionRect = .zero
        remoteSelectionFullRect = .zero
        annotations.removeAll()
        undoStack.removeAll()
        redoStack.removeAll()
        currentAnnotation = nil
        currentTool = OverlayView.initialTool
        numberCounter = 0
        showToolbars = false
        dismissResolutionBox()
        bottomStripView?.isHidden = true
        rightStripView?.isHidden = true
        toolOptionsRowView?.isHidden = true
        PopoverHelper.dismiss()
        editorTooltipView?.removeFromSuperview()
        editorTooltipView = nil
        captureSourceImage = nil
        autoMeasurePreview = nil
        autoMeasureKeyHeld = false
        autoMeasureBitmapCtx = nil
        isKeyboardMoveSelectionActive = false
        isToolbarMoveDragActive = false
        keyboardMoveSelectionShortcut = ""
        pendingAutoAdjustSelection = false
        selectedAnnotation = nil
        isDraggingAnnotation = false
        hoveredAnnotationClearTimer?.invalidate()
        hoveredAnnotationClearTimer = nil
        hoveredAnnotation = nil
        colorWheel.dismiss()
        beautifyEnabled = UserDefaults.standard.bool(forKey: "beautifyEnabled")
        beautifyStyleIndex = UserDefaults.standard.integer(forKey: "beautifyStyleIndex")
        beautifyMode =
            BeautifyMode(rawValue: UserDefaults.standard.integer(forKey: "beautifyMode")) ?? .window
        beautifyPadding = CGFloat(
            UserDefaults.standard.object(forKey: "beautifyPadding") as? Double ?? 48)
        beautifyCornerRadius = CGFloat(
            UserDefaults.standard.object(forKey: "beautifyCornerRadius") as? Double ?? 10)
        beautifyShadowRadius = CGFloat(
            UserDefaults.standard.object(forKey: "beautifyShadowRadius") as? Double ?? 20)
        beautifyBgRadius = CGFloat(
            UserDefaults.standard.object(forKey: "beautifyBgRadius") as? Double ?? 8)
        // The custom-style background is loaded here (not lazily in the
        // beautifyConfig getter) so reads during draw never mutate state.
        customBeautifyBackground = nil
        ensureCustomBeautifyBackgroundLoaded()
        currentLineStyle =
            LineStyle(rawValue: UserDefaults.standard.integer(forKey: "currentLineStyle")) ?? .solid
        currentArrowStyle =
            ArrowStyle(rawValue: UserDefaults.standard.integer(forKey: "currentArrowStyle"))
            ?? .single
        currentRectFillStyle =
            RectFillStyle(rawValue: UserDefaults.standard.integer(forKey: "currentRectFillStyle"))
            ?? .stroke
        currentRectCornerRadius = CGFloat(
            UserDefaults.standard.object(forKey: "currentRectCornerRadius") as? Double ?? 0)
        textEditor.dismiss()
        dismissResolutionBox()
        hidePreSelectionPresetButton()
        lockedAspect = activePreSelectionRatio
        isResizingAnnotation = false
        loupeCursorPoint = .zero
        colorSamplerPoint = .zero
        colorSamplerBitmap = nil
        overlayErrorTimer?.invalidate()
        overlayErrorTimer = nil
        overlayErrorMessage = nil
        hoveredSnapRect = nil
        pendingSnapQueryPoint = nil
        for workItem in browserAccessibilityRetryWorkItems {
            workItem.cancel()
        }
        browserAccessibilityRetryWorkItems.removeAll()
        Self.resetBrowserAccessibilityPreparation()
        // Auto-mode flags — these are set per-session by the controller and
        // must NOT leak into the next session.
        autoOCRMode = false
        autoQuickSaveMode = false
        autoScrollCaptureMode = false
        autoConfirmMode = false
        needsDisplay = true
    }
}

// MARK: - NSTextViewDelegate

extension OverlayView: NSTextViewDelegate {
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            textView.insertNewlineIgnoringFieldEditor(self)
            textDidChange(Notification(name: NSText.didChangeNotification))
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancelTextEditing()
            return true
        }
        return false
    }

    func textDidChange(_ notification: Notification) {
        textEditor.resizeToFit()
        needsDisplay = true
    }
}

// MARK: - Image Effects helpers

extension OverlayView {
    /// Returns the effects-processed screenshot, cached for performance during draw().
    func effectsProcessedScreenshot(_ screenshot: NSImage) -> NSImage {
        if let cached = cachedEffectsScreenshot { return cached }
        let config = effectsConfig
        guard !config.isIdentity else { return screenshot }
        let processed = ImageEffects.apply(to: screenshot, config: config)
        cachedEffectsScreenshot = processed
        return processed
    }
}

// MARK: - AnnotationCanvas conformance

extension OverlayView: AnnotationCanvas {
    var activeAnnotation: Annotation? {
        get { currentAnnotation }
        set { currentAnnotation = newValue }
    }

    func setNeedsDisplay() {
        needsDisplay = true
    }
}

// MARK: - TextEditingCanvas conformance

extension OverlayView: TextEditingCanvas {}

