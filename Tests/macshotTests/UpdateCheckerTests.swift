import Foundation
import Testing
@testable import macshot

/// The update check, with the GitHub request replaced: the tests make no network request.
final class UpdateCheckerTests {

    private static let current = AppVersion("5.0.0")!
    private static let cleanDefaults: [String: Any?] = [
        Preferences.Key.checkForUpdates: nil,
        Preferences.Key.lastUpdateCheck: nil,
    ]

    /// Counts the requests and answers each with `answer`.
    private final class FakeGitHub {
        var requests = 0
        var answer: UpdateChecker.State

        init(_ answer: UpdateChecker.State) {
            self.answer = answer
        }

        func checker() -> UpdateChecker {
            UpdateChecker(currentVersion: UpdateCheckerTests.current) { [self] _ in
                requests += 1
                return answer
            }
        }
    }

    /// Counts `UpdateChecker.didChange`, which Settings uses to show the state.
    private final class ChangeCounter: NSObject {
        var count = 0

        init(_ checker: UpdateChecker) {
            super.init()
            NotificationCenter.default.addObserver(self, selector: #selector(changed), name: UpdateChecker.didChange, object: checker)
        }

        @objc private func changed() {
            count += 1
        }
    }

    private static func answer(_ status: Int, _ json: String) -> UpdateChecker.State {
        UpdateChecker.state(status: status, body: Data(json.utf8), current: current)
    }

    @Test func testANewerReleaseIsAvailable() {
        let page = URL(string: "https://github.com/pgilad/macshot/releases/tag/v5.1.0")!
        // Fields that the check does not read are ignored.
        #expect(Self.answer(200, #"{"tag_name": "v5.1.0", "html_url": "\#(page)", "draft": false, "assets": []}"#)
            == .available(version: "5.1.0", page: page))
    }

    @Test func testTheSameOrAnOlderReleaseIsUpToDate() {
        #expect(Self.answer(200, #"{"tag_name": "v5.0.0"}"#) == .upToDate)
        #expect(Self.answer(200, #"{"tag_name": "v4.9.9"}"#) == .upToDate)
    }

    @Test func testAPageThatIsNotOnGitHubOpensTheReleasesPage() {
        #expect(Self.answer(200, #"{"tag_name": "v5.1.0", "html_url": "https://example.net/macshot"}"#)
            == .available(version: "5.1.0", page: UpdateChecker.releasesPage))
    }

    @Test func testAnAnswerWithNoReleaseFails() {
        // A status other than 200 fails before the body is read.
        for (status, json) in [(403, #"{"tag_name": "v5.1.0"}"#), (200, "not json"), (200, #"{"tag_name": "v5.1.0-beta"}"#)] {
            guard case .failed = Self.answer(status, json) else {
                Issue.record("HTTP \(status) \(json) must fail")
                continue
            }
        }
    }

    @Test func testOnlyACheckThatGetsAnAnswerCounts() async {
        await withDefaults(Self.cleanDefaults) {
            let github = FakeGitHub(.failed("Cannot reach GitHub"))
            let checker = github.checker()
            await checker.check(showingResult: false)
            #expect(Preferences.lastUpdateCheck == nil, "after a failure, the next automatic look tries again")

            github.answer = .upToDate
            let changes = ChangeCounter(checker)
            await checker.check(showingResult: false)
            #expect(Preferences.lastUpdateCheck != nil)
            #expect(changes.count == 2, "checking, then the answer")
        }
    }

    @Test func testAnAutomaticCheckRunsWhenOnAndDue() async {
        await withDefaults(Self.cleanDefaults) {
            let github = FakeGitHub(.upToDate)
            let checker = github.checker()
            await checker.checkIfDue()
            #expect(github.requests == 1, "on by default, and never checked")
            await checker.checkIfDue()
            #expect(github.requests == 1, "not again soon after an answer")

            Preferences.lastUpdateCheck = Date.now.addingTimeInterval(-2 * 86_400)
            await checker.checkIfDue()
            #expect(github.requests == 2, "again after a day")

            Preferences.checkForUpdates = false
            Preferences.lastUpdateCheck = nil
            await checker.checkIfDue()
            #expect(github.requests == 2, "never when turned off")
        }
    }
}
