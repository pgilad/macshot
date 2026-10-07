import Cocoa
import Testing
@testable import macshot

/// Filenames come from a user-editable template and go straight to disk, so a
/// bad render means a failed save, an overwritten capture, or a name macOS
/// quietly mangles.
final class FilenameFormatterTests {

    /// 2026-03-14 09:26:53 UTC, formatted in whatever zone the machine runs in.
    private let fixedDate = Date(timeIntervalSince1970: 1_773_480_413)

    private func expectedDate(_ format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter.string(from: fixedDate)
    }

    // MARK: - Tokens

    @Test func testDefaultTemplateRendersDateAndTime() {
        let name = FilenameFormatter.format(template: FilenameFormatter.defaultTemplate, date: fixedDate)
        #expect(name == "Screenshot \(expectedDate("yyyy-MM-dd")) at \(expectedDate("HH-mm-ss"))")
    }

    @Test func testEachTokenExpands() {
        let cases: [(String, String)] = [
            ("{date}", expectedDate("yyyy-MM-dd")),
            ("{time}", expectedDate("HH-mm-ss")),
            ("{timestamp}", "\(expectedDate("yyyy-MM-dd"))_\(expectedDate("HH-mm-ss"))"),
            ("{unix}", String(Int(fixedDate.timeIntervalSince1970))),
        ]
        for (template, expected) in cases {
            #expect(FilenameFormatter.format(template: template, date: fixedDate) == expected, "token \(template) rendered wrong")
        }
    }

    @Test func testWindowAndIndexTokens() {
        #expect(FilenameFormatter.format(template: "{window}-{index}", windowTitle: "Safari", index: 3, date: fixedDate) == "Safari-3")
    }

    @Test func testInsertedWindowTitlesAreLiteralNotMoreTemplateTokens() {
        #expect(FilenameFormatter.format(template: "Capture {window}-{index}",
            windowTitle: "{date} {random} {index}", index: 7, date: fixedDate) == "Capture {date} {random} {index}-7")
    }

    @Test func testUnicodeClustersAndTrailingDotsSurviveLengthCappingCleanly() {
        let family = "👩‍👩‍👦"
        let name = FilenameFormatter.format(template: "abc" + String(repeating: family, count: 40), date: fixedDate)
        #expect(name.utf8.count <= 200)
        #expect(name == ("abc" + String(repeating: family, count: 10)))
        #expect(FilenameFormatter.format(template: String(repeating: "a", count: 199) + ".tail", date: fixedDate) == String(repeating: "a", count: 199))
    }

    @Test func testMissingWindowAndIndexRenderEmptyRatherThanPlaceholders() {
        #expect(FilenameFormatter.format(template: "shot{window}{index}", date: fixedDate) == "shot")
    }

    @Test func testRandomTokenIsEightLowercaseBase36Characters() {
        let name = FilenameFormatter.format(template: "{random}", date: fixedDate)
        #expect(name.count == 8)
        #expect(name.allSatisfy { $0.isNumber || ($0.isLetter && $0.isLowercase) }, "got \(name)")
    }

    @Test func testEachRandomTokenGetsItsOwnValue() {
        let name = FilenameFormatter.format(template: "{random}-{random}", date: fixedDate)
        let parts = name.split(separator: "-")
        #expect(parts.count == 2)
        #expect(parts[0] != parts[1], "two {random} tokens produced the same value")
    }

    @Test func testRandomTokensDifferBetweenCaptures() {
        let names = Set((0..<20).map { _ in FilenameFormatter.format(template: "{random}", date: fixedDate) })
        #expect(names.count > 15, "{random} must not repeat across captures")
    }

    @Test func testUnknownTokensAreLeftVisible() {
        #expect(FilenameFormatter.format(template: "shot-{notAToken}", date: fixedDate) == "shot-{notAToken}", "a typo should be visible in the filename, not silently swallowed")
        #expect(FilenameFormatter.format(template: "Capture {unfinished", date: fixedDate) == "Capture {unfinished")
    }

    @Test func testTokensAreCaseSensitive() {
        #expect(FilenameFormatter.format(template: "{DATE}", date: fixedDate) == "{DATE}")
    }

    // MARK: - Sanitizing

    @Test func testPathSeparatorsCannotEscapeTheSaveDirectory() {
        let name = FilenameFormatter.format(template: "../../etc/passwd", date: fixedDate)
        #expect(!name.contains("/"), "a slash in the template would write outside the save directory: \(name)")
        #expect(name == "..-..-etc-passwd")
    }

    @Test func testWindowTitleWithSlashesIsNeutralized() {
        let name = FilenameFormatter.format(template: "{window}", windowTitle: "docs/README: draft", date: fixedDate)
        #expect(name == "docs-README- draft")
    }

    @Test func testColonsAreReplacedBecauseFinderShowsThemAsSlashes() {
        #expect(FilenameFormatter.format(template: "a:b", date: fixedDate) == "a-b")
    }

    @Test func testControlCharactersAreStripped() {
        let name = FilenameFormatter.format(template: "shot\u{7}\u{1}name", date: fixedDate)
        #expect(name == "shotname")
    }

    @Test func testNullBytesAreNeutralized() {
        let name = FilenameFormatter.format(template: "shot\0name", date: fixedDate)
        #expect(!name.contains("\0"))
    }

    @Test func testTrailingDotsAreTrimmed() {
        #expect(FilenameFormatter.format(template: "screenshot...", date: fixedDate) == "screenshot", "macOS hides trailing dots, so they'd produce a confusing filename")
    }

    @Test func testSurroundingWhitespaceIsTrimmed() {
        #expect(FilenameFormatter.format(template: "   shot   ", date: fixedDate) == "shot")
    }

    @Test func testNewlinesInAWindowTitleAreStripped() {
        let name = FilenameFormatter.format(template: "{window}", windowTitle: "line1\nline2", date: fixedDate)
        #expect(!name.contains("\n"))
    }

    // MARK: - Length

    @Test func testLongNamesAreCappedToAWritableLength() {
        let name = FilenameFormatter.format(template: String(repeating: "a", count: 500), date: fixedDate)
        #expect(name.utf8.count <= 200, "macOS rejects filenames longer than 255 bytes")
    }

    @Test func testCappingDoesNotSplitAMultiByteCharacter() {
        // 150 emoji = 600 UTF-8 bytes; the cut has to land on a boundary.
        let name = FilenameFormatter.format(template: String(repeating: "😀", count: 150), date: fixedDate)
        #expect(name.utf8.count <= 200)
        #expect(!name.isEmpty)
        #expect(name == String(name.unicodeScalars.map(Character.init)), "result must still be valid text")
        #expect(name.allSatisfy { $0 == "😀" }, "a truncated scalar would show as a replacement character")
    }

    @Test func testAVeryLongWindowTitleStillLeavesAUsableName() {
        let name = FilenameFormatter.format(
            template: "{window}", windowTitle: String(repeating: "Document ", count: 100), date: fixedDate)
        #expect(!name.isEmpty)
        #expect(name.utf8.count <= 200)
    }

    // MARK: - Fallbacks

    @Test func testEmptyTemplateFallsBackToTheDefault() {
        #expect(FilenameFormatter.format(template: "", date: fixedDate) == FilenameFormatter.format(template: FilenameFormatter.defaultTemplate, date: fixedDate))
    }

    @Test func testWhitespaceOnlyTemplateFallsBackToTheDefault() {
        #expect(FilenameFormatter.format(template: "   \n ", date: fixedDate) == FilenameFormatter.format(template: FilenameFormatter.defaultTemplate, date: fixedDate))
    }

    @Test func testTemplateThatSanitizesToNothingFallsBack() {
        // Only control characters: renders to an empty string.
        let name = FilenameFormatter.format(template: "\u{1}\u{2}", date: fixedDate)
        #expect(!name.isEmpty, "an empty filename can't be saved")
        #expect(name.hasPrefix("Screenshot"), "expected the default template, got \(name)")
    }

    // MARK: - Defaults-driven convenience

    @Test func testDefaultImageFilenameUsesTheSavedTemplateAndExtension() {
        withDefaults([FilenameFormatter.userDefaultsKey: "capture-{index}", "imageFormat": "jpeg"]) {
            #expect(FilenameFormatter.defaultImageFilename(index: 7) == "capture-7.jpg")
        }
    }

    @Test func testDefaultImageFilenameWithoutASavedTemplate() {
        withDefaults([FilenameFormatter.userDefaultsKey: nil, "imageFormat": "png"]) {
            #expect(FilenameFormatter.defaultImageFilename().hasPrefix("Screenshot "))
            #expect(FilenameFormatter.defaultImageFilename().hasSuffix(".png"))
        }
    }

    // MARK: - Determinism

    @Test func testTheSameInputsRenderTheSameName() {
        let first = FilenameFormatter.format(template: "{timestamp}-{window}", windowTitle: "App", date: fixedDate)
        let second = FilenameFormatter.format(template: "{timestamp}-{window}", windowTitle: "App", date: fixedDate)
        #expect(first == second)
    }

    @Test func testTimeFormatUsesDashesSoTheNameStaysValid() {
        let name = FilenameFormatter.format(template: "{time}", date: fixedDate)
        #expect(!name.contains(":"), "HH:mm:ss would be mangled by the filesystem")
        #expect((name.filter { $0 == "-" }.count) == 2)
    }
    // MARK: - App token, date parts, subfolders

    @Test func testAppAndDatePartTokens() {
        let millis = Date(timeIntervalSince1970: 1_773_480_413.042)
        #expect(FilenameFormatter.format(template: "{app}-{HH}.{mm}.{ss}.{ms}", appName: "Safari", date: millis) == "Safari-\(expectedDate("HH")).\(expectedDate("mm")).\(expectedDate("ss")).042")
        #expect(FilenameFormatter.format(template: "{yyyy}{MM}{dd}", date: fixedDate) == expectedDate("yyyyMMdd"))
    }

    @Test func testSlashesBecomeSubfolders() {
        let path = FilenameFormatter.formatRelativePath(
            template: "{yyyy}/{MM}/{dd}/{app}-{HH}.{mm}.{ss}", appName: "Safari", date: fixedDate)
        #expect(path == [expectedDate("yyyy"), expectedDate("MM"), expectedDate("dd"),
                              "Safari-\(expectedDate("HH.mm.ss"))"])
    }

    @Test func testNoAppTemplateIsUsedOnlyWhenAppIsUnknown() {
        let template = "{yyyy}/{app}-{HH}"
        let noApp = "{yyyy}/{HH}.{ms}"
        #expect(FilenameFormatter.formatRelativePath(template: template, noAppTemplate: noApp,
                                                            appName: "Xcode", date: fixedDate) == [expectedDate("yyyy"), "Xcode-\(expectedDate("HH"))"])
        #expect(FilenameFormatter.formatRelativePath(template: template, noAppTemplate: noApp,
                                                            appName: "  ", date: fixedDate) == [expectedDate("yyyy"), "\(expectedDate("HH")).000"])
        // Without a no-app template the main one still renders.
        #expect(FilenameFormatter.formatRelativePath(template: template, appName: nil, date: fixedDate).count == 2)
    }

    @Test func testRelativePathCannotEscapeTheSaveFolder() {
        let path = FilenameFormatter.formatRelativePath(template: "../../{app}/./x//{window}",
                                                        windowTitle: "a/b", appName: "..", date: fixedDate)
        #expect(!path.contains(".."))
        #expect(!path.contains("."))
        #expect(!path.contains(""))
        #expect(path.last == "a-b", "slashes inside a token value never create folders")
    }

    @Test func testEmptyRelativePathFallsBack() {
        #expect(FilenameFormatter.formatRelativePath(template: "{app}/{window}", date: fixedDate) == [FilenameFormatter.format(template: FilenameFormatter.defaultTemplate, date: fixedDate)])
    }
}
