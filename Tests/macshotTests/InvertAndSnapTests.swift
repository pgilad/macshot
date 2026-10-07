import Cocoa
import Testing
@testable import macshot

/// Inverting colours with a window-snapped selection used to flip the
/// screenshot behind the overlay while leaving the captured window — the part
/// that actually gets exported — in its original colours (issue #88).
@MainActor
final class InvertAndSnapTests {

    private func makeOverlay() -> OverlayView {
        let view = OverlayView()
        view.frame = NSRect(x: 0, y: 0, width: 200, height: 160)
        view.screenshotImage = ImageProbe.solidImage(
            width: 200, height: 160, color: CGColor(srgbRed: 0.8, green: 0.2, blue: 0.1, alpha: 1))
        view.applySelection(NSRect(x: 20, y: 20, width: 100, height: 80))
        return view
    }

    private func red(_ image: NSImage?) -> CGFloat? {
        guard let image else { return nil }
        return ImageProbe.pixelColor(image, x: 5, y: 5)?.redComponent
    }

    // MARK: - The inversion itself

    @Test func testInvertedCopyReversesTheOrderOfTheChannels() throws {
        // CIColorInvert works in Core Image's linear space, so the result isn't
        // 1 - value in sRGB terms; what must hold is that a dark channel comes
        // back bright and a bright one comes back dark.
        let source = ImageProbe.solidImage(
            width: 8, height: 8, color: CGColor(srgbRed: 0.75, green: 0.25, blue: 0, alpha: 1))
        let inverted = try #require(OverlayView.invertedCopy(of: source))
        let pixel = try #require(ImageProbe.pixelColor(inverted, x: 4, y: 4))

        #expect(pixel.redComponent < 0.75, "the bright channel must darken")
        #expect(pixel.greenComponent > 0.25, "the dim channel must brighten")
        #expect(abs(pixel.blueComponent - (1.0)) <= 0.02, "black inverts to white")
        #expect(pixel.greenComponent > pixel.redComponent)
    }

    @Test func testInvertingTwiceReturnsTheOriginalColours() throws {
        let source = ImageProbe.quadrantImage(width: 16, height: 16)
        let once = try #require(OverlayView.invertedCopy(of: source))
        let twice = try #require(OverlayView.invertedCopy(of: once))

        for (x, y) in [(2, 2), (12, 2), (2, 12), (12, 12)] {
            let before = try #require(ImageProbe.pixelColor(source, x: x, y: y))
            let after = try #require(ImageProbe.pixelColor(twice, x: x, y: y))
            #expect(abs(after.redComponent - (before.redComponent)) <= 0.03, "pixel \(x),\(y)")
            #expect(abs(after.blueComponent - (before.blueComponent)) <= 0.03, "pixel \(x),\(y)")
        }
    }

    @Test func testInvertedCopyKeepsTheSize() throws {
        let source = ImageProbe.solidImage(width: 37, height: 11)
        let inverted = try #require(OverlayView.invertedCopy(of: source))
        #expect(inverted.size == source.size)
    }

    // MARK: - Invert with a snapped window

    @Test func testSnappedWindowPreviewKeepsEffectsWithAndWithoutShadows() throws {
        for shadow: CGFloat in [0, 20] {
            let overlay = makeOverlay()
            let windowImage = ImageProbe.solidImage(width: 100, height: 80,
                color: CGColor(srgbRed: 0.1, green: 0.8, blue: 0.3, alpha: 1))
            overlay.snappedWindowImage = windowImage
            overlay.selectionIsWindowSnap = true
            overlay.beautifyEnabled = true
            overlay.beautifyMode = .window
            overlay.beautifyPadding = 16
            overlay.beautifyShadowRadius = shadow
            overlay.beautifyStyleIndex = 0
            overlay.effectsPreset = .mono
            overlay.effectsBrightness = 0
            overlay.effectsContrast = 1
            overlay.effectsSaturation = 1
            overlay.effectsSharpness = 0
            let preview = ImageProbe.makeImage(width: 200, height: 160) { cg in
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)
                overlay.draw(overlay.bounds)
                NSGraphicsContext.restoreGraphicsState()
            }
            let actual = try #require(ImageProbe.pixelColor(preview, x: 70, y: 100))
            let expected = try #require(ImageProbe.pixelColor(
                ImageEffects.apply(to: windowImage, config: overlay.effectsConfig), x: 50, y: 40))
            #expect(abs(actual.redComponent - (expected.redComponent)) <= 0.03, "shadow \(shadow)")
            #expect(abs(actual.greenComponent - (expected.greenComponent)) <= 0.03, "shadow \(shadow)")
            #expect(abs(actual.blueComponent - (expected.blueComponent)) <= 0.03, "shadow \(shadow)")
        }
    }

    @Test func testInvertFlipsTheSnappedWindowCaptureToo() throws {
        let overlay = makeOverlay()
        overlay.snappedWindowImage = ImageProbe.solidImage(
            width: 100, height: 80, color: CGColor(srgbRed: 0.9, green: 0.9, blue: 0.9, alpha: 1))
        let originalSnapRed = try #require(red(overlay.snappedWindowImage))

        overlay.handleToolbarAction(.invertColors)

        let invertedSnapRed = try #require(red(overlay.snappedWindowImage))
        #expect(invertedSnapRed < (originalSnapRed - 0.3), "the window capture is what gets exported, so it has to invert as well")
    }

    @Test func testInvertStillFlipsTheScreenshot() throws {
        let overlay = makeOverlay()
        let before = try #require(red(overlay.screenshotImage))
        overlay.handleToolbarAction(.invertColors)
        let after = try #require(red(overlay.screenshotImage))
        #expect(after < (before - 0.1), "a bright red screenshot must come back darker")
    }

    @Test func testUndoRestoresBothImages() throws {
        let overlay = makeOverlay()
        overlay.snappedWindowImage = ImageProbe.solidImage(
            width: 100, height: 80, color: CGColor(srgbRed: 0.9, green: 0.9, blue: 0.9, alpha: 1))
        let screenshotBefore = try #require(red(overlay.screenshotImage))
        let snapBefore = try #require(red(overlay.snappedWindowImage))

        overlay.handleToolbarAction(.invertColors)
        overlay.undo()

        #expect(abs(try #require(red(overlay.screenshotImage)) - (screenshotBefore)) <= 0.03)
        #expect(abs(try #require(red(overlay.snappedWindowImage)) - (snapBefore)) <= 0.03, "undo has to put the window capture back too")
    }

    @Test func testRedoAppliesTheInversionAgain() throws {
        let overlay = makeOverlay()
        overlay.snappedWindowImage = ImageProbe.solidImage(
            width: 100, height: 80, color: CGColor(srgbRed: 0.9, green: 0.9, blue: 0.9, alpha: 1))
        let snapBefore = try #require(red(overlay.snappedWindowImage))

        overlay.handleToolbarAction(.invertColors)
        let afterInvert = try #require(red(overlay.snappedWindowImage))
        overlay.undo()
        overlay.redo()

        #expect(abs(try #require(red(overlay.snappedWindowImage)) - (afterInvert)) <= 0.03)
        #expect(afterInvert < (snapBefore - 0.3))
    }

    @Test func testInvertWorksWithoutASnappedWindow() throws {
        let overlay = makeOverlay()
        let before = try #require(red(overlay.screenshotImage))
        overlay.handleToolbarAction(.invertColors)
        #expect(overlay.snappedWindowImage == nil)
        #expect((try #require(red(overlay.screenshotImage))) < (before - 0.1))
    }

    @Test func testFlippingDoesNotDisturbTheSnappedWindowImage() throws {
        // Only invert touches it; a flip must leave it alone rather than
        // restoring a nil over it on undo.
        let overlay = makeOverlay()
        let snap = ImageProbe.solidImage(width: 100, height: 80)
        overlay.snappedWindowImage = snap

        overlay.flipImageHorizontally()
        #expect(overlay.snappedWindowImage === snap)
        overlay.undo()
        #expect(overlay.snappedWindowImage === snap, "undoing a flip must not clear the window capture")
    }
}

/// Element snapping may change accessibility settings only inside Chromium and
/// Electron apps, and only when the user turned it on.
final class BrowserElementSnapTests {

    private func makeBundle(frameworks: [String: [String]]) throws -> URL {
        let bundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("macshot-tests-\(UUID().uuidString).app", isDirectory: true)
        for (framework, resources) in frameworks {
            let folder = bundle.appendingPathComponent("Contents/Frameworks/\(framework)/Resources", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for resource in resources {
                try Data().write(to: folder.appendingPathComponent(resource))
            }
        }
        return bundle
    }

    @Test func testChromiumAndElectronBundlesAreRecognized() throws {
        for framework in ["Electron Framework.framework", "Google Chrome Framework.framework",
                          "Chromium Embedded Framework.framework"] {
            let bundle = try makeBundle(frameworks: [
                "Squirrel.framework": ["Info.plist"],
                framework: ["chrome_100_percent.pak"],
            ])
            defer { try? FileManager.default.removeItem(at: bundle) }
            #expect(OverlayView.isChromiumBasedApp(at: bundle), "\(framework)")
        }
    }

    @Test func testOtherBundlesAreNotChanged() throws {
        let native = try makeBundle(frameworks: ["Sparkle.framework": ["Info.plist"]])
        defer { try? FileManager.default.removeItem(at: native) }
        #expect(!OverlayView.isChromiumBasedApp(at: native))

        let empty = try makeBundle(frameworks: [:])
        defer { try? FileManager.default.removeItem(at: empty) }
        #expect(!OverlayView.isChromiumBasedApp(at: empty), "no Frameworks folder")
    }

    @Test func testItIsOffUntilTheUserTurnsItOn() {
        withDefaults([OverlayView.browserElementSnapEnabledKey: nil]) {
            #expect(!OverlayView.browserElementSnapEnabled)
        }
        withDefaults([OverlayView.browserElementSnapEnabledKey: true]) {
            #expect(OverlayView.browserElementSnapEnabled)
        }
    }
}
