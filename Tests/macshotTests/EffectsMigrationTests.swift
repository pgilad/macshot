import Cocoa
import Testing
@testable import macshot

/// Users who tried the Vivid effect in an old build kept getting
/// over-saturated screenshots forever, because the preset stayed persisted
/// across updates and nothing in the UI made that obvious (issue #345).
final class EffectsMigrationTests {

    private var defaults: UserDefaults!
    private var suiteName: String!

    init() {
        suiteName = "macshot-effects-migration-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    isolated deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func writeLegacyVividState() {
        defaults.set(ImageEffectPreset.vivid.rawValue, forKey: "effectsPreset")
        defaults.set(0.0, forKey: "effectsBrightness")
        defaults.set(EffectsMigration.legacyVividContrast, forKey: "effectsContrast")
        defaults.set(EffectsMigration.legacyVividSaturation, forKey: "effectsSaturation")
        defaults.set(0.0, forKey: "effectsSharpness")
    }

    private var storedPreset: Int? {
        defaults.object(forKey: "effectsPreset") as? Int
    }

    @Test func testLegacyVividStateIsCleared() {
        writeLegacyVividState()
        #expect(EffectsMigration.runIfNeeded(defaults: defaults))
        #expect(storedPreset == nil, "the stuck Vivid preset must be cleared")
        #expect(defaults.object(forKey: "effectsContrast") == nil)
        #expect(defaults.object(forKey: "effectsSaturation") == nil)
    }

    @Test func testVividChosenInACurrentBuildIsLeftAlone() {
        // Today's build writes neutral sliders alongside the preset, so this
        // is a deliberate choice, not legacy leakage.
        defaults.set(ImageEffectPreset.vivid.rawValue, forKey: "effectsPreset")
        defaults.set(1.0, forKey: "effectsContrast")
        defaults.set(1.0, forKey: "effectsSaturation")

        #expect(!EffectsMigration.runIfNeeded(defaults: defaults))
        #expect(storedPreset == ImageEffectPreset.vivid.rawValue, "a user who picked Vivid on purpose keeps it")
    }

    @Test func testOtherPresetsAreNeverTouched() {
        for preset in ImageEffectPreset.allCases where preset != .vivid {
            defaults.removeObject(forKey: EffectsMigration.migrationKey)
            defaults.set(preset.rawValue, forKey: "effectsPreset")
            defaults.set(EffectsMigration.legacyVividContrast, forKey: "effectsContrast")
            defaults.set(EffectsMigration.legacyVividSaturation, forKey: "effectsSaturation")

            #expect(!EffectsMigration.runIfNeeded(defaults: defaults), "\(preset)")
            #expect(storedPreset == preset.rawValue, "\(preset) was cleared by mistake")
        }
    }

    @Test func testAnUntouchedInstallIsUnaffected() {
        #expect(!EffectsMigration.runIfNeeded(defaults: defaults))
        #expect(storedPreset == nil)
    }

    @Test func testTheMigrationRunsOnlyOnce() {
        writeLegacyVividState()
        #expect(EffectsMigration.runIfNeeded(defaults: defaults))

        // The user re-selects Vivid afterwards; it must survive the next launch.
        defaults.set(ImageEffectPreset.vivid.rawValue, forKey: "effectsPreset")
        defaults.set(EffectsMigration.legacyVividContrast, forKey: "effectsContrast")
        defaults.set(EffectsMigration.legacyVividSaturation, forKey: "effectsSaturation")

        #expect(!EffectsMigration.runIfNeeded(defaults: defaults))
        #expect(storedPreset == ImageEffectPreset.vivid.rawValue)
    }

    @Test func testTheMigrationIsRecordedEvenWhenThereIsNothingToClear() {
        #expect(!EffectsMigration.runIfNeeded(defaults: defaults))
        #expect(defaults.bool(forKey: EffectsMigration.migrationKey), "an install with no legacy state shouldn't re-check on every launch")
    }

    @Test func testDetectionIgnoresAPartiallyWrittenState() {
        defaults.set(ImageEffectPreset.vivid.rawValue, forKey: "effectsPreset")
        defaults.set(EffectsMigration.legacyVividContrast, forKey: "effectsContrast")
        // No saturation stored at all.
        #expect(!EffectsMigration.hasLegacyVividState(defaults: defaults))
    }

    // MARK: - The effect itself

    @Test func testAnIdentityConfigLeavesTheImageAlone() {
        let image = ImageProbe.quadrantImage(width: 20, height: 20)
        let result = ImageEffects.apply(to: image, config: ImageEffectsConfig())
        #expect(result === image, "no effect should mean no re-encode")
    }

    @Test func testVividChangesMidGreyTheWayUsersNoticed() throws {
        // The complaint in #345 is crushed greys, so measure one.
        let grey = ImageProbe.solidImage(width: 20, height: 20,
                                         color: CGColor(srgbRed: 0.45, green: 0.45, blue: 0.45, alpha: 1))
        var config = ImageEffectsConfig()
        config.preset = .vivid

        let before = try #require(ImageProbe.pixelColor(grey, x: 10, y: 10))
        let after = try #require(ImageProbe.pixelColor(ImageEffects.apply(to: grey, config: config), x: 10, y: 10))

        #expect(after.redComponent < (before.redComponent - 0.02), "Vivid's contrast boost should darken a mid grey — it was applied to every capture")
    }

    @Test func testVividIgnoresLeftoverSliderValues() {
        // Vivid applies its own boost; stale slider values must not stack on top.
        let image = ImageProbe.solidImage(width: 20, height: 20,
                                          color: CGColor(srgbRed: 0.45, green: 0.5, blue: 0.55, alpha: 1))
        var plain = ImageEffectsConfig()
        plain.preset = .vivid
        var withStaleSliders = plain
        withStaleSliders.contrast = Float(EffectsMigration.legacyVividContrast)
        withStaleSliders.saturation = Float(EffectsMigration.legacyVividSaturation)

        #expect(FieldDescriber.describe(ImageEffects.apply(to: image, config: plain)) == FieldDescriber.describe(ImageEffects.apply(to: image, config: withStaleSliders)))
    }
}
