import AppKit
import Testing
@testable import macshot

@MainActor
final class HistoryTransactionTests {
    private var directory: URL!
    private let queue = DispatchQueue(label: "macshot.tests.history-transactions")
    private let failure = FailureSwitch()

    private final class FailureSwitch: @unchecked Sendable {
        private let lock = NSLock()
        nonisolated(unsafe) private var enabled = false
        nonisolated func set(_ value: Bool) { lock.lock(); enabled = value; lock.unlock() }
        nonisolated func check() throws {
            lock.lock(); let fail = enabled; lock.unlock()
            if fail { throw CocoaError(.fileWriteOutOfSpace) }
        }
    }

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        failure.set(false)
    }
    isolated deinit {
        queue.sync {}
        try? FileManager.default.removeItem(at: directory)
    }
    private func history() -> ScreenshotHistory {
        let failure = self.failure
        return ScreenshotHistory(directory: directory, writeQueue: queue, beforeIndexPublication: { try failure.check() })
    }
    private func annotation() -> Annotation {
        Annotation(tool: .rectangle, startPoint: .zero, endPoint: NSPoint(x: 10, y: 10), color: .red, strokeWidth: 3)
    }

    @Test func testQueuedWritesOwnBothImagesAndAnnotationValues() async throws {
        let history = history()
        let image = ImageProbe.quadrantImage(width: 80, height: 60)
        let raw = ImageProbe.solidImage(width: 40, height: 30)
        let originalPixels = try #require(ImageProbe.bitmap(from: image))
        let probes = ImageProbe.samplePoints(width: 80, height: 60)
        let originalColors = probes.map { ImageProbe.describePixel(bitmap: originalPixels, x: $0.x, y: $0.y) }
        let annotation = annotation()
        queue.suspend()
        let id = history.add(image: image, rawImage: raw, annotations: [annotation])
        #expect(id != nil)
        #expect(history.entries.isEmpty, "Unwritten captures must not be published in history")
        for representation in image.representations { image.removeRepresentation(representation) }
        for representation in raw.representations { raw.removeRepresentation(representation) }
        image.size = CGSize(width: 1, height: 1)
        raw.size = CGSize(width: 1, height: 1)
        annotation.strokeWidth = 99
        queue.resume()
        await history.waitUntilIdle()
        let entry = try #require(history.entries.first)
        #expect(entry.id == id)
        #expect(entry.pixelWidth == 80)
        #expect(entry.pixelHeight == 60)
        #expect((try #require(history.loadImage(for: entry)).size) == CGSize(width: 80, height: 60))
        #expect((try #require(history.loadRawImage(for: entry)).size) == CGSize(width: 40, height: 30))
        #expect((try #require(history.loadAnnotations(for: entry)).first?.strokeWidth) == 3)
        let savedPixelsInput = try #require(history.loadImage(for: entry))
        let savedPixels = try #require(ImageProbe.bitmap(from: savedPixelsInput))
        #expect((probes.map { ImageProbe.describePixel(bitmap: savedPixels, x: $0.x, y: $0.y) }) == originalColors)
    }

    @Test func testRetinaCaptureKeepsLogicalSizeAndSharpBoundedCaches() async throws {
        let history = history()
        let image = ImageProbe.quadrantImage(width: 960, height: 640)
        image.size = CGSize(width: 480, height: 320)
        history.add(image: image)
        await history.waitUntilIdle()
        let entry = try #require(history.entries.first)
        let saved = try #require(history.loadImage(for: entry))
        #expect(abs(saved.size.width - (480)) <= 0.05)
        #expect(abs(saved.size.height - (320)) <= 0.05)
        #expect(entry.pixelWidth == 960)
        #expect(entry.pixelHeight == 640)
        let thumbnail = try #require(history.loadThumbnail(for: entry))
        #expect(abs(thumbnail.size.width - (36)) <= 0.05)
        #expect(abs(thumbnail.size.height - (24)) <= 0.05)
        #expect((try #require(ImageProbe.bitmap(from: thumbnail)).pixelsWide) == 72)
        let preview = try #require(HistoryImageSnapshot.preview(at: history.previewURLs(for: entry)))
        #expect(preview.width == 480)
        #expect(preview.height == 320)
    }

    @Test func testMissingLegacyPreviewDecodesABoundedOriginal() async throws {
        let id = UUID().uuidString
        let original = directory.appendingPathComponent(id + ".png")
        try HistoryImageSnapshot.Image(ImageProbe.quadrantImage(width: 2400, height: 1600)).writePNG(to: original)
        try Data("[{\"id\":\"\(id)\"}]".utf8).write(to: directory.appendingPathComponent("index.json"))
        let history = history()
        let entry = try #require(history.entries.first)
        let urls = history.previewURLs(for: entry)
        let image = await Task.detached { HistoryImageSnapshot.preview(at: urls) }.value
        let preview = try #require(image)
        #expect(preview.width == 480)
        #expect(preview.height == 320)
        #expect(HistoryImageSnapshot.preview(at: urls, maximumPixels: 0) == nil)
    }

    @Test func testUpdateFollowedByClearCannotRecreateFilesOrRows() async throws {
        let history = history()
        queue.suspend()
        let id = history.add(image: ImageProbe.solidImage(width: 40, height: 30))
        if let id {
            history.updateEntry(id: id, compositedImage: ImageProbe.solidImage(width: 80, height: 60), rawImage: nil, annotations: nil)
        }
        history.clear()
        queue.resume()
        #expect(id != nil)
        await history.waitUntilIdle()
        #expect(history.entries.isEmpty)
        #expect(ScreenshotHistory(directory: directory).entries.isEmpty)
        #expect((try FileManager.default.contentsOfDirectory(atPath: directory.path)) == ["index.json"])
    }

    @Test func testFailedUpdatePreservesEveryPreviouslyCommittedArtifact() async throws {
        let history = history()
        let image = ImageProbe.quadrantImage(width: 40, height: 30)
        history.add(image: image, rawImage: image, annotations: [annotation()])
        await history.waitUntilIdle()
        let entry = try #require(history.entries.first)
        let originalIndex = try Data(contentsOf: directory.appendingPathComponent("index.json"))
        let urls = [history.fileURL(for: entry), history.sidecarURL(for: entry, suffix: "_raw.png"),
                    history.sidecarURL(for: entry, suffix: "_annotations.json")]
        let originals = try urls.map { try Data(contentsOf: $0) }
        failure.set(true)
        var saved: Bool?
        history.updateEntry(id: entry.id, compositedImage: ImageProbe.solidImage(width: 100, height: 90),
                            rawImage: nil, annotations: nil, completion: { saved = $0 })
        await history.waitUntilIdle()
        #expect(saved == false)
        #expect(history.entries.first?.revision == entry.revision)
        #expect((try Data(contentsOf: directory.appendingPathComponent("index.json"))) == originalIndex)
        #expect((try urls.map { try Data(contentsOf: $0) }) == originals)
        #expect(history.loadAnnotations(for: entry)?.first?.strokeWidth == 3)
        #expect(ScreenshotHistory(directory: directory).entries.first?.revision == entry.revision)
    }

    @Test func testFailedIndexDeletionRestoresTheRowAndKeepsItsImage() async throws {
        let history = history()
        history.add(image: ImageProbe.solidImage())
        await history.waitUntilIdle()
        let entry = try #require(history.entries.first)
        failure.set(true)
        history.removeEntry(id: entry.id)
        #expect(history.entries.isEmpty)
        await history.waitUntilIdle()
        #expect(history.entries.first?.id == entry.id)
        #expect(history.loadImage(for: entry) != nil)
        #expect(ScreenshotHistory(directory: directory).entries.first?.id == entry.id)
    }

    @Test func testUnencodableEditCannotReplaceAValidCapture() async throws {
        let history = history()
        history.add(image: ImageProbe.solidImage())
        await history.waitUntilIdle()
        let entry = try #require(history.entries.first)
        var success: Bool?
        history.updateEntry(id: entry.id, compositedImage: NSImage(size: NSSize(width: 0, height: 0)),
                            rawImage: nil, annotations: nil, completion: { success = $0 })
        #expect(success == false)
        #expect(history.entries.first?.revision == entry.revision)
        #expect(history.loadImage(for: entry) != nil)
    }

    @Test func testDisabledHistoryDoesNotReturnAnOlderCapturesIdentifier() async throws {
        let history = history()
        history.add(image: ImageProbe.solidImage())
        await history.waitUntilIdle()
        withDefaults(["historySize": 0, "historyUnlimited": false]) {
            #expect(history.add(image: ImageProbe.solidImage()) == nil)
        }
    }

    @Test func testSerializedUpdatesPublishOnlyCompleteMatchingRevisions() async throws {
        let history = history()
        let id = try #require(history.add(image: ImageProbe.solidImage(width: 20, height: 20)))
        await history.waitUntilIdle()
        queue.suspend()
        let raw = ImageProbe.quadrantImage(width: 30, height: 20)
        history.updateEntry(id: id, compositedImage: raw, rawImage: raw, annotations: [annotation()])
        history.updateEntry(id: id, compositedImage: ImageProbe.solidImage(width: 80, height: 70),
                            rawImage: nil, annotations: nil)
        queue.resume()
        await history.waitUntilIdle()
        let reloaded = ScreenshotHistory(directory: directory)
        let entry = try #require(reloaded.entries.first)
        #expect(entry.pixelWidth == 80)
        #expect(entry.pixelHeight == 70)
        #expect(!entry.hasAnnotations)
        #expect(reloaded.loadRawImage(for: entry) == nil)
        #expect(reloaded.loadAnnotations(for: entry) == nil)
        #expect((try #require(reloaded.loadImage(for: entry)).size) == CGSize(width: 80, height: 70))
        let revisions = try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent(id).path)
        #expect(revisions == [entry.revision!])
    }

    @Test func testLegacyFlatCaptureRemainsReadableAndMigratesOnlyAfterSuccessfulEdit() async throws {
        let id = UUID().uuidString
        let original = directory.appendingPathComponent(id + ".png")
        try HistoryImageSnapshot.Image(ImageProbe.quadrantImage(width: 30, height: 20)).writePNG(to: original)
        try Data("[{\"id\":\"\(id)\",\"pixelWidth\":30,\"pixelHeight\":20}]".utf8)
            .write(to: directory.appendingPathComponent("index.json"))
        let history = history()
        let before = try #require(history.entries.first)
        #expect(before.revision == nil)
        #expect(history.loadImage(for: before) != nil)
        history.updateEntry(id: id, compositedImage: ImageProbe.solidImage(width: 60, height: 40), rawImage: nil, annotations: nil)
        await history.waitUntilIdle()
        let after = try #require(history.entries.first)
        #expect(after.revision != nil)
        #expect(history.loadImage(for: after) != nil)
        #expect(!FileManager.default.fileExists(atPath: original.path))
        #expect(ScreenshotHistory(directory: directory).entries.first?.revision == after.revision)
    }

    @Test func testFailedNewCaptureReportsFailureWithoutPublishingAPhantomRow() async throws {
        let reported = TestExpectation(description: "History save failure is visible")
        ImageSaveService.onFailure = { message in
            #expect(message.contains("history"))
            reported.fulfill()
        }
        defer { ImageSaveService.onFailure = nil }
        let history = history()
        failure.set(true)
        var saved: Bool?
        history.add(image: ImageProbe.solidImage(), completion: { saved = $0 })
        await history.waitUntilIdle()
        await fulfillment(of: [reported], timeout: 3)
        #expect(saved == false)
        #expect(history.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("index.json").path))
    }

    @Test func testPendingPixelBudgetRejectsAnotherCaptureAndRecoversAfterDrain() async throws {
        let history = ScreenshotHistory(directory: directory, writeQueue: queue, maximumPendingBytes: 8_192)
        let image = ImageProbe.solidImage(width: 32, height: 32)
        var errors: [String] = []
        let previous = ImageSaveService.onFailure
        ImageSaveService.onFailure = { errors.append($0) }
        defer { ImageSaveService.onFailure = previous }
        queue.suspend()
        let first = history.add(image: image)
        let second = history.add(image: image)
        var rejected: Bool?
        let third = history.add(image: image, completion: { rejected = $0 })
        let retained = history.pendingSnapshotBytes
        queue.resume()
        #expect(first != nil)
        #expect(second != nil)
        #expect(third == nil)
        #expect(rejected == false)
        #expect(retained == 8_192)
        await history.waitUntilIdle()
        #expect(errors.count == 1)
        #expect(errors.first?.contains("History is busy saving. Please try again shortly.") == true)
        #expect(history.pendingSnapshotBytes == 0)
        #expect(Set(history.entries.map(\.id)) == Set([first!, second!]))
        #expect(history.add(image: image) != nil)
        await history.waitUntilIdle()
        #expect(history.entries.count == 3)
    }

    @Test func testSaveCountLimitAndFailedPublicationReleaseTheirReservations() async throws {
        let failure = self.failure
        let history = ScreenshotHistory(directory: directory, writeQueue: queue,
            maximumPendingBytes: 1_048_576, maximumPendingSaves: 1,
            beforeIndexPublication: { try failure.check() })
        let image = ImageProbe.solidImage(width: 32, height: 32)
        let id = try #require(history.add(image: image))
        await history.waitUntilIdle()
        let oldIndex = try Data(contentsOf: directory.appendingPathComponent("index.json"))
        failure.set(true)
        queue.suspend()
        history.updateEntry(id: id, compositedImage: image, rawImage: nil, annotations: nil)
        var rejected: Bool?
        history.updateEntry(id: id, compositedImage: image, rawImage: nil, annotations: nil, completion: { rejected = $0 })
        queue.resume()
        #expect(rejected == false)
        await history.waitUntilIdle()
        #expect(history.pendingSnapshotBytes == 0)
        #expect((try Data(contentsOf: directory.appendingPathComponent("index.json"))) == oldIndex)
        failure.set(false)
        var saved: Bool?
        history.updateEntry(id: id, compositedImage: image, rawImage: nil, annotations: nil, completion: { saved = $0 })
        await history.waitUntilIdle()
        #expect(saved == true)
    }

    @Test func testOneOversizedCaptureCanSaveAloneAndAllSnapshotDataIsCounted() async throws {
        let image = ImageProbe.solidImage(width: 32, height: 32)
        let raw = ImageProbe.solidImage(width: 16, height: 16)
        let annotations = [annotation()]
        let snapshot = try HistoryImageSnapshot(image: image, rawImage: raw, annotations: annotations, editState: nil)
        #expect(snapshot.retainedBytes == (32 * 32 * 4 + 16 * 16 * 4 + (snapshot.annotations?.count ?? 0)))
        let history = ScreenshotHistory(directory: directory, writeQueue: queue, maximumPendingBytes: 1_024)
        queue.suspend()
        let first = history.add(image: image, rawImage: raw, annotations: annotations)
        let second = history.add(image: image)
        let retained = history.pendingSnapshotBytes
        queue.resume()
        #expect(first != nil)
        #expect(second == nil)
        #expect(retained == snapshot.retainedBytes)
        await history.waitUntilIdle()
        #expect(history.pendingSnapshotBytes == 0)
        #expect(history.entries.count == 1)
        #expect(history.loadRawImage(for: try #require(history.entries.first)) != nil)
    }
}
