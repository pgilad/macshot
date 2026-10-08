import Foundation

nonisolated enum Paths {
    /// `Application Support/com.pgilad.macshot`. Inside the App Sandbox this is in the app
    /// container. A debug binary from `swift build` has no sandbox, so debug builds accept
    /// `MACSHOT_DATA_DIR`, and the self-test uses a temporary folder.
    static var dataDirectory: URL {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["MACSHOT_DATA_DIR"], !override.isEmpty {
            return URL(filePath: override, directoryHint: .isDirectory)
        }
        #endif
        return URL.applicationSupportDirectory.appending(path: "com.pgilad.macshot", directoryHint: .isDirectory)
    }
}
