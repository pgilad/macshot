import Cocoa
import XCTest

@MainActor
final class KeyboardMoveSelectionTests: XCTestCase {
    private func withOverlay(_ body: (MoveSelectionOverlay) -> Void) {
        withDefaults(["overlayToolShortcuts": nil]) {
            // Invalidate the shortcut cache both before use and before the
            // surrounding helper restores the previous preferences.
            ToolShortcutManager.setKey(" ", for: .moveSelection)
            defer { ToolShortcutManager.setKey(" ", for: .moveSelection) }
            let view = MoveSelectionOverlay(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            view.applySelection(NSRect(x: 100, y: 100, width: 300, height: 200))
            body(view)
        }
    }

    func testSpaceStartsMoveSelection() {
        withOverlay { view in
            view.keyDown(with: TestKeyEvent.keyDown(characters: " ", keyCode: 49))
            XCTAssertEqual(view.moveEligibility, [true])
        }
    }
}

@MainActor
private final class MoveSelectionOverlay: OverlayView {
    var moveEligibility: [Bool] = []

    override func startKeyboardMoveSelection() -> Bool {
        // Exercise real key routing and the real eligibility predicate without
        // constructing a window or moving the user's pointer in headless tests.
        let allowed = canStartKeyboardMoveSelection()
        moveEligibility.append(allowed)
        return allowed
    }
}
