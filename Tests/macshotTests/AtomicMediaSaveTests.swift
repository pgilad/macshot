import Foundation
import Testing
@testable import macshot

final class AtomicMediaSaveTests {
    private var directory: URL!

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    isolated deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func testFailedPrePublicationCheckKeepsThePreviousDestination() throws {
        let destination = directory.appendingPathComponent("saved.png")
        let previous = Data("previous file".utf8)
        try previous.write(to: destination)
        let save = try AtomicMediaSave(destinationURL: destination)
        try Data("complete new file".utf8).write(to: save.stagingURL)
        #expect(throws: CancellationError.self) {
            try save.commit(beforePublish: { throw CancellationError() })
        }
        #expect((try Data(contentsOf: destination)) == previous)
    }

    @Test func testMissingAndEmptyOutputNeverReplacesDestination() throws {
        let destination = directory.appendingPathComponent("saved.png")
        let previous = Data("only good file".utf8)
        try previous.write(to: destination)
        let save = try AtomicMediaSave(destinationURL: destination)
        #expect(throws: (any Error).self) { try save.commit() }
        try Data().write(to: save.stagingURL)
        #expect(throws: (any Error).self) { try save.commit() }
        #expect((try Data(contentsOf: destination)) == previous)
    }

    @Test func testAbandonedPartialOutputLeavesDestinationIntact() throws {
        let destination = directory.appendingPathComponent("saved.png")
        let previous = Data("only good file".utf8)
        try previous.write(to: destination)
        var save: AtomicMediaSave? = try AtomicMediaSave(destinationURL: destination)
        try Data("incomplete encoding".utf8).write(to: #require(save?.stagingURL))
        save = nil
        #expect((try Data(contentsOf: destination)) == previous)
    }

    @Test func testFailedRenameLeavesBothDestinationAndStagedOutputAvailable() throws {
        let destination = directory.appendingPathComponent("folder.png")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let original = destination.appendingPathComponent("do not remove.txt")
        try Data("original".utf8).write(to: original)
        let save = try AtomicMediaSave(destinationURL: destination)
        let output = Data("finished encoding".utf8)
        try output.write(to: save.stagingURL)
        #expect(throws: (any Error).self) { try save.commit() }
        #expect((try Data(contentsOf: save.stagingURL)) == output)
        #expect((try Data(contentsOf: original)) == Data("original".utf8))
    }

    @Test func testSeparateJobsHaveIndependentStagingEvenWithSameDestination() throws {
        let destination = directory.appendingPathComponent("saved.png")
        let first = try AtomicMediaSave(destinationURL: destination)
        let second = try AtomicMediaSave(destinationURL: destination)
        #expect(first.stagingURL != second.stagingURL)
        try Data("first".utf8).write(to: first.stagingURL)
        try Data("second".utf8).write(to: second.stagingURL)
        try first.commit()
        #expect((try Data(contentsOf: destination)) == Data("first".utf8))
        try second.commit()
        #expect((try Data(contentsOf: destination)) == Data("second".utf8))
    }

    @Test func testExclusivePublicationProtectsAFileCreatedAfterDestinationWasChosen() throws {
        let destination = directory.appendingPathComponent("saved.png")
        let save = try AtomicMediaSave(destinationURL: destination)
        try Data("new file".utf8).write(to: save.stagingURL)
        try Data("another app's file".utf8).write(to: destination)
        #expect(throws: (any Error).self) { try save.commit(overwritingExisting: false) }
        #expect((try Data(contentsOf: destination)) == Data("another app's file".utf8))
    }
}
