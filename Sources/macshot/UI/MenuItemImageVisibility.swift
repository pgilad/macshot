import Cocoa

extension NSMenuItem {
    /// macOS 27 hides most menu item images. Call this for an image that is content, not
    /// decoration: a capture thumbnail or an app icon. SF Symbol icons keep the system
    /// default. The macOS 26 SDK has no `preferredImageVisibility`, and CI builds it with
    /// the Swift 6.3 compiler; the macOS 27 SDK comes with Swift 6.4.
    func keepImageVisible() {
        #if compiler(>=6.4)
        if #available(macOS 27, *) {
            preferredImageVisibility = .visible
        }
        #endif
    }
}
