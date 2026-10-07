import Cocoa
import Testing
@testable import macshot

@MainActor
final class HistoryFileCleanupTests {
    private var directory: URL!
    private let cleanupQueue = DispatchQueue(label: "macshot.tests.history-cleanup")
    private let now = Date()

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    isolated deinit {
        cleanupQueue.sync {}
        try? FileManager.default.removeItem(at: directory)
    }

    @discardableResult
    private func file(_ name: String, age: TimeInterval = 48 * 60 * 60) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data("retained capture bytes".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.path)
        return url
    }

    private func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path)
    }

    @Test func testMissingUnreadableAndPartlySalvagedIndexesPreserveEveryFile() throws {
        let id = UUID().uuidString
        let names = ["\(id).png", "\(id)_raw.png", "\(id)_thumb.png", "\(id)_preview.png", "\(id)_annotations.json"]
        for name in names { try file(name) }
        for payload: String? in [nil, "truncated{", "[{\"id\":\"\(id)\"},{}]"] {
            if let payload { try Data(payload.utf8).write(to: directory.appendingPathComponent("index.json")) }
            withDefaults(["historySize": 10, "historyUnlimited": false]) {
                let history = ScreenshotHistory(directory: directory, cleanupQueue: cleanupQueue)
                cleanupQueue.sync {}
                for name in names { #expect(exists(name), "\(name)") }
                withExtendedLifetime(history) {}
            }
        }
    }

    @Test func testACompleteIndexAllowsOnlyOldUnreferencedDerivedCachesToBeRemoved() throws {
        let orphan = UUID().uuidString, known = UUID().uuidString, fresh = UUID().uuidString
        let originalSuffixes = [".png", "_raw.png", "_annotations.json", "_edit.json", "_other.png"]
        for suffix in originalSuffixes { try file(orphan + suffix) }
        for id in [orphan, known] { try file(id + "_thumb.png"); try file(id + "_preview.png") }
        try file(fresh + "_thumb.png", age: 3600)
        let result = HistoryFileCleanup.sweep(directory: directory, indexedIDs: [known.lowercased()], asOf: now)
        #expect(result.removed == 2)
        #expect(!exists(orphan + "_thumb.png"))
        #expect(!exists(orphan + "_preview.png"))
        for suffix in originalSuffixes { #expect(exists(orphan + suffix)) }
        #expect(exists(known + "_thumb.png"))
        #expect(exists(known + "_preview.png"))
        #expect(exists(fresh + "_thumb.png"))
    }

    @Test func testQueuedStartupCleanupPreservesFilesWrittenAfterTheIndexWasRead() throws {
        try Data("[]".utf8).write(to: directory.appendingPathComponent("index.json"))
        cleanupQueue.suspend()
        let history = ScreenshotHistory(directory: directory, cleanupQueue: cleanupQueue)
        let id = UUID().uuidString
        do {
            try file(id + ".png", age: 0)
            try file(id + "_thumb.png", age: 0)
        } catch { cleanupQueue.resume(); throw error }
        cleanupQueue.resume()
        cleanupQueue.sync {}
        #expect(exists(id + ".png"))
        #expect(exists(id + "_thumb.png"))
        withExtendedLifetime(history) {}
    }

    @Test func testDuplicateRowsCannotPruneTheOnlyImageForThatIdentifier() throws {
        let id = UUID().uuidString
        try file(id + ".png")
        try Data("[{\"id\":\"\(id)\"},{\"id\":\"\(id)\"}]".utf8)
            .write(to: directory.appendingPathComponent("index.json"))
        withDefaults(["historySize": 1, "historyUnlimited": false]) {
            let history = ScreenshotHistory(directory: directory, cleanupQueue: cleanupQueue)
            cleanupQueue.sync {}
            #expect(history.entries.count == 1)
            #expect(exists(id + ".png"))
        }
    }

    @Test func testInvalidNamesAreSkippedAndInvalidMetadataUsesSafeDefaults() throws {
        let id = UUID().uuidString
        let data = try JSONSerialization.data(withJSONObject: [
            ["id": "invalid identifier", "fileExtension": "png"],
            ["id": UUID().uuidString, "fileExtension": "unsupported"],
            ["id": id, "timestamp": 1e200, "lastEditedAt": -1e200, "pixelWidth": -3, "pixelHeight": -4],
        ])
        let rows = try #require(LenientArrayDecoder.decode(ScreenshotHistory.IndexEntry.self, from: data))
        #expect(rows.count == 1)
        #expect(rows[0].id == id)
        #expect(rows[0].fileExtension == "png")
        #expect(rows[0].timestamp == Date(timeIntervalSince1970: 0))
        #expect(rows[0].lastEditedAt == nil)
        #expect(rows[0].pixelWidth == 0)
        #expect(rows[0].pixelHeight == 0)
    }

    @Test func testUnusableDatesDoNotTrapWhenTheHistoryLabelIsDrawn() {
        for value in [Double.nan, .infinity, -.infinity, 1e200] {
            let entry = HistoryEntry(id: UUID().uuidString, fileExtension: "png",
                timestamp: Date(timeIntervalSince1970: value), pixelWidth: 1, pixelHeight: 1)
            #expect(entry.timeAgoString == "-")
        }
    }
}
