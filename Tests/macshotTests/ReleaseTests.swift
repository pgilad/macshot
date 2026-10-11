import Foundation
import Testing
@testable import macshot

/// The update check compares the running version with the tag of the latest GitHub release.
final class ReleaseTests {

    @Test(arguments: [("v5.0.2", [5, 0, 2]), ("5.1", [5, 1]), (" v1.2.3.4 ", [1, 2, 3, 4])])
    func testAVersionParses(_ text: String, _ components: [Int]) throws {
        #expect(try #require(AppVersion(text)).components == components)
    }

    // "?" is what BuildInfo gives a build with no version.
    @Test(arguments: ["", "5..1", "5.1.0-beta", "1.2.3.4.5", "５.0", "+1.0", "?"])
    func testAVersionRejects(_ text: String) {
        #expect(AppVersion(text) == nil)
    }

    @Test func testVersionsCompareByNumber() throws {
        func version(_ text: String) throws -> AppVersion { try #require(AppVersion(text)) }
        #expect(try version("5.0.10") > version("5.0.9"))
        #expect(try version("5.1") > version("5.0.9"))
        #expect(try version("5.0") == version("5.0.0"))
        #expect(try version("v5.0.2").description == "5.0.2")
    }

    @Test(arguments: [
        "http://github.com/pgilad/macshot/releases/tag/v5.0.2",
        "https://github.com.example.net/pgilad/macshot",
        "file:///Applications/macshot.app",
    ])
    func testTheReleasePageMustBeOnGitHub(_ url: String) {
        #expect(GitHubRelease(tagName: "v5.0.2", htmlURL: url).pageURL == nil)
    }
}
