import Foundation

/// App settings that the Settings window shares with the code that uses them. Each has
/// one key and one default here, so the two cannot drift apart: auto-redact once used a
/// different default from the censor tool. maccy keeps all its settings in one type in the
/// same way. Tool state that only the overlay and its options row share stays with them,
/// and a setting that only one file uses keeps its key there. The key names are persisted:
/// do not change them.
nonisolated enum Preferences {
    enum Key {
        static let playCopySound = "playCopySound"
        static let hideMenuBarIcon = "hideMenuBarIcon"
        static let ocrAction = "ocrAction"
        static let rememberLastTool = "rememberLastTool"
        static let quickCaptureOpenEditor = "quickCaptureOpenEditor"
        static let closeEditorAfterCopy = "closeEditorAfterCopy"
        static let urlSchemeEnabled = "urlSchemeEnabled"
        static let historySize = "historySize"
        static let historyUnlimited = "historyUnlimited"
        static let historyOrderByLastEdit = "historyOrderByLastEdit"
        static let showFloatingThumbnail = "showFloatingThumbnail"
        static let thumbnailStacking = "thumbnailStacking"
        static let thumbnailCorner = "thumbnailCorner"
        static let thumbnailScale = "thumbnailScale"
        static let thumbnailAutoDismiss = "thumbnailAutoDismiss"
        static let thumbnailLetterbox = "thumbnailLetterbox"
        static let captureCursor = "captureCursor"
        static let imageFormat = "imageFormat"
        static let downscaleRetina = "downscaleRetina"
        static let clipboardIncludesImageFormat = "clipboardIncludesImageFormat"
        static let showToolShortcutsInTooltips = "showToolShortcutsInTooltips"
        static let snapGuidesEnabled = "snapGuidesEnabled"
        static let boundarySnapEnabled = "boundarySnapEnabled"
        static let doubleClickToCopy = "doubleClickToCopy"
        static let hideCaptureInstructions = "hideCaptureInstructions"
        static let disableSelectionOutsideShadow = "disableSelectionOutsideShadow"
    }

    // MARK: - General

    static var playCopySound: Bool {
        get { bool(Key.playCopySound, default: true) }
        set { defaults.set(newValue, forKey: Key.playCopySound) }
    }
    static var hideMenuBarIcon: Bool {
        get { bool(Key.hideMenuBarIcon, default: false) }
        set { defaults.set(newValue, forKey: Key.hideMenuBarIcon) }
    }
    /// The index of the OCR action in the Settings popup (show and copy, show only, copy
    /// only). Callers compare it with those indexes.
    static var ocrAction: Int {
        get { int(Key.ocrAction, default: 0) }
        set { defaults.set(newValue, forKey: Key.ocrAction) }
    }
    static var rememberLastTool: Bool {
        get { bool(Key.rememberLastTool, default: true) }
        set { defaults.set(newValue, forKey: Key.rememberLastTool) }
    }
    static var quickCaptureOpenEditor: Bool {
        get { bool(Key.quickCaptureOpenEditor, default: false) }
        set { defaults.set(newValue, forKey: Key.quickCaptureOpenEditor) }
    }
    static var closeEditorAfterCopy: Bool {
        get { bool(Key.closeEditorAfterCopy, default: false) }
        set { defaults.set(newValue, forKey: Key.closeEditorAfterCopy) }
    }
    /// Off by default: see `AppDelegate.handleOpenURLs`.
    static var urlSchemeEnabled: Bool {
        get { bool(Key.urlSchemeEnabled, default: false) }
        set { defaults.set(newValue, forKey: Key.urlSchemeEnabled) }
    }

    // MARK: - History

    static var historySize: Int {
        get { int(Key.historySize, default: 10) }
        set { defaults.set(newValue, forKey: Key.historySize) }
    }
    static var historyUnlimited: Bool {
        get { bool(Key.historyUnlimited, default: false) }
        set { defaults.set(newValue, forKey: Key.historyUnlimited) }
    }
    static var historyOrderByLastEdit: Bool {
        get { bool(Key.historyOrderByLastEdit, default: true) }
        set { defaults.set(newValue, forKey: Key.historyOrderByLastEdit) }
    }

    // MARK: - Floating thumbnail

    static var showFloatingThumbnail: Bool {
        get { bool(Key.showFloatingThumbnail, default: true) }
        set { defaults.set(newValue, forKey: Key.showFloatingThumbnail) }
    }
    static var thumbnailStacking: Bool {
        get { bool(Key.thumbnailStacking, default: true) }
        set { defaults.set(newValue, forKey: Key.thumbnailStacking) }
    }
    /// A `FloatingThumbnailCorner` raw value.
    static var thumbnailCorner: String {
        get { defaults.string(forKey: Key.thumbnailCorner) ?? "bottomRight" }
        set { defaults.set(newValue, forKey: Key.thumbnailCorner) }
    }
    static var thumbnailScale: Double {
        get { defaults.object(forKey: Key.thumbnailScale) as? Double ?? 1.0 }
        set { defaults.set(newValue, forKey: Key.thumbnailScale) }
    }
    /// Seconds; 0 keeps the thumbnail until the user closes it.
    static var thumbnailAutoDismiss: Int {
        get { int(Key.thumbnailAutoDismiss, default: 5) }
        set { defaults.set(newValue, forKey: Key.thumbnailAutoDismiss) }
    }
    static var thumbnailLetterbox: Bool {
        get { bool(Key.thumbnailLetterbox, default: false) }
        set { defaults.set(newValue, forKey: Key.thumbnailLetterbox) }
    }

    // MARK: - Capture and output

    static var captureCursor: Bool {
        get { bool(Key.captureCursor, default: false) }
        set { defaults.set(newValue, forKey: Key.captureCursor) }
    }
    /// An `ImageEncoder.Format` raw value, or nil for the default format.
    static var imageFormat: String? {
        get { defaults.string(forKey: Key.imageFormat) }
        set { defaults.set(newValue, forKey: Key.imageFormat) }
    }
    static var downscaleRetina: Bool {
        get { bool(Key.downscaleRetina, default: false) }
        set { defaults.set(newValue, forKey: Key.downscaleRetina) }
    }
    static var clipboardIncludesImageFormat: Bool {
        get { bool(Key.clipboardIncludesImageFormat, default: false) }
        set { defaults.set(newValue, forKey: Key.clipboardIncludesImageFormat) }
    }

    // MARK: - Overlay

    static var showToolShortcutsInTooltips: Bool {
        get { bool(Key.showToolShortcutsInTooltips, default: false) }
        set { defaults.set(newValue, forKey: Key.showToolShortcutsInTooltips) }
    }
    static var snapGuidesEnabled: Bool {
        get { bool(Key.snapGuidesEnabled, default: true) }
        set { defaults.set(newValue, forKey: Key.snapGuidesEnabled) }
    }
    static var boundarySnapEnabled: Bool {
        get { bool(Key.boundarySnapEnabled, default: true) }
        set { defaults.set(newValue, forKey: Key.boundarySnapEnabled) }
    }
    static var doubleClickToCopy: Bool {
        get { bool(Key.doubleClickToCopy, default: true) }
        set { defaults.set(newValue, forKey: Key.doubleClickToCopy) }
    }
    static var hideCaptureInstructions: Bool {
        get { bool(Key.hideCaptureInstructions, default: false) }
        set { defaults.set(newValue, forKey: Key.hideCaptureInstructions) }
    }
    static var disableSelectionOutsideShadow: Bool {
        get { bool(Key.disableSelectionOutsideShadow, default: false) }
        set { defaults.set(newValue, forKey: Key.disableSelectionOutsideShadow) }
    }

    // MARK: - Storage

    private static var defaults: UserDefaults { .standard }

    /// `bool(forKey:)` and `integer(forKey:)` also read numbers and "YES"/"1" strings,
    /// which a `defaults write` or an imported settings file can contain.
    private static func bool(_ key: String, default value: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? value : defaults.bool(forKey: key)
    }

    private static func int(_ key: String, default value: Int) -> Int {
        defaults.object(forKey: key) == nil ? value : defaults.integer(forKey: key)
    }
}
