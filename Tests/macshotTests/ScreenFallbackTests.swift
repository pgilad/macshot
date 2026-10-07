import AppKit
import Testing
@testable import macshot

/// `NSScreen.screens` is empty while every display is asleep, during a display
/// reconfiguration, and on a headless Mac. Indexing it traps — for a menu-bar
/// app that runs for days, that reads as "it just quit on its own" (#387).
@MainActor
final class ScreenFallbackTests {

    @Test func testPreferredScreenMatchesWhatAppKitReports() {
        if NSScreen.screens.isEmpty {
            #expect(NSScreen.preferred == nil)
        } else {
            #expect(NSScreen.preferred != nil)
        }
    }

    @Test(.enabled(if: NSScreen.main != nil, "no main screen in this environment"))
    func testPreferredScreenPrefersTheMainOne() {
        #expect(NSScreen.preferred == NSScreen.main)
    }

    @Test func testTheFallbackFrameIsAlwaysUsable() {
        let frame = NSScreen.preferredVisibleFrame
        #expect(frame.width > 0, "UI positioned against this frame must not collapse")
        #expect(frame.height > 0)
        #expect(frame.origin.x.isFinite && frame.origin.y.isFinite)
    }

    @Test func testTheFallbackFrameMatchesTheRealScreenWhenThereIsOne() throws {
        let screen = try #require(NSScreen.preferred)
        #expect(NSScreen.preferredVisibleFrame == screen.visibleFrame)
    }

    @Test func testNoAppCodeIndexesTheScreenArrayDirectly() throws {
        // The whole point of the helper: a regression here is invisible until a
        // user's displays sleep at the wrong moment.
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("macshot")

        var offenders: [String] = []
        let enumerator = FileManager.default.enumerator(at: sourceRoot, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift",
                  url.lastPathComponent != "ScreenFallback.swift",
                  let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for (index, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let text = String(line)
                guard !text.trimmingCharacters(in: .whitespaces).hasPrefix("//") else { continue }
                if text.contains("NSScreen.screens[") || text.contains("NSScreen.screens.first!") {
                    offenders.append("\(url.lastPathComponent):\(index + 1)")
                }
            }
        }
        #expect(offenders.isEmpty, """
            These index NSScreen.screens without a guard, which traps when no display is \
            available — use NSScreen.preferred / preferredVisibleFrame instead:
            \(offenders.joined(separator: "\n"))
            """)
    }
}
