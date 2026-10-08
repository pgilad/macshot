import Cocoa

extension NSApplication {
    /// Shows a macshot window in front of the app that the user works in. `activate()` is
    /// only a request: after a click in the menu bar menu or a global hotkey, macOS can
    /// keep the other app active. A window ordered front while macshot is not active goes
    /// behind the windows of that app, so the command seems to do nothing.
    /// `orderFrontRegardless()` puts it on top anyway. It becomes key when macshot becomes
    /// active, or when the user clicks it.
    func showInFront(_ window: NSWindow) {
        activate()
        window.makeKeyAndOrderFront(nil)
        if !isActive {
            window.orderFrontRegardless()
        }
    }

    /// `showInFront(_:)` for an open or save panel that is not a sheet.
    func beginInFront(_ panel: NSSavePanel, completionHandler: @escaping (NSApplication.ModalResponse) -> Void) {
        activate()
        panel.begin(completionHandler: completionHandler)
        if !isActive {
            panel.orderFrontRegardless()
        }
    }
}
