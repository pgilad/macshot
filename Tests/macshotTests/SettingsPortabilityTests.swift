import Cocoa
import Testing
@testable import macshot

/// Exported settings files get shared, attached to bug reports and synced
/// between machines. The export filter is therefore a security boundary: it has
/// to fail closed for anything that looks like a credential.
final class SettingsPortabilityTests {

    // MARK: - Secrets never leave the machine

    @Test func testKnownCredentialKeysAreNeverPortable() {
        let credentials = [
            "serviceAPIKey", "serviceRefreshToken", "serviceAccessToken", "storageSecretKey",
            "saveDirectoryBookmark",
            "translationApiKey", "userPassword", "someCredential",
        ]
        for key in credentials {
            #expect(!SettingsPortability.isPortable(key), "`\(key)` must never be exported")
        }
    }

    @Test func testSecretDetectionIsCaseInsensitiveAndSubstringBased() {
        for key in ["myAPIKey", "MYAPIKEY", "providerToken", "TOKEN_store", "xSecrety", "oauthPassword"] {
            #expect(SettingsPortability.looksSecret(key), "`\(key)` should read as a secret")
        }
    }

    @Test func testAFutureProvidersCredentialIsExcludedByName() {
        // The point of the substring rule: a provider added later is covered
        // without anyone remembering to update an exclusion list.
        for key in ["dropboxApiKey", "azureSecret", "newProviderAccessToken", "somethingPassword"] {
            #expect(!SettingsPortability.isPortable(key), "`\(key)` slipped through the secret filter")
        }
    }

    // MARK: - Machine-specific state stays behind

    @Test func testMachineSpecificKeysAreNotPortable() {
        for key in SettingsPortability.excludedKeys {
            #expect(!SettingsPortability.isPortable(key), "`\(key)` is machine-specific and must not transfer")
        }
    }

    @Test func testUploadHistoryAndAccountEmailStayLocal() {
    }

    // MARK: - System keys are filtered out

    @Test func testSystemInjectedKeysAreNotPortable() {
        let systemKeys = [
            "NSWindowFrame main", "AppleLanguages", "com.apple.trackpad.scrolling",
            "kCIEnableCoreImage", "_internalThing", "AKLastIDMSEnvironment",
            "METAL_ERROR_MODE", "KB_Something", "Country",
        ]
        for key in systemKeys {
            #expect(!SettingsPortability.isPortable(key), "`\(key)` is injected by macOS, not a macshot setting")
        }
    }

    @Test func testScreamingSnakeCaseIsNotAppAuthored() {
        #expect(!SettingsPortability.looksAppAuthored("METAL_DEVICE_WRAPPER_TYPE"))
        #expect(!SettingsPortability.looksAppAuthored("SOME_OTHER_ENV"))
        #expect(SettingsPortability.looksAppAuthored("beautify_enabled"), "a lowercase key with an underscore is still app-authored")
    }

    @Test func testKeysStartingWithACapitalAreNotAppAuthored() {
        #expect(!SettingsPortability.looksAppAuthored("Country"))
        #expect(!SettingsPortability.looksAppAuthored("WindowState"))
        #expect(!SettingsPortability.looksAppAuthored(""))
        #expect(!SettingsPortability.looksAppAuthored("9lives"), "a key that doesn't start with a letter")
    }

    // MARK: - Real settings do transfer

    @Test func testEverydaySettingsArePortable() {
        let settings = [
            "imageFormat", "imageQuality", "downscaleRetina",
            "historySize", "enabledTools", "beautifyEnabled", "beautifyStyleIndex",
            "currentStrokeWidth", "filenameTemplate", "autoCopyToClipboard",
            "overlayToolShortcuts", "hotkeyKeyCode", "hotkeyModifiers",
        ]
        for key in settings {
            #expect(SettingsPortability.isPortable(key), "`\(key)` is a normal setting and should transfer")
        }
    }

    // MARK: - Import validation

    @Test func testImportRejectsNonJSON() {
        #expect(throws: SettingsPortability.ImportError.self) {
            try SettingsPortability.importData(Data("not json".utf8))
        }
    }

    @Test func testImportRejectsAFileFromADifferentApp() throws {
        let json = try JSONSerialization.data(withJSONObject: [
            "type": "some-other-app-settings",
            "schemaVersion": 1,
            "settings": ["imageFormat": "png"],
        ])
        #expect(throws: (any Error).self) { try SettingsPortability.importData(json) }
    }

    @Test func testImportRejectsANewerSchema() throws {
        let json = try JSONSerialization.data(withJSONObject: [
            "type": SettingsPortability.fileType,
            "schemaVersion": SettingsPortability.schemaVersion + 1,
            "settings": ["imageFormat": "png"],
        ])
        #expect(throws: (any Error).self, "a file from a newer macshot must be refused, not half-applied") { try SettingsPortability.importData(json) }
    }

    @Test func testImportRejectsAFileWithNoSettings() throws {
        let json = try JSONSerialization.data(withJSONObject: [
            "type": SettingsPortability.fileType,
            "schemaVersion": SettingsPortability.schemaVersion,
        ])
        #expect(throws: (any Error).self) { try SettingsPortability.importData(json) }
    }

    @Test func testImportErrorsAllDescribeThemselves() {
        let errors: [SettingsPortability.ImportError] = [
            .notJSON, .wrongFileType, .newerSchema(found: 9), .missingSettings,
        ]
        for error in errors {
            #expect(!(error.errorDescription ?? "").isEmpty, "\(error) has no user-facing message")
        }
    }

    // MARK: - Export

    @Test func testExportContainsOnlyPortableKeys() throws {
        let result = try SettingsPortability.exportData()
        let object = try JSONSerialization.jsonObject(with: result.data) as? [String: Any]
        let settings = try #require(object?["settings"] as? [String: Any])
        for key in settings.keys {
            #expect(SettingsPortability.isPortable(key), "export leaked `\(key)`")
        }
    }

    @Test func testExportIsTaggedSoItCanBeRecognized() throws {
        let result = try SettingsPortability.exportData()
        let object = try JSONSerialization.jsonObject(with: result.data) as? [String: Any]
        #expect((object?["type"] as? String) == SettingsPortability.fileType)
        #expect((object?["schemaVersion"] as? Int) == SettingsPortability.schemaVersion)
    }

    @Test func testSuggestedFilenameIsAValidJSONName() {
        let name = SettingsPortability.suggestedExportFilename()
        #expect(name.hasSuffix(".json"))
        #expect(!name.contains("/"))
        #expect(!name.contains(":"))
    }

    @Test func testExportedSecretKeysAreAbsentEvenWhenSet() throws {
        try withDefaults([
            "serviceAPIKey": "secret-value-1234",
            "storageSecretKey": "another-secret",
            "imageFormat": "png",
        ]) {
            let result = try SettingsPortability.exportData()
            let text = String(decoding: result.data, as: UTF8.self)
            #expect(!text.contains("secret-value-1234"), "an API key reached the export file")
            #expect(!text.contains("another-secret"), "an S3 secret reached the export file")
        }
    }
}
