import Cocoa
import Testing
@testable import macshot

/// Image effects are applied to the capture on its way out, so a preset wired
/// to the wrong filter (or one that silently does nothing) ships in the file
/// the user shares.
@MainActor
final class ImageEffectsTests {

    /// A photo-like image: flat colour can't show a tonal effect.
    private func sample() -> NSImage {
        ImageProbe.makeImage(width: 40, height: 40) { context in
            for x in 0..<40 {
                for y in stride(from: 0, to: 40, by: 2) {
                    context.setFillColor(CGColor(srgbRed: CGFloat(x) / 40,
                                                 green: CGFloat(y) / 40,
                                                 blue: 0.5, alpha: 1))
                    context.fill(CGRect(x: x, y: y, width: 1, height: 2))
                }
            }
        }
    }

    private func describe(_ image: NSImage) -> String { FieldDescriber.describe(image) }

    private func config(_ preset: ImageEffectPreset) -> ImageEffectsConfig {
        var config = ImageEffectsConfig()
        config.preset = preset
        return config
    }

    @Test func testTheDefaultConfigIsIdentity() {
        #expect(ImageEffectsConfig().isIdentity)
    }

    @Test func testAnyAdjustmentBreaksIdentity() {
        for change: (inout ImageEffectsConfig) -> Void in [
            { $0.preset = .noir }, { $0.brightness = 0.1 },
            { $0.contrast = 1.2 }, { $0.saturation = 0.5 }, { $0.sharpness = 0.4 },
        ] {
            var config = ImageEffectsConfig()
            change(&config)
            #expect(!config.isIdentity)
        }
    }

    @Test func testAnIdentityConfigReturnsTheSameImage() {
        let image = sample()
        #expect(ImageEffects.apply(to: image, config: ImageEffectsConfig()) === image)
    }

    @Test func testEveryPresetChangesTheImage() {
        let image = sample()
        let original = describe(image)
        for preset in ImageEffectPreset.allCases where preset != .none {
            let result = describe(ImageEffects.apply(to: image, config: config(preset)))
            #expect(result != original, "\(preset.displayName) left the image untouched")
        }
    }

    @Test func testEveryPresetProducesADistinctLook() {
        // Two presets rendering identically means one is wired to the wrong filter.
        var seen: [String: String] = [:]
        for preset in ImageEffectPreset.allCases where preset != .none {
            let rendered = describe(ImageEffects.apply(to: sample(), config: config(preset)))
            if let other = seen[rendered] {
                Issue.record("\(preset.displayName) renders identically to \(other)")
            }
            seen[rendered] = preset.displayName
        }
    }

    @Test func testMonochromePresetsRemoveColour() throws {
        for preset in [ImageEffectPreset.noir, .mono] {
            let result = ImageEffects.apply(to: sample(), config: config(preset))
            let pixel = try #require(ImageProbe.pixelColor(result, x: 30, y: 10))
            #expect(abs(pixel.redComponent - (pixel.greenComponent)) <= 0.03, "\(preset.displayName)")
            #expect(abs(pixel.greenComponent - (pixel.blueComponent)) <= 0.03, "\(preset.displayName)")
        }
    }

    @Test func testBrightnessMovesTheImageInTheRightDirection() throws {
        var brighter = ImageEffectsConfig()
        brighter.brightness = 0.3
        var darker = ImageEffectsConfig()
        darker.brightness = -0.3

        let source = sample()
        let base = try #require(ImageProbe.pixelColor(source, x: 20, y: 20)).redComponent
        let up = try #require(ImageProbe.pixelColor(ImageEffects.apply(to: source, config: brighter), x: 20, y: 20))
        let down = try #require(ImageProbe.pixelColor(ImageEffects.apply(to: source, config: darker), x: 20, y: 20))

        #expect(up.redComponent > base)
        #expect(down.redComponent < base)
    }

    @Test func testSaturationCanRemoveColourEntirely() throws {
        var grey = ImageEffectsConfig()
        grey.saturation = 0
        let result = ImageEffects.apply(to: sample(), config: grey)
        let pixel = try #require(ImageProbe.pixelColor(result, x: 30, y: 10))
        #expect(abs(pixel.redComponent - (pixel.blueComponent)) <= 0.03)
    }

    @Test func testEffectsKeepTheImageSize() {
        for preset in ImageEffectPreset.allCases {
            let result = ImageEffects.apply(to: sample(), config: config(preset))
            #expect(result.size == NSSize(width: 40, height: 40), "\(preset.displayName)")
        }
    }

    @Test func testSharpnessIsApplied() {
        var sharp = ImageEffectsConfig()
        sharp.sharpness = 1.5
        #expect(describe(ImageEffects.apply(to: sample(), config: sharp)) != describe(sample()))
    }

    @Test func testEveryPresetHasADisplayName() {
        for preset in ImageEffectPreset.allCases {
            #expect(!preset.displayName.isEmpty)
        }
    }

    @Test func testADegenerateImageDoesNotCrashTheFilterChain() {
        var config = ImageEffectsConfig()
        config.preset = .vivid
        config.sharpness = 2
        _ = ImageEffects.apply(to: ImageProbe.solidImage(width: 1, height: 1), config: config)
        _ = ImageEffects.apply(to: NSImage(size: .zero), config: config)
    }
}
