import Cocoa
import Testing
@testable import macshot

/// History is the only place a capture survives after the overlay closes, and
/// "Edit" reopens it from these files. Each test gets its own directory, so
/// nothing here touches the user's real captures.
@MainActor
final class ScreenshotHistoryTests {

    private var directory: URL!

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macshot-history-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    isolated deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeHistory() -> ScreenshotHistory {
        ScreenshotHistory(directory: directory)
    }

    /// `add` finishes its file writes on a background queue, in a fixed order:
    /// composited image, thumbnail, preview, raw image, annotations, edit
    /// state. Waiting on the last file each capture expects avoids racing it.
    private func waitForWrites(_ history: ScreenshotHistory, entryCount: Int,
                               expecting suffixes: [String] = [".png", "_thumb.png", "_preview.png"],
                               sourceLocation: SourceLocation = #_sourceLocation) async {
        // `add` writes on a utility queue, which can be starved for several
        // seconds on a loaded machine (a parallel build, say), so wait
        // generously rather than flaking.
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            let files = Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            let complete = !history.hasPendingWrites && history.entries.count >= entryCount && history.entries.allSatisfy { entry in
                suffixes.allSatisfy { suffix in
                    let url = suffix == ".png" ? history.fileURL(for: entry) : history.sidecarURL(for: entry, suffix: suffix)
                    return FileManager.default.fileExists(atPath: url.path)
                }
            }
            if complete && files.contains("index.json") { return }
            // History publishes on the main actor; sleeping lets it run.
            try? await Task.sleep(for: .milliseconds(50))
        }
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
        Issue.record("history files were never written. entries=\(history.entries.map(\.id)) expected=\(suffixes) onDisk=\(files)", sourceLocation: sourceLocation)
    }

    private func annotations() -> [Annotation] {
        let rect = Annotation(tool: .rectangle, startPoint: NSPoint(x: 5, y: 5),
                              endPoint: NSPoint(x: 60, y: 40), color: .systemRed, strokeWidth: 4)
        rect.rectCornerRadius = 8
        let arrow = Annotation(tool: .arrow, startPoint: NSPoint(x: 10, y: 10),
                               endPoint: NSPoint(x: 90, y: 70), color: .systemBlue, strokeWidth: 6)
        arrow.arrowStyle = .double
        return [rect, arrow]
    }

    // MARK: - Round trip

    @Test func testACaptureComesBackAfterARestart() async throws {
        let image = ImageProbe.quadrantImage(width: 120, height: 90)
        let history = makeHistory()
        withDefaults(["historySize": 10, "historyUnlimited": false]) {
            history.add(image: image, rawImage: image, annotations: annotations())
        }
        await waitForWrites(history, entryCount: 1, expecting: [".png", "_thumb.png", "_preview.png", "_raw.png", "_annotations.json"])

        // A second instance reads the index from disk, like the next launch does.
        let reloaded = makeHistory()
        #expect(reloaded.entries.count == 1)
        let entry = try #require(reloaded.entries.first)
        #expect(entry.hasAnnotations)
        #expect(reloaded.loadImage(for: entry) != nil, "the capture image must reload")
        #expect(reloaded.loadRawImage(for: entry) != nil, "editing needs the un-annotated original")

        let restored = try #require(reloaded.loadAnnotations(for: entry))
        #expect(restored.count == 2)
        #expect(restored.map(\.tool) == [.rectangle, .arrow])
        #expect(restored[0].rectCornerRadius == 8)
        #expect(restored[1].arrowStyle == .double)
    }

    @Test func testARedactedCaptureKeepsOnlyTheFlattenedImage() async throws {
        let image = ImageProbe.quadrantImage(width: 120, height: 90)
        let history = makeHistory()
        let censor = Annotation(tool: .pixelate, startPoint: NSPoint(x: 10, y: 10),
                                endPoint: NSPoint(x: 50, y: 40), color: .black, strokeWidth: 1)
        var state = CaptureEditState()
        state.beautifyEnabled = true
        withDefaults(["historySize": 10, "historyUnlimited": false]) {
            history.add(image: image, rawImage: image, annotations: annotations() + [censor], editState: state)
        }
        await waitForWrites(history, entryCount: 1)

        let reloaded = makeHistory()
        let entry = try #require(reloaded.entries.first)
        #expect(reloaded.loadImage(for: entry) != nil, "the flattened capture must stay")
        #expect(reloaded.loadRawImage(for: entry) == nil, "the raw image would undo the redaction")
        #expect(!entry.hasAnnotations)
        #expect(reloaded.loadEditableCapture(for: entry) == nil, "the capture reopens flattened")
    }

    @Test func testEditStateSurvivesTheRoundTrip() async throws {
        var state = CaptureEditState()
        state.beautifyEnabled = true
        state.beautifyStyleIndex = 5
        state.beautifyPadding = 72

        let image = ImageProbe.quadrantImage(width: 80, height: 60)
        let history = makeHistory()
        withDefaults(["historySize": 10, "historyUnlimited": false]) {
            history.add(image: image, rawImage: image, annotations: nil, editState: state)
        }
        await waitForWrites(history, entryCount: 1, expecting: [".png", "_thumb.png", "_preview.png", "_edit.json"])

        let reloaded = makeHistory()
        let entry = try #require(reloaded.entries.first)
        let restored = try #require(reloaded.loadEditState(for: entry))
        #expect(restored == state)
    }

    @Test func testAnnotationsWrittenByAnOlderBuildStillLoad() async throws {
        // Same shape the app writes, but with only the fields the first version
        // had — what an entry saved before later fields existed looks like.
        let image = ImageProbe.quadrantImage(width: 60, height: 40)
        let history = makeHistory()
        withDefaults(["historySize": 10, "historyUnlimited": false]) {
            history.add(image: image, rawImage: image, annotations: annotations())
        }
        await waitForWrites(history, entryCount: 1, expecting: [".png", "_thumb.png", "_preview.png", "_annotations.json"])

        let entry = try #require(history.entries.first)
        let annotationFile = history.sidecarURL(for: entry, suffix: "_annotations.json")
        try Data("""
        [{"tool":3,"startX":1,"startY":2,"endX":30,"endY":40,"colorRGBA":[1,0,0,1],"strokeWidth":5}]
        """.utf8).write(to: annotationFile)

        let reloaded = makeHistory()
        let restoredInput = try #require(reloaded.entries.first)
        let restored = try #require(reloaded.loadAnnotations(for: restoredInput), "an entry from an older version must still open with its annotations")
        #expect(restored.count == 1)
        #expect(restored[0].tool == .rectangle)
    }

    @Test func testACorruptAnnotationFileLosesOnlyTheAnnotations() async throws {
        let image = ImageProbe.quadrantImage(width: 60, height: 40)
        let history = makeHistory()
        withDefaults(["historySize": 10, "historyUnlimited": false]) {
            history.add(image: image, rawImage: image, annotations: annotations())
        }
        await waitForWrites(history, entryCount: 1, expecting: [".png", "_thumb.png", "_preview.png", "_annotations.json"])

        let entry = try #require(history.entries.first)
        try Data("truncated{".utf8).write(to: history.sidecarURL(for: entry, suffix: "_annotations.json"))

        let reloaded = makeHistory()
        let reloadedEntry = try #require(reloaded.entries.first)
        #expect(reloaded.loadAnnotations(for: reloadedEntry) == nil)
        #expect(reloaded.loadImage(for: reloadedEntry) != nil, "the capture itself must still open")
    }

    @Test func testACorruptIndexDoesNotTakeTheCapturesWithIt() async throws {
        let history = makeHistory()
        withDefaults(["historySize": 10, "historyUnlimited": false]) {
            history.add(image: ImageProbe.quadrantImage(width: 40, height: 40), rawImage: nil, annotations: nil)
        }
        await waitForWrites(history, entryCount: 1)

        // One unreadable row among good ones.
        let entry = try #require(history.entries.first)
        let index = """
        [{"garbage":true},
         {"id":"\(entry.id)","revision":"\(entry.revision!)","fileExtension":"png","timestamp":0,"pixelWidth":40,"pixelHeight":40}]
        """
        try Data(index.utf8).write(to: directory.appendingPathComponent("index.json"))

        let reloaded = makeHistory()
        #expect(reloaded.entries.count == 1, "one bad row must not empty the history")
        #expect(reloaded.entries.first?.id == entry.id)
    }

    // MARK: - Pruning

    @Test func testEditableReopenRequiresReadablePresentSidecars() async throws {
        let image = ImageProbe.quadrantImage(width: 80, height: 60)
        var state = CaptureEditState()
        state.effectsBrightness = 0.2
        let history = makeHistory()
        withDefaults(["historySize": 10, "historyUnlimited": false]) {
            history.add(image: image, rawImage: image, annotations: annotations(), editState: state)
        }
        await history.waitUntilIdle()
        let entry = try #require(history.entries.first)
        let editable = try #require(history.loadEditableCapture(for: entry))
        #expect(editable.annotations.count == 2)
        #expect(editable.editState == state)
        let original = try Data(contentsOf: history.fileURL(for: entry))
        let editURL = history.sidecarURL(for: entry, suffix: "_edit.json")
        try Data("incomplete".utf8).write(to: editURL)
        #expect(history.loadEditableCapture(for: entry) == nil, "the UI must use its flattened-image fallback")
        #expect(history.loadImage(for: entry) != nil)
        #expect((try Data(contentsOf: history.fileURL(for: entry))) == original)
        try JSONEncoder().encode(state).write(to: editURL)
        try Data("incomplete".utf8).write(to: history.sidecarURL(for: entry, suffix: "_annotations.json"))
        #expect(history.loadEditableCapture(for: entry) == nil)
        #expect(history.loadImage(for: entry) != nil)
    }

    @Test func testEditableReopenSupportsEffectsOnlyAndLegacyAnnotationsOnly() async throws {
        let image = ImageProbe.quadrantImage(width: 80, height: 60)
        var state = CaptureEditState()
        state.effectsBrightness = 0.2
        let history = makeHistory()
        withDefaults(["historySize": 10, "historyUnlimited": false]) {
            history.add(image: image, rawImage: image, annotations: nil, editState: state)
            history.add(image: image, rawImage: image, annotations: annotations())
        }
        await history.waitUntilIdle()
        #expect(history.entries.count == 2)
        for entry in history.entries {
            let editable = try #require(history.loadEditableCapture(for: entry))
            if editable.editState != nil { #expect(editable.annotations.isEmpty) }
            else { #expect(editable.annotations.count == 2) }
            for suffix in ["_edit.json", "_annotations.json"] {
                let url = history.sidecarURL(for: entry, suffix: suffix)
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            }
            #expect(history.loadEditableCapture(for: entry) == nil, "raw pixels alone must not lose baked edits")
            #expect(history.loadImage(for: entry) != nil)
        }
    }

    @Test func testTheOldestCaptureIsDroppedWhenTheLimitIsReached() async {
        let history = makeHistory()
        await withDefaults(["historySize": 3, "historyUnlimited": false]) {
            for index in 0..<5 {
                history.add(image: ImageProbe.solidImage(width: 20 + index, height: 20), rawImage: nil, annotations: nil)
            }
            await waitForWrites(history, entryCount: 3)
            #expect(history.entries.count == 3)
        }
    }

    @Test func testNewestCapturesComeFirst() async {
        let history = makeHistory()
        withDefaults(["historySize": 5, "historyUnlimited": false]) {
            history.add(image: ImageProbe.solidImage(width: 10, height: 10), rawImage: nil, annotations: nil)
            history.add(image: ImageProbe.solidImage(width: 20, height: 20), rawImage: nil, annotations: nil)
        }
        await waitForWrites(history, entryCount: 2)
        #expect((history.entries.first?.pixelWidth ?? 0) == (history.entries.last.map { $0.pixelWidth * 2 } ?? -1), "the 20pt capture should be first")
    }

    @Test func testAZeroSizedHistoryStoresNothing() {
        let history = makeHistory()
        withDefaults(["historySize": 0, "historyUnlimited": false]) {
            history.add(image: ImageProbe.solidImage(), rawImage: nil, annotations: nil)
            #expect(history.entries.isEmpty, "history turned off must not write captures")
        }
    }

    @Test func testClearRemovesEveryEntryAndItsFiles() async {
        let history = makeHistory()
        withDefaults(["historySize": 5, "historyUnlimited": false]) {
            for _ in 0..<3 {
                history.add(image: ImageProbe.solidImage(), rawImage: nil, annotations: nil)
            }
        }
        await waitForWrites(history, entryCount: 3)

        history.clear()
        await waitForWrites(history, entryCount: 0)
        #expect(history.entries.isEmpty)

        let reloaded = makeHistory()
        #expect(reloaded.entries.isEmpty, "cleared captures must not come back on relaunch")
    }

    @Test func testRemovingOneEntryLeavesTheRest() async throws {
        let history = makeHistory()
        withDefaults(["historySize": 5, "historyUnlimited": false]) {
            for _ in 0..<3 {
                history.add(image: ImageProbe.solidImage(), rawImage: nil, annotations: nil)
            }
        }
        await waitForWrites(history, entryCount: 3)

        let doomed = try #require(history.entries.first?.id)
        history.removeEntry(id: doomed)
        await waitForWrites(history, entryCount: 2)
        #expect(history.entries.count == 2)
        #expect(!(history.entries.contains { $0.id == doomed }))

        let reloaded = makeHistory()
        #expect(reloaded.entries.count == 2)
    }

    @Test func testAnEntryWhoseImageWasDeletedIsSkippedOnLoad() async throws {
        let history = makeHistory()
        withDefaults(["historySize": 5, "historyUnlimited": false]) {
            history.add(image: ImageProbe.solidImage(), rawImage: nil, annotations: nil)
        }
        await waitForWrites(history, entryCount: 1)

        let entry = try #require(history.entries.first)
        try FileManager.default.removeItem(at: history.fileURL(for: entry))

        let reloaded = makeHistory()
        #expect(reloaded.entries.isEmpty, "an entry with no image would show as a broken thumbnail")
    }

    // MARK: - Entry metadata

    @Test func testTimeAgoReadsNaturallyAtEachStep() {
        let now = Date()
        let cases: [(TimeInterval, String)] = [
            (-2, "just now"),
            (-30, "s ago"),
            (-60 * 5, "m ago"),
            (-60 * 60 * 3, "h ago"),
        ]
        for (offset, expected) in cases {
            let entry = HistoryEntry(id: "x", fileExtension: "png", timestamp: now.addingTimeInterval(offset),
                                     lastEditedAt: nil, pixelWidth: 10, pixelHeight: 10,
                                     hasAnnotations: false, thumbnail: nil)
            #expect(entry.timeAgoString.lowercased().contains(expected.lowercased()), "\(offset)s ago rendered as \(entry.timeAgoString)")
        }
    }

    @Test func testAnEditedCaptureSortsByWhenItWasEdited() {
        let created = Date(timeIntervalSince1970: 1_000)
        let edited = Date(timeIntervalSince1970: 2_000)
        let entry = HistoryEntry(id: "x", fileExtension: "png", timestamp: created, lastEditedAt: edited,
                                 pixelWidth: 1, pixelHeight: 1, hasAnnotations: true, thumbnail: nil)
        #expect(entry.effectiveSortDate == edited)

        let untouched = HistoryEntry(id: "y", fileExtension: "png", timestamp: created, lastEditedAt: nil,
                                     pixelWidth: 1, pixelHeight: 1, hasAnnotations: false, thumbnail: nil)
        #expect(untouched.effectiveSortDate == created)
    }
}
