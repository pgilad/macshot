import Cocoa
import Testing
@testable import macshot

/// Pinned clipboard text is rendered on the main thread, so it needs a limit.
final class ClipboardPinSafetyTests {

    @Test func testOrdinaryTextIsNotTruncated() {
        let text = "a short note"
        #expect(ClipboardTextPinRenderer.truncatedForPinning(text) == text)
    }

    @Test func testAHugePasteIsCappedBeforeLayout() {
        // Laying out a copied log file glyph by glyph on the main thread is
        // what made the app beachball, hotkeys included.
        let huge = String(repeating: "x", count: 500_000)
        let capped = ClipboardTextPinRenderer.truncatedForPinning(huge)
        #expect(capped.count <= (ClipboardTextPinRenderer.maxCharacters + 2))
        #expect(capped.hasSuffix("…"), "the pin should show the text was cut, not end mid-sentence")
    }

    @Test func testRenderingAHugePasteFinishesQuickly() {
        let attributed = ClipboardTextPinRenderer.plainAttributedString(String(repeating: "word ", count: 100_000))
        let start = Date()
        _ = ClipboardTextPinRenderer.render(attributed)
        #expect(Date().timeIntervalSince(start) < 5.0, "a huge paste must not lock the main thread for minutes")
    }

    @Test func testRichTextFlavorsAreIgnoredForThePlainText() {
        let item = NSPasteboardItem()
        item.setData(Data("<b>bold</b>".utf8), forType: .html)
        item.setData(Data("{\\rtf1 bold}".utf8), forType: .rtf)
        item.setString("A normal plain-text fallback", forType: .string)
        if case .image(let image) = ClipboardPinService.image(from: item) {
            #expect(image.size.width > 0)
            #expect(image.size.height > 0)
        } else { Issue.record("Plain clipboard text must remain pinnable") }
    }

    @Test func testRichTextWithoutPlainTextIsNotPinnable() {
        let item = NSPasteboardItem()
        item.setData(Data("<b>bold</b>".utf8), forType: .html)
        guard case .unsupported = ClipboardPinService.image(from: item) else {
            Issue.record("HTML alone must not be parsed"); return
        }
    }
}

/// Share and drag files land in a scratch folder. Two shares of the same
/// capture name used to overwrite each other, swapping the attachment under an
/// already-open Mail draft.
final class TmpScratchDirectoryTests {

    @Test func testTwoSharesWithTheSameNameGetDistinctPaths() {
        let first = TmpScratchDirectory.makeURL(filename: "Screenshot 2026-09-19.png")
        let second = TmpScratchDirectory.makeURL(filename: "Screenshot 2026-09-19.png")
        #expect(first != second)
        #expect(first.lastPathComponent == second.lastPathComponent, "the receiving app should still see the configured filename")
        try? FileManager.default.removeItem(at: first.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: second.deletingLastPathComponent())
    }

    @Test func testTheContainingFolderExistsSoTheWriteSucceeds() throws {
        let url = TmpScratchDirectory.makeURL(filename: "note.txt")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try Data("hello".utf8).write(to: url)
        #expect((try String(contentsOf: url, encoding: .utf8)) == "hello")
    }

    @Test func testAnEmptyFilenameStillProducesAUsablePath() {
        let url = TmpScratchDirectory.makeURL(filename: "")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(!url.lastPathComponent.isEmpty)
    }

    @Test func testScratchFoldersAreInsideTheScratchDirectory() {
        let url = TmpScratchDirectory.makeURL(filename: "x.png")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(url.path.hasPrefix(TmpScratchDirectory.url.path), "a scratch file outside the swept folder would never be cleaned up")
    }
}

/// The launch sweep has to reach those per-share folders, or they pile up.
final class ScratchFolderSweepTests {

    private var directory: URL!

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macshot-sweepdir-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    isolated deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeFolder(_ name: String, ageInHours: Double, fileBytes: Int = 32) throws -> URL {
        let folder = directory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(repeating: 0x42, count: fileBytes).write(to: folder.appendingPathComponent("file.png"))
        if ageInHours > 0 {
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-ageInHours * 3600)],
                ofItemAtPath: folder.path)
        }
        return folder
    }

    @Test func testStaleFoldersAreRemoved() throws {
        let old = try makeFolder("old", ageInHours: 2)
        let result = DirectorySweeper.sweepDirectories(in: directory, olderThan: 300)
        #expect(result.removed == 1)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(result.bytesFreed > 0)
    }

    @Test func testAFolderStillInUseIsLeftAlone() throws {
        let fresh = try makeFolder("fresh", ageInHours: 0)
        let result = DirectorySweeper.sweepDirectories(in: directory, olderThan: 300)
        #expect(result.removed == 0)
        #expect(FileManager.default.fileExists(atPath: fresh.path), "a share the user just started must not be deleted from under it")
    }

    @Test func testLooseFilesAreNotTouchedByTheDirectorySweep() throws {
        let file = directory.appendingPathComponent("loose.png")
        try Data("x".utf8).write(to: file)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-7200)], ofItemAtPath: file.path)

        let result = DirectorySweeper.sweepDirectories(in: directory, olderThan: 300)
        #expect(result.removed == 0)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func testAMissingDirectoryIsNotAnError() {
        let result = DirectorySweeper.sweepDirectories(
            in: directory.appendingPathComponent("nope"), olderThan: 60)
        #expect(result.removed == 0)
    }
}
