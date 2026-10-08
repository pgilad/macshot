import Cocoa

/// The privacy permissions that macshot asks for: their names in System Settings ›
/// Privacy & Security, and links to their panes.
enum Permissions {
    /// macOS 27 renamed the Accessibility pane. `AXIsProcessTrusted` and the deep link did
    /// not change.
    static var accessibilityName: String {
        if #available(macOS 27, *) {
            "Device Control and Data Access"
        } else {
            "Accessibility"
        }
    }

    /// The title of the pane. Its row in the Privacy & Security list says "Screen Recording".
    static let screenRecordingName = "Screen & System Audio Recording"

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    /// Privacy & Security › Paste from Other Apps.
    static func openPasteboardSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard")
    }

    private static func open(_ string: String) {
        if let url = URL(string: string) {
            NSWorkspace.shared.open(url)
        }
    }
}
