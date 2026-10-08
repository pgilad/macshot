import Foundation
import Testing
@testable import macshot

/// The keys are persisted and the defaults are behavior, so both are written out here.
final class PreferencesTests {

    private static let keys = [
        Preferences.Key.playCopySound, Preferences.Key.hideMenuBarIcon, Preferences.Key.ocrAction,
        Preferences.Key.rememberLastTool, Preferences.Key.quickCaptureOpenEditor,
        Preferences.Key.closeEditorAfterCopy, Preferences.Key.urlSchemeEnabled, Preferences.Key.historySize,
        Preferences.Key.historyUnlimited, Preferences.Key.historyOrderByLastEdit,
        Preferences.Key.showFloatingThumbnail, Preferences.Key.thumbnailStacking, Preferences.Key.thumbnailCorner,
        Preferences.Key.thumbnailScale, Preferences.Key.thumbnailAutoDismiss, Preferences.Key.thumbnailLetterbox,
        Preferences.Key.captureCursor, Preferences.Key.scrollMaxHeight, Preferences.Key.imageFormat, Preferences.Key.downscaleRetina,
        Preferences.Key.clipboardIncludesImageFormat, Preferences.Key.showToolShortcutsInTooltips,
        Preferences.Key.snapGuidesEnabled, Preferences.Key.boundarySnapEnabled, Preferences.Key.doubleClickToCopy,
        Preferences.Key.hideCaptureInstructions, Preferences.Key.disableSelectionOutsideShadow,
    ]

    @Test func testTheDefaultsWhenNothingIsStored() {
        withDefaults(Dictionary(uniqueKeysWithValues: Self.keys.map { ($0, nil as Any?) })) {
            #expect(Preferences.playCopySound)
            #expect(!Preferences.hideMenuBarIcon)
            #expect(Preferences.ocrAction == 0)
            #expect(Preferences.rememberLastTool)
            #expect(!Preferences.quickCaptureOpenEditor)
            #expect(!Preferences.closeEditorAfterCopy)
            #expect(!Preferences.urlSchemeEnabled, "the URL scheme is off until the user turns it on")
            #expect(Preferences.historySize == 10)
            #expect(!Preferences.historyUnlimited)
            #expect(Preferences.historyOrderByLastEdit)
            #expect(Preferences.showFloatingThumbnail)
            #expect(Preferences.thumbnailStacking)
            #expect(Preferences.thumbnailCorner == FloatingThumbnailCorner.bottomRight.rawValue)
            #expect(Preferences.thumbnailScale == 1.0)
            #expect(Preferences.thumbnailAutoDismiss == 5)
            #expect(!Preferences.thumbnailLetterbox)
            #expect(!Preferences.captureCursor)
            #expect(Preferences.scrollMaxHeight == ScrollCaptureController.defaultMaxHeight)
            #expect(Preferences.imageFormat == nil)
            #expect(!Preferences.downscaleRetina)
            #expect(!Preferences.clipboardIncludesImageFormat)
            #expect(!Preferences.showToolShortcutsInTooltips)
            #expect(Preferences.snapGuidesEnabled)
            #expect(Preferences.boundarySnapEnabled)
            #expect(Preferences.doubleClickToCopy)
            #expect(!Preferences.hideCaptureInstructions)
            #expect(!Preferences.disableSelectionOutsideShadow)
        }
    }

    @Test func testAStoredValueWinsOverTheDefault() {
        withDefaults([Preferences.Key.playCopySound: false, Preferences.Key.historySize: 25,
                      Preferences.Key.doubleClickToCopy: "NO"]) {
            #expect(!Preferences.playCopySound)
            #expect(Preferences.historySize == 25)
            #expect(!Preferences.doubleClickToCopy, "a defaults write of \"NO\" is read as false")
        }
    }

    @Test func testTheKeyNamesAreTheStoredNames() {
        #expect(Self.keys.count == Set(Self.keys).count)
        #expect(Preferences.Key.playCopySound == "playCopySound")
        #expect(Preferences.Key.ocrAction == "ocrAction")
        #expect(Preferences.Key.thumbnailCorner == "thumbnailCorner")
        #expect(Preferences.Key.disableSelectionOutsideShadow == "disableSelectionOutsideShadow")
    }
}
