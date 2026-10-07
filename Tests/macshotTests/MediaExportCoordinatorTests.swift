import Cocoa
import Testing
@testable import macshot

@MainActor
final class MediaExportCoordinatorTests {
    private final class Gate {
        private var open = false
        private var waiter: CheckedContinuation<Void, Never>?
        func wait() async {
            if open { return }
            await withCheckedContinuation { waiter = $0 }
        }
        func release() { open = true; waiter?.resume(); waiter = nil }
    }

    @Test func testIdleIncludesWorkStartedByACompletion() async {
        let coordinator = MediaExportCoordinator()
        let first = Gate(), second = Gate(), third = Gate()
        let firstFinished = TestExpectation(description: "First completion registered follow-up")
        let secondFinished = TestExpectation(description: "Second completion")
        coordinator.start(operation: {
            await first.wait()
        }, completion: { _ in
            coordinator.start(operation: { await third.wait() }, completion: { _ in })
            firstFinished.fulfill()
        })
        coordinator.start(operation: { await second.wait() }, completion: { _ in secondFinished.fulfill() })
        var idle = false
        let waiter = Task { await coordinator.waitUntilIdle(); idle = true }
        #expect(coordinator.hasActiveJobs)
        first.release()
        await fulfillment(of: [firstFinished], timeout: 5)
        #expect(coordinator.hasActiveJobs)
        #expect(!idle)
        second.release()
        await fulfillment(of: [secondFinished], timeout: 5)
        #expect(coordinator.hasActiveJobs)
        #expect(!idle)
        third.release()
        await waiter.value
        #expect(idle)
        #expect(!coordinator.hasActiveJobs)
    }

    @Test func testAFailingOperationReportsItsError() async {
        let coordinator = MediaExportCoordinator()
        var failure: Error?
        coordinator.start(operation: { throw CocoaError(.fileWriteOutOfSpace) },
                          completion: { result in
            if case .failure(let error) = result { failure = error }
        })
        await coordinator.waitUntilIdle()
        #expect((failure as? CocoaError)?.code == .fileWriteOutOfSpace)
        #expect(!coordinator.hasActiveJobs)
    }

    @Test func testQuitKeepsNormalRunLoopAndRetriesOnceAfterJobsAndTheirFollowupDrain() async {
        let exports = MediaExportCoordinator(), termination = ApplicationTerminationCoordinator()
        let first = Gate(), second = Gate()
        let followedUp = TestExpectation(description: "First save starts follow-up")
        let quitRetried = TestExpectation(description: "Quit retried after all work")
        var drainCount = 0, retryCount = 0
        exports.start(operation: { await first.wait() }, completion: { _ in
            exports.start(operation: { await second.wait() }, completion: { _ in })
            followedUp.fulfill()
        })
        for _ in 0..<3 {
            let reply = termination.request(hasActiveWork: exports.hasActiveJobs, drain: {
                drainCount += 1
                await exports.waitUntilIdle()
            }, terminate: {
                #expect(!exports.hasActiveJobs)
                retryCount += 1
                quitRetried.fulfill()
            })
            #expect(reply == .terminateCancel, "A modal termination loop stalls MainActor completion")
        }
        first.release()
        await fulfillment(of: [followedUp], timeout: 5)
        #expect(retryCount == 0)
        second.release()
        await fulfillment(of: [quitRetried], timeout: 5)
        #expect(drainCount == 1)
        #expect(retryCount == 1)
        #expect(termination.request(hasActiveWork: false, drain: { Issue.record("Already idle") },
            terminate: { Issue.record("No asynchronous retry needed") }) == .terminateNow)
    }
}
