import Foundation

/// The version, build number and commit that scripts/bundle.sh writes into Info.plist.
/// macshot is built from source, so the commit tells which code runs.
enum BuildInfo {
    static var version: String { value(for: "CFBundleShortVersionString") ?? "?" }
    static var build: String { value(for: "CFBundleVersion") ?? "?" }
    /// nil for a binary that `swift build` made, which has no bundle Info.plist.
    static var commit: String? { value(for: "MacshotGitCommit") }

    /// Version, build number and commit in one line, for About and diagnostics.
    static var description: String {
        commit.map { "\(version) (\(build), commit \($0))" } ?? "\(version) (\(build))"
    }

    private static func value(for key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty, !value.hasPrefix("__") else { return nil }
        return value
    }
}
