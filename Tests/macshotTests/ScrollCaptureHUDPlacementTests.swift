import Cocoa
import Testing
@testable import macshot

/// The scroll-capture HUD carries the Auto Scroll and Stop buttons. If it lands
/// under the notch or off screen, the session can't be stopped from the HUD at
/// all — which is what users reported on notched MacBooks (issue #153).
@MainActor
final class ScrollCaptureHUDPlacementTests {

    /// A 16" MacBook Pro: notch, menu bar, and a Dock at the bottom.
    private let notchedScreen = NSRect(x: 0, y: 0, width: 1728, height: 1117)
    private let notchedVisible = NSRect(x: 0, y: 76, width: 1728, height: 1004)
    private let notchInset: CGFloat = 37

    /// An external display: no notch, menu bar only.
    private let plainScreen = NSRect(x: 1728, y: 0, width: 2560, height: 1440)
    private let plainVisible = NSRect(x: 1728, y: 0, width: 2560, height: 1415)

    private let hudSize = NSSize(width: 260, height: 44)

    private func frame(selection: NSRect, notched: Bool = true) -> NSRect {
        ScrollCaptureHUDPanel.hudFrame(
            size: hudSize,
            selectionScreenRect: selection,
            screenFrame: notched ? notchedScreen : plainScreen,
            visibleFrame: notched ? notchedVisible : plainVisible,
            topInset: notched ? notchInset : 0)
    }

    private var notchBandBottom: CGFloat { notchedScreen.maxY - notchInset }

    // MARK: - Ordinary placement

    @Test func testTheHUDSitsBelowTheSelectionWhenThereIsRoom() {
        let selection = NSRect(x: 400, y: 400, width: 600, height: 300)
        let hud = frame(selection: selection)
        #expect(hud.maxY < selection.minY, "expected the HUD below the selection")
        #expect(abs(hud.midX - (selection.midX)) <= 1, "and centred on it")
    }

    @Test func testTheHUDMovesAboveWhenThereIsNoRoomBelow() {
        let selection = NSRect(x: 400, y: 90, width: 600, height: 500)
        let hud = frame(selection: selection)
        #expect(hud.minY > selection.minY, "expected the HUD above the selection")
    }

    // MARK: - The notch

    @Test func testAFullHeightSelectionKeepsTheHUDClearOfTheNotch() {
        // Scroll capture is usually a tall selection, which is exactly the case
        // that used to put the HUD under the camera housing.
        let selection = NSRect(x: 300, y: 0, width: 900, height: 1117)
        let hud = frame(selection: selection)
        #expect(hud.maxY <= notchBandBottom, "the Stop button ended up under the notch")
        #expect(hud.minY >= notchedVisible.minY, "and must not fall off the bottom either")
    }

    @Test func testAFullScreenSelectionStillLeavesAClickableHUD() {
        let hud = frame(selection: notchedScreen)
        #expect(hud.maxY <= notchBandBottom)
        #expect(notchedScreen.contains(hud), "the HUD must stay on the display")
    }

    @Test func testTheHUDIsNeverPlacedInTheNotchBandForAnySelection() {
        // Sweep selection heights and positions; none may push it into the band.
        for y in stride(from: CGFloat(0), through: 1000, by: 125) {
            for height in stride(from: CGFloat(50), through: 1100, by: 175) {
                let selection = NSRect(x: 200, y: y, width: 800, height: height)
                let hud = frame(selection: selection)
                #expect(hud.maxY <= notchBandBottom, "selection y=\(y) h=\(height) put the HUD at \(hud)")
            }
        }
    }

    // MARK: - Displays without a notch

    @Test func testOnAPlainDisplayTheHUDStaysUnderTheMenuBar() {
        let selection = NSRect(x: 2000, y: 0, width: 800, height: 1440)
        let hud = frame(selection: selection, notched: false)
        #expect(hud.maxY <= plainVisible.maxY, "the menu bar would cover it")
    }

    @Test func testTheHUDStaysOnASecondDisplay() {
        let selection = NSRect(x: 1800, y: 200, width: 600, height: 400)
        let hud = frame(selection: selection, notched: false)
        #expect(hud.minX >= plainVisible.minX, "a display with a non-zero origin must still hold the HUD")
        #expect(hud.maxX <= plainVisible.maxX)
    }

    // MARK: - Edges

    @Test func testASelectionAtTheLeftEdgeKeepsTheHUDOnScreen() {
        let hud = frame(selection: NSRect(x: 0, y: 300, width: 120, height: 200))
        #expect(hud.minX >= notchedVisible.minX)
        #expect(hud.maxX <= notchedVisible.maxX)
    }

    @Test func testASelectionAtTheRightEdgeKeepsTheHUDOnScreen() {
        let hud = frame(selection: NSRect(x: 1600, y: 300, width: 128, height: 200))
        #expect(hud.maxX <= notchedVisible.maxX)
    }

    @Test func testTheHUDKeepsItsSize() {
        let hud = frame(selection: NSRect(x: 100, y: 100, width: 400, height: 300))
        #expect(hud.size == hudSize)
    }

    @Test func testADegenerateSelectionDoesNotProduceAnOffscreenHUD() {
        for selection in [NSRect.zero,
                          NSRect(x: -500, y: -500, width: 10, height: 10),
                          NSRect(x: 5000, y: 5000, width: 10, height: 10)] {
            let hud = frame(selection: selection)
            #expect(hud.minX >= notchedVisible.minX, "selection \(selection)")
            #expect(hud.maxX <= notchedVisible.maxX, "selection \(selection)")
            #expect(hud.minY >= notchedVisible.minY, "selection \(selection)")
            #expect(hud.maxY <= notchBandBottom, "selection \(selection)")
        }
    }
}
