import Cocoa
import Testing
@testable import macshot

/// A capture that can't be written used to vanish without a word: the overlay
/// dismissed, the thumbnail animated, and the only trace was a DEBUG-only log.
/// These pin the reporting path that replaced it.
final class ImageSaveServiceTests {

    private var directory: URL!
    private var reported: [String] = []

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macshot-save-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        reported = []
        ImageSaveService.onFailure = { [weak self] message in
            self?.reported.append(message)
        }
    }

    isolated deinit {
        ImageSaveService.onFailure = nil
        UserDefaults.standard.removeObject(forKey: ImageSaveService.copyPathAfterSaveKey)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        try? FileManager.default.removeItem(at: directory)
    }

    /// The write happens on a background queue and the completion hops back to
    /// main, so tests wait for it explicitly.
    @discardableResult
    private func save(_ image: NSImage, as filename: String) async -> Bool {
        let finished = TestExpectation(description: "save finished")
        var result = false
        ImageSaveService.writeImageForTesting(image, toDirectory: directory, filename: filename) { success in
            result = success
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 5)
        return result
    }

    private var savedFiles: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    // MARK: - Writing

    @Test func testASavedScreenshotLandsOnDisk() async throws {
        await withDefaults(["imageFormat": "png", "downscaleRetina": false]) {
            #expect(await save(ImageProbe.quadrantImage(width: 40, height: 30), as: "shot.png"))
        }
        #expect(savedFiles == ["shot.png"])
        #expect(reported.isEmpty, "a successful save must not report a failure")

        let reloaded = try #require(NSImage(contentsOf: directory.appendingPathComponent("shot.png")))
        let bitmap = try #require(ImageProbe.bitmap(from: reloaded))
        #expect(bitmap.pixelsWide == 40)
    }

    @Test func testASecondSaveDoesNotOverwriteTheFirst() async {
        await withDefaults(["imageFormat": "png", "downscaleRetina": false]) {
            await save(ImageProbe.solidImage(width: 10, height: 10), as: "shot.png")
            await save(ImageProbe.solidImage(width: 20, height: 20), as: "shot.png")
        }
        #expect(savedFiles.count == 2, "the second capture must not replace the first")
        #expect(savedFiles.contains("shot.png"))
    }

    @Test func testManySavesWithTheSameNameAllSurvive() async {
        await withDefaults(["imageFormat": "png", "downscaleRetina": false]) {
            for _ in 0..<5 {
                await save(ImageProbe.solidImage(width: 8, height: 8), as: "same.png")
            }
        }
        #expect(savedFiles.count == 5, "five captures in the same second must produce five files")
        #expect(Set(savedFiles).count == 5, "and five distinct names")
    }

    @Test func testCopyPathAfterSaveWritesTheActualAvailablePathToTheClipboard() async {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("sentinel", forType: .string)

        await withDefaults([
            "imageFormat": "png",
            "downscaleRetina": false,
            ImageSaveService.copyPathAfterSaveKey: true,
        ]) {
            #expect(await save(ImageProbe.solidImage(), as: "shot.png"))
            #expect(await save(ImageProbe.solidImage(), as: "shot.png"))
        }

        #expect(pasteboard.string(forType: .string) == directory.appendingPathComponent("shot (2).png").standardizedFileURL.path)
    }

    @Test func testCopyPathAfterSaveIsOffByDefault() async {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("sentinel", forType: .string)

        await withDefaults([
            "imageFormat": "png",
            "downscaleRetina": false,
            ImageSaveService.copyPathAfterSaveKey: nil,
        ]) {
            #expect(!ImageSaveService.copyPathAfterSave)
            #expect(await save(ImageProbe.solidImage(), as: "shot.png"))
        }

        #expect(pasteboard.string(forType: .string) == "sentinel")
    }

    @Test func testQuickCaptureModesKeepTheirPersistedValuesAndOutputSemantics() {
        let expected: [(QuickCaptureMode, Int, Bool, Bool, Bool?)] = [
            (.saveToFile, 0, false, true, nil),
            (.copyImage, 1, true, false, nil),
            (.saveAndCopyImage, 2, true, true, nil),
            (.doNothing, 3, false, false, nil),
            (.saveAndCopyPath, 4, false, true, true),
        ]

        for (mode, rawValue, copiesImage, saves, pathOverride) in expected {
            #expect(mode.rawValue == rawValue)
            #expect(mode.shouldCopyImage == copiesImage)
            #expect(mode.shouldSave == saves)
            #expect(mode.copyPathOverride == pathOverride)
            #expect(!mode.title.isEmpty)
        }
    }

    @Test func testQuickCaptureModeDefaultsSafelyForMissingOrUnknownValues() {
        withDefaults([QuickCaptureMode.userDefaultsKey: nil]) {
            #expect(QuickCaptureMode.current == .copyImage)
        }
        withDefaults([QuickCaptureMode.userDefaultsKey: 99]) {
            #expect(QuickCaptureMode.current == .copyImage)
        }
    }

    // MARK: - Failure reporting

    @Test func testConcurrentSavesAreCoordinatedAndKeepEveryDistinctImage() async throws {
        let finished = TestExpectation(description: "all concurrent saves complete")
        finished.expectedFulfillmentCount = 12
        withDefaults(["imageFormat": "png", "downscaleRetina": false]) {
            for width in 10..<22 {
                ImageSaveService.writeImageForTesting(ImageProbe.solidImage(width: width, height: 8),
                    toDirectory: directory, filename: "concurrent.png") { success in
                        #expect(success)
                        finished.fulfill()
                    }
            }
        }
        #expect(MediaExportCoordinator.shared.hasActiveJobs, "Quit must see pending screenshot saves")
        await fulfillment(of: [finished], timeout: 10)
        #expect(!MediaExportCoordinator.shared.hasActiveJobs)
        let widths = try savedFiles.map { name in
            let image = try #require(NSImage(contentsOf: directory.appendingPathComponent(name)))
            return try #require(ImageProbe.bitmap(from: image)).pixelsWide
        }
        #expect(widths.sorted() == Array(10..<22))
    }

    @Test func testFailedSaveAsPreservesExistingFile() async throws {
        let destination = directory.appendingPathComponent("existing.png")
        let original = Data("original destination remains intact".utf8)
        try original.write(to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        let prepared = try ImageEncoder.PreparedImage(ImageProbe.solidImage())
        let finished = TestExpectation(description: "failed replacement")
        ImageSaveService.writePreparedImage(prepared, to: destination, chooseAvailableName: false) { success in
            #expect(!success)
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 5)
        #expect((try Data(contentsOf: destination)) == original)
    }

    @Test func testAFailedWriteIsReportedToTheUser() async {
        // Make the directory read-only so the write fails the way a full disk
        // or an unmounted volume would.
        try? FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)

        var succeeded = true
        await withDefaults(["imageFormat": "png", "downscaleRetina": false]) {
            succeeded = await save(ImageProbe.solidImage(), as: "denied.png")
        }

        #expect(!succeeded)
        // The report is dispatched to main; let it land.
        let reportArrived = TestExpectation(description: "failure reported")
        DispatchQueue.main.async { reportArrived.fulfill() }
        await fulfillment(of: [reportArrived], timeout: 5)

        #expect(!reported.isEmpty, "a save that failed must tell the user, not just return false")
        #expect(reported.first?.lowercased().contains("save") == true, "the message should say what failed, got: \(reported)")
    }

    @Test func testAMissingDirectoryIsReported() async {
        let missing = directory.appendingPathComponent("not-created")
        let finished = TestExpectation(description: "save finished")
        var succeeded = true
        withDefaults(["imageFormat": "png"]) {
            ImageSaveService.writeImageForTesting(ImageProbe.solidImage(), toDirectory: missing,
                                                  filename: "x.png") { success in
                succeeded = success
                finished.fulfill()
            }
        }
        await fulfillment(of: [finished], timeout: 5)
        #expect(!succeeded)

        let reportArrived = TestExpectation(description: "failure reported")
        DispatchQueue.main.async { reportArrived.fulfill() }
        await fulfillment(of: [reportArrived], timeout: 5)
        #expect(!reported.isEmpty)
    }

    @Test func testTemplateSubfoldersAreCreatedOnlyBelowAnExistingSaveFolder() throws {
        let nested = directory.appendingPathComponent("2026/09/25/Safari-14.30.05.png")
        try ImageSaveService.createSubfolders(for: nested, below: directory)
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: nested.deletingLastPathComponent().path,
                                                     isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)

        // A vanished save folder is never recreated.
        let missingRoot = directory.appendingPathComponent("unplugged-drive")
        try ImageSaveService.createSubfolders(for: missingRoot.appendingPathComponent("2026/x.png"), below: missingRoot)
        #expect(!FileManager.default.fileExists(atPath: missingRoot.path))

        // Paths outside the save folder are ignored.
        let outside = directory.deletingLastPathComponent().appendingPathComponent("elsewhere-\(UUID().uuidString)/x.png")
        try ImageSaveService.createSubfolders(for: outside, below: directory)
        #expect(!FileManager.default.fileExists(atPath: outside.deletingLastPathComponent().path))
    }

    @Test func testTheDefaultSaveActionIsToUseTheConfiguredFolder() {
        withDefaults([SaveActionPreference.userDefaultsKey: nil]) {
            #expect(SaveActionPreference.current == .saveToFolder)
        }
        withDefaults([SaveActionPreference.userDefaultsKey: 99]) {
            #expect(SaveActionPreference.current == .saveToFolder, "an unknown stored value must fall back")
        }
    }

    @Test func testEverySaveActionHasATitle() {
        for action in SaveActionPreference.allCases {
            #expect(!action.title.isEmpty)
        }
    }
}
