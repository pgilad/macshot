import Cocoa
import Testing
@testable import macshot

@MainActor
final class DeferredRestorationTests {
    @Test func testNewCaptureInheritsHiddenItemsAndRejectsTheOldTimer() throws {
        var state = DeferredRestoration<Int>()
        state.begin(adding: [1, 2])
        let oldTimer = try #require(scheduled(&state))
        state.begin(adding: [3])
        #expect(state.take(ifCurrent: oldTimer) == nil)
        #expect(state.pending == [1, 2, 3])
        let current = try #require(scheduled(&state))
        #expect(state.take(ifCurrent: current) == [1, 2, 3])
        #expect(state.pending.isEmpty)
    }

    @Test func testActivationAndFallbackCannotRestoreTwiceOrConsumeTheNextCapture() throws {
        var state = DeferredRestoration<Int>()
        state.begin(adding: [1])
        let token = try #require(scheduled(&state))
        #expect(state.take(ifCurrent: token) == [1])
        state.begin(adding: [2])
        #expect(state.take(ifCurrent: token) == nil)
        #expect(state.pending == [2])
    }

    @Test func testClosedItemsAreNotRestoredAndExistingItemsAreNotDuplicated() throws {
        var state = DeferredRestoration<Int>()
        state.begin(adding: [1, 2])
        state.begin(adding: [2, 3])
        let token = try #require(scheduled(&state))
        state.remove(2)
        #expect(state.take(ifCurrent: token) == [1, 3])
    }

    @Test func testReschedulingAndImmediateRestoreInvalidateEarlierCallbacks() throws {
        var state = DeferredRestoration<Int>()
        state.begin(adding: [1])
        let first = try #require(scheduled(&state))
        let second = try #require(scheduled(&state))
        #expect(state.take(ifCurrent: first) == nil)
        #expect(state.takeNow() == [1])
        #expect(state.take(ifCurrent: second) == nil)
        #expect(state.schedule() == nil)
    }
}

/// `#require` cannot call a mutating method, so tests schedule through this.
private func scheduled<Item>(_ state: inout DeferredRestoration<Item>) -> UInt64? {
    state.schedule()
}
