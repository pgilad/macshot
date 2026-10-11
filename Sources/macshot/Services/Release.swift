import Foundation

/// A release version such as `5.0.2`, from the bundle or from a release tag (`v5.0.2`).
/// A missing component counts as zero, so `5.0` equals `5.0.0`.
nonisolated struct AppVersion: Sendable, Comparable, CustomStringConvertible {
    let components: [Int]

    init?(_ text: String) {
        var text = Substring(text.trimmingCharacters(in: .whitespaces))
        if text.first == "v" {
            text = text.dropFirst()
        }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        // ASCII digits only: a pre-release such as 5.1.0-beta is not a release.
        let numbers = parts.compactMap { part in
            part.allSatisfy { $0.isASCII && $0.isWholeNumber } ? Int(part) : nil
        }
        guard (1...4).contains(parts.count), numbers.count == parts.count else {
            return nil
        }
        components = numbers
    }

    var description: String {
        components.map(String.init).joined(separator: ".")
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        for index in 0..<max(lhs.components.count, rhs.components.count) {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right {
                return left < right
            }
        }
        return false
    }

    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }
}

/// The fields of a GitHub release that the update check reads
/// (`GET /repos/{owner}/{repo}/releases/latest`).
nonisolated struct GitHubRelease: Sendable, Equatable, Decodable {
    var tagName: String
    var htmlURL: String?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }

    var version: AppVersion? { AppVersion(tagName) }

    /// The release page. The app opens it in the browser, so only an HTTPS page on github.com.
    var pageURL: URL? {
        guard let url = htmlURL.flatMap(URL.init(string:)), url.scheme == "https", url.host() == "github.com" else {
            return nil
        }
        return url
    }
}
