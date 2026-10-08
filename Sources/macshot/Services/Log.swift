import OSLog

/// Unified logging. Read it with:
///   log show --last 30m --info --predicate 'subsystem == "com.pgilad.macshot"'
/// Screen content, OCR text, clipboard text and file paths must never be public in a
/// message: interpolate them with `privacy: .private`, or log counts and sizes only.
nonisolated enum Log {
    static let app = Logger(subsystem: "com.pgilad.macshot", category: "app")
    static let capture = Logger(subsystem: "com.pgilad.macshot", category: "capture")
    static let hotkey = Logger(subsystem: "com.pgilad.macshot", category: "hotkey")
}
