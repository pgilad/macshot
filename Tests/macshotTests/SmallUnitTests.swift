import Cocoa
import Testing
@testable import macshot

/// Number badges: the label a user sees on each numbered annotation.
final class NumberFormatTests {

    @Test func testDecimalIsJustTheNumber() {
        #expect(NumberFormat.decimal.format(1) == "1")
        #expect(NumberFormat.decimal.format(42) == "42")
    }

    @Test func testRomanNumerals() {
        let expected: [Int: String] = [
            1: "I", 4: "IV", 9: "IX", 14: "XIV", 40: "XL", 90: "XC",
            400: "CD", 900: "CM", 1987: "MCMLXXXVII", 3999: "MMMCMXCIX",
        ]
        for (value, numeral) in expected {
            #expect(NumberFormat.roman.format(value) == numeral, "roman \(value)")
        }
    }

    @Test func testRomanClampsOutOfRangeValues() {
        // There is no Roman numeral for zero or for 4000+, so the badge falls
        // back to the nearest representable value instead of rendering blank.
        #expect(NumberFormat.roman.format(0) == "I")
        #expect(NumberFormat.roman.format(-5) == "I")
        #expect(NumberFormat.roman.format(4000) == "MMMCMXCIX")
        #expect(NumberFormat.roman.format(99999) == "MMMCMXCIX")
    }

    @Test func testAlphabeticBadges() {
        #expect(NumberFormat.alpha.format(1) == "A")
        #expect(NumberFormat.alpha.format(26) == "Z")
        #expect(NumberFormat.alphaLower.format(1) == "a")
        #expect(NumberFormat.alphaLower.format(26) == "z")
    }

    @Test func testAlphabeticBadgesWrapAfterZ() {
        #expect(NumberFormat.alpha.format(27) == "A", "the 27th badge wraps rather than breaking")
        #expect(NumberFormat.alpha.format(52) == "Z")
    }

    @Test func testAlphabeticBadgesHandleZeroAndNegatives() {
        #expect(NumberFormat.alpha.format(0) == "A")
        #expect(NumberFormat.alpha.format(-3) == "A")
    }

    @Test func testEveryFormatProducesSomethingForEveryBadge() {
        for format in NumberFormat.allCases {
            for number in [-10, 0, 1, 26, 27, 100, 3999, 4000, 10_000] {
                #expect(!format.format(number).isEmpty, "\(format) rendered \(number) as an empty badge")
            }
        }
    }
}

/// Dashed and dotted strokes are fitted to the path length so the pattern ends
/// cleanly instead of being cut off mid-dash.
final class LineStyleTests {

    private func path(lineWidth: CGFloat = 4) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: .zero)
        path.line(to: NSPoint(x: 100, y: 0))
        path.lineWidth = lineWidth
        return path
    }

    @Test func testSolidLeavesThePathAlone() {
        let solid = path()
        LineStyle.solid.apply(to: solid)
        #expect(solid.lineWidth == 4)
    }

    @Test func testDottedUsesRoundCapsSoDotsAreCircles() {
        let dotted = path()
        LineStyle.dotted.apply(to: dotted)
        #expect(dotted.lineCapStyle == .round)
    }

    @Test func testFittingToALengthDoesNotCrashOnDegenerateInput() {
        for length in [0, -10, 0.0001, 1_000_000] as [CGFloat] {
            for style in LineStyle.allCases {
                let p = path()
                style.applyFitted(to: p, pathLength: length)
            }
        }
    }

    @Test func testFittingAZeroWidthPath() {
        for style in LineStyle.allCases {
            let p = path(lineWidth: 0)
            style.applyFitted(to: p, pathLength: 100)
        }
    }

    @Test func testEveryStyleIsDistinct() {
        #expect(Set(LineStyle.allCases.map(\.rawValue)).count == LineStyle.allCases.count)
    }
}

/// The launch sweeper deletes files from shared directories. Deleting one file
/// too many means losing a user's capture, so its two guards — the filename
/// predicate and the age gate — are worth pinning down.
final class DirectorySweeperTests {

    private var directory: URL!

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macshot-sweeper-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    isolated deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    @discardableResult
    private func makeFile(_ name: String, ageInHours: Double = 0, bytes: Int = 16) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        if ageInHours > 0 {
            let modified = Date().addingTimeInterval(-ageInHours * 3600)
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
        return url
    }

    private func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path)
    }

    @Test func testOnlyMatchingFilesAreDeleted() throws {
        try makeFile("scratch-1.png")
        try makeFile("keep-me.png")

        let result = DirectorySweeper.sweep(directory: directory, olderThan: nil) { $0.hasPrefix("scratch-") }
        #expect(result.removed == 1)
        #expect(!exists("scratch-1.png"))
        #expect(exists("keep-me.png"), "a file the predicate rejected must survive")
    }

    @Test func testRecentFilesAreLeftAloneWhenAnAgeGateIsSet() throws {
        try makeFile("old.tmp", ageInHours: 48)
        try makeFile("fresh.tmp")

        let result = DirectorySweeper.sweep(directory: directory, olderThan: 3600) { $0.hasSuffix(".tmp") }
        #expect(result.removed == 1)
        #expect(!exists("old.tmp"))
        #expect(exists("fresh.tmp"), "a file being written right now must not be deleted underneath it")
    }

    @Test func testFreedBytesAreReported() throws {
        try makeFile("a.tmp", ageInHours: 5, bytes: 100)
        try makeFile("b.tmp", ageInHours: 5, bytes: 250)

        let result = DirectorySweeper.sweep(directory: directory, olderThan: 60) { $0.hasSuffix(".tmp") }
        #expect(result.removed == 2)
        #expect(result.bytesFreed == 350)
    }

    @Test func testSubdirectoriesAreNeverDeleted() throws {
        let subdirectory = directory.appendingPathComponent("nested.tmp")
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)

        let result = DirectorySweeper.sweep(directory: directory, olderThan: nil) { _ in true }
        #expect(result.removed == 0)
        #expect(FileManager.default.fileExists(atPath: subdirectory.path), "a directory must not be swept away by a filename rule")
    }

    @Test func testAMissingDirectoryIsNotAnError() {
        let missing = directory.appendingPathComponent("does-not-exist")
        let result = DirectorySweeper.sweep(directory: missing, olderThan: nil) { _ in true }
        #expect(result.removed == 0)
        #expect(result.bytesFreed == 0)
    }

    @Test func testAPredicateThatMatchesNothingDeletesNothing() throws {
        try makeFile("one.png")
        try makeFile("two.png")
        let result = DirectorySweeper.sweep(directory: directory, olderThan: nil) { _ in false }
        #expect(result.removed == 0)
        #expect(exists("one.png") && exists("two.png"))
    }
}

/// Text pinned from the clipboard is rendered to an image; these are the parts
/// that decide what that image contains.
final class ClipboardTextPinRendererTests {

    @Test func testPlainTextKeepsItsContent() {
        let attributed = ClipboardTextPinRenderer.plainAttributedString("hello\nworld")
        #expect(attributed.string == "hello\nworld")
        #expect(attributed.length > 0)
    }

    @Test func testPlainTextIsStyledForALightBackground() {
        let attributed = ClipboardTextPinRenderer.plainAttributedString("x")
        let color = attributed.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(color == .black, "the pin renders on white, so the text has to be dark")
        #expect(attributed.attribute(.font, at: 0, effectiveRange: nil) != nil)
    }

    @Test func testEmptyTextIsHandled() {
        #expect(ClipboardTextPinRenderer.plainAttributedString("").string == "")
    }

    @Test func testRenderingProducesAnImageForOrdinaryText() {
        let image = ClipboardTextPinRenderer.render(ClipboardTextPinRenderer.plainAttributedString("Pinned note"))
        #expect(image != nil)
        #expect((image?.size.width ?? 0) > 0)
        #expect((image?.size.height ?? 0) > 0)
    }

    @Test func testRenderingHandlesAwkwardText() {
        for text in ["", "   ", "\n\n\n", String(repeating: "word ", count: 2_000), "🎉", "العربية"] {
            _ = ClipboardTextPinRenderer.render(ClipboardTextPinRenderer.plainAttributedString(text))
        }
    }
}

/// Toolbar buttons draw themselves, so VoiceOver knows them only from what they report.
final class ToolbarButtonAccessibilityTests {

    @Test func testAButtonIsNamedByItsTooltipAndCanBePressed() {
        let button = ToolbarButtonView(action: .undo, sfSymbol: "arrow.uturn.backward", tooltip: "Undo")
        var pressed: [String] = []
        button.onClick = { action in pressed.append("\(action)") }
        #expect(button.isAccessibilityElement())
        #expect(button.accessibilityRole() == .button)
        #expect(button.accessibilityLabel() == "Undo")
        #expect(button.accessibilityPerformPress())
        #expect(pressed == ["undo"])
    }

    @Test func testTheSelectedToolIsReportedAsSelected() {
        let button = ToolbarButtonView(action: .tool(.arrow), sfSymbol: "arrow.up.right", tooltip: "Arrow")
        #expect(!button.isAccessibilitySelected())
        button.isOn = true
        #expect(button.isAccessibilitySelected())
    }

    @Test func testAButtonWithoutAClickActionCannotBePressed() {
        let button = ToolbarButtonView(action: .undo, sfSymbol: nil, tooltip: "")
        #expect(button.accessibilityLabel() == nil)
        #expect(!button.accessibilityPerformPress())
    }
}
