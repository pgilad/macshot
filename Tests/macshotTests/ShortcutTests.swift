import Carbon
import Cocoa
import Testing
@testable import macshot

/// Shortcut matching decides whether a keypress edits the capture or does
/// nothing. These tests drive the matcher with synthesized events, which is the
/// deterministic half — the ASCII fallback path reads the machine's live
/// keyboard layout and is exercised separately below.
final class KeyboardShortcutMatcherTests {

    @Test func testMatchesTheSameCharacterAndModifiers() {
        let event = TestKeyEvent.keyDown(characters: "z", keyCode: TestKeyEvent.Code.z, modifiers: [.command])
        #expect(KeyboardShortcutMatcher.matches(event, character: "z", modifiers: [.command]))
    }

    @Test func testCharacterComparisonIgnoresCase() {
        let event = TestKeyEvent.keyDown(characters: "Z", keyCode: TestKeyEvent.Code.z, modifiers: [.command, .shift])
        #expect(KeyboardShortcutMatcher.matches(event, character: "z", modifiers: [.command, .shift]))
        #expect(KeyboardShortcutMatcher.matches(event, character: "Z", modifiers: [.command, .shift]))
    }

    @Test func testModifiersMustMatchExactly() {
        let event = TestKeyEvent.keyDown(characters: "z", keyCode: TestKeyEvent.Code.z, modifiers: [.command, .shift])
        #expect(!KeyboardShortcutMatcher.matches(event, character: "z", modifiers: [.command]), "⌘⇧Z must not trigger a plain ⌘Z binding — that's how redo would fire undo")
        #expect(KeyboardShortcutMatcher.matches(event, character: "z", modifiers: [.command, .shift]))
    }

    @Test func testIrrelevantModifiersAreIgnored() {
        let event = TestKeyEvent.keyDown(characters: "z", keyCode: TestKeyEvent.Code.z,
                                         modifiers: [.command, .capsLock, .function, .numericPad])
        #expect(KeyboardShortcutMatcher.matches(event, character: "z", modifiers: [.command]), "caps lock shouldn't break a shortcut")
    }

    @Test func testModifierExtractionKeepsOnlyTheFourThatMatter() {
        let event = TestKeyEvent.keyDown(characters: "a", keyCode: TestKeyEvent.Code.a,
                                         modifiers: [.command, .option, .capsLock, .help])
        #expect(KeyboardShortcutMatcher.modifiers(in: event) == [.command, .option])
    }

    @Test func testADifferentCharacterDoesNotMatch() {
        let event = TestKeyEvent.keyDown(characters: "y", keyCode: TestKeyEvent.Code.y, modifiers: [.command])
        #expect(!KeyboardShortcutMatcher.matches(event, character: "z", modifiers: [.command]))
    }

    @Test func testSemanticCharacterFollowsTheLayoutsCharacterNotTheKeyCode() {
        // A QWERTZ keyboard reports "y" from the key that is Z on QWERTY. The
        // matcher must follow the printed character, so ⌘Z stays ⌘Z.
        let qwertz = TestKeyEvent.keyDown(characters: "y", keyCode: TestKeyEvent.Code.z, modifiers: [.command])
        #expect(KeyboardShortcutMatcher.semanticCharacter(for: qwertz) == "y")
        #expect(KeyboardShortcutMatcher.matches(qwertz, character: "y", modifiers: [.command]))
    }

    @Test func testToolCharactersIncludeTheTypedCharacter() {
        let event = TestKeyEvent.keyDown(characters: "r", keyCode: 15)
        #expect(KeyboardShortcutMatcher.toolCharacters(for: event).contains("r"))
    }

    @Test func testToolCharactersAreLowercased() {
        let event = TestKeyEvent.keyDown(characters: "R", keyCode: 15, modifiers: [.shift])
        #expect(KeyboardShortcutMatcher.toolCharacters(for: event).contains("r"))
    }

    @Test func testNonLatinInputStillOffersAnASCIIFallback() {
        // Cyrillic "я" — the app's Latin defaults have to stay reachable, so the
        // matcher offers the ASCII-capable layout's character as well.
        let event = TestKeyEvent.keyDown(characters: "я", keyCode: TestKeyEvent.Code.z)
        let candidates = KeyboardShortcutMatcher.toolCharacters(for: event)
        #expect(candidates.contains("я"), "the typed character is always a candidate")
        #expect(candidates.count > 1, "a non-Latin character needs an ASCII fallback too")
        #expect(candidates.contains { $0.unicodeScalars.first?.isASCII == true })
    }

    @Test func testControlCharactersAreNotShortcuts() {
        for character in ["\n", "\r", "\t", "\u{1B}", "\0"] {
            let event = TestKeyEvent.keyDown(characters: character, keyCode: TestKeyEvent.Code.escape)
            #expect(!KeyboardShortcutMatcher.matches(event, character: character, modifiers: []), "\(character.debugDescription) must not resolve as a character shortcut")
        }
    }

    @Test func testMultiCharacterInputIsNotAShortcut() {
        let event = TestKeyEvent.keyDown(characters: "ab", keyCode: TestKeyEvent.Code.a)
        #expect(!KeyboardShortcutMatcher.matches(event, character: "ab", modifiers: []))
    }
}

/// Undo/redo chords are user-configurable, and a mis-resolved chord either does
/// nothing or does the opposite of what the user meant.
final class EditorCommandShortcutTests {

    private let undoKey = "editorCommandShortcuts.undo"
    private let redoKey = "editorCommandShortcuts.redo"

    private func withCleanShortcuts(_ body: () throws -> Void) rethrows {
        try withDefaults([undoKey: nil, redoKey: nil], body)
    }

    // MARK: - Defaults

    @Test func testDefaultUndoAndRedoChords() {
        withCleanShortcuts {
            #expect(EditorCommandShortcutManager.shortcuts(for: .undo) == [.init(character: "z", modifiers: [.command])])
            #expect(EditorCommandShortcutManager.shortcuts(for: .redo) == [.init(character: "z", modifiers: [.command, .shift]),
                            .init(character: "y", modifiers: [.command])])
        }
    }

    @Test func testDefaultChordsResolveToTheirActions() {
        withCleanShortcuts {
            let undo = TestKeyEvent.keyDown(characters: "z", keyCode: TestKeyEvent.Code.z, modifiers: [.command])
            let redoShift = TestKeyEvent.keyDown(characters: "z", keyCode: TestKeyEvent.Code.z, modifiers: [.command, .shift])
            let redoY = TestKeyEvent.keyDown(characters: "y", keyCode: TestKeyEvent.Code.y, modifiers: [.command])

            #expect(EditorCommandShortcutManager.action(for: undo) == .undo)
            #expect(EditorCommandShortcutManager.action(for: redoShift) == .redo)
            #expect(EditorCommandShortcutManager.action(for: redoY) == .redo)
        }
    }

    @Test func testAnUnboundChordResolvesToNothing() {
        withCleanShortcuts {
            let event = TestKeyEvent.keyDown(characters: "q", keyCode: 12, modifiers: [.command, .option])
            #expect(EditorCommandShortcutManager.action(for: event) == nil)
        }
    }

    // MARK: - Shortcut normalization

    @Test func testShortcutsNormalizeCaseAndIrrelevantModifiers() {
        let upper = EditorCommandShortcutManager.Shortcut(character: "Z", modifiers: [.command, .capsLock])
        let lower = EditorCommandShortcutManager.Shortcut(character: "z", modifiers: [.command])
        #expect(upper == lower, "the same chord typed with caps lock on must compare equal")
    }

    @Test func testShortcutRoundTripsThroughItsStoredForm() throws {
        let shortcut = EditorCommandShortcutManager.Shortcut(character: "k", modifiers: [.command, .option])
        let decoded = try JSONDecoder().decode(
            EditorCommandShortcutManager.Shortcut.self,
            from: try JSONEncoder().encode(shortcut))
        #expect(decoded == shortcut)
        #expect(decoded.modifiers == [.command, .option])
    }

    // MARK: - Rebinding

    @Test func testRebindingTakesTheChordFromTheOtherAction() {
        withCleanShortcuts {
            // Bind ⌘Z (undo's default) to redo.
            EditorCommandShortcutManager.setShortcut(.init(character: "z", modifiers: [.command]), for: .redo)

            let event = TestKeyEvent.keyDown(characters: "z", keyCode: TestKeyEvent.Code.z, modifiers: [.command])
            #expect(EditorCommandShortcutManager.action(for: event) == .redo, "a chord can only mean one thing")
            #expect(!(EditorCommandShortcutManager.shortcuts(for: .undo)
                .contains(.init(character: "z", modifiers: [.command]))), "undo must lose the chord it no longer owns")
        }
    }

    @Test func testRebindingReplacesRatherThanAppends() {
        withCleanShortcuts {
            EditorCommandShortcutManager.setShortcut(.init(character: "u", modifiers: [.command]), for: .undo)
            #expect(EditorCommandShortcutManager.shortcuts(for: .undo).count == 1)
            #expect(EditorCommandShortcutManager.shortcuts(for: .undo).first?.character == "u")
        }
    }

    @Test func testDisableRemovesTheBindingWithoutRestoringTheDefault() {
        withCleanShortcuts {
            EditorCommandShortcutManager.disable(.undo)
            #expect(EditorCommandShortcutManager.shortcuts(for: .undo).isEmpty, "disabled must stay disabled, not silently fall back to ⌘Z")

            let event = TestKeyEvent.keyDown(characters: "z", keyCode: TestKeyEvent.Code.z, modifiers: [.command])
            #expect(EditorCommandShortcutManager.action(for: event) == nil)
        }
    }

    @Test func testResetBringsBackTheDefault() {
        withCleanShortcuts {
            EditorCommandShortcutManager.disable(.undo)
            EditorCommandShortcutManager.reset(.undo)
            #expect(EditorCommandShortcutManager.shortcuts(for: .undo) == [.init(character: "z", modifiers: [.command])])
        }
    }

    @Test func testCorruptStoredDataFallsBackToDefaults() {
        withDefaults([undoKey: Data("not json".utf8)]) {
            #expect(EditorCommandShortcutManager.shortcuts(for: .undo) == [.init(character: "z", modifiers: [.command])], "a damaged preference must not leave the editor without undo")
        }
    }

    @Test func testDisplayStringsAreHumanReadable() {
        withCleanShortcuts {
            let undo = EditorCommandShortcutManager.displayString(for: .undo)
            #expect(undo.contains("\u{2318}"), "expected ⌘ in \(undo)")
            #expect(undo.uppercased().contains("Z"))
        }
    }

    @Test func testMenuItemGetsTheConfiguredChord() {
        withCleanShortcuts {
            let item = NSMenuItem()
            EditorCommandShortcutManager.applyPrimaryMenuShortcut(for: .undo, to: item)
            #expect(item.keyEquivalent.lowercased() == "z")
            #expect(item.keyEquivalentModifierMask.contains(.command))
        }
    }
}

/// Single-key tool shortcuts in the overlay.
final class ToolShortcutTests {

    private let toolsKey = "overlayToolShortcuts"

    @Test func testDefaultsAreTheDocumentedLetters() {
        withDefaults([toolsKey: nil]) {
            let expected: [ToolShortcutManager.Action: String] = [
                .pencil: "p", .arrow: "a", .line: "l", .rectangle: "r", .ellipse: "o",
                .marker: "m", .text: "t", .number: "n", .censor: "b", .highlight: "h",
                .colorSampler: "i", .stamp: "g", .adjustSelection: "s", .moveSelection: " ",
                .openInEditor: "e", .pin: "f",
            ]
            for (action, key) in expected {
                #expect(ToolShortcutManager.key(for: action) == key, "default for \(action.rawValue)")
            }
        }
    }

    @Test func testEveryDefaultIsEitherUniqueOrDeliberatelyUnbound() {
        withDefaults([toolsKey: nil]) {
            var seen: [String: String] = [:]
            for action in ToolShortcutManager.Action.allCases {
                let key = ToolShortcutManager.key(for: action)
                guard !key.isEmpty else { continue }  // unbound by default
                if let existing = seen[key] {
                    Issue.record("default key `\(key)` is bound to both \(existing) and \(action.rawValue) — one of them would be unreachable")
                }
                seen[key] = action.rawValue
            }
        }
    }

    @Test func testSettingAKeyChangesTheLookup() {
        withDefaults([toolsKey: nil]) {
            let original = ToolShortcutManager.key(for: .pencil)
            defer { ToolShortcutManager.setKey(original, for: .pencil) }

            ToolShortcutManager.setKey("j", for: .pencil)
            #expect(ToolShortcutManager.key(for: .pencil) == "j")
            // ToolbarButtonAction isn't Equatable, so compare the tool it carries.
            guard case .tool(let tool)? = ToolShortcutManager.lookupAction(for: "j") else {
                Issue.record("`j` no longer selects a tool"); return
            }
            #expect(tool == .pencil)
        }
    }

    @Test func testAnEmptyKeyDisablesTheShortcut() {
        withDefaults([toolsKey: nil]) {
            let original = ToolShortcutManager.key(for: .rectangle)
            defer { ToolShortcutManager.setKey(original, for: .rectangle) }

            ToolShortcutManager.setKey("", for: .rectangle)
            #expect(ToolShortcutManager.key(for: .rectangle) == "")
            #expect(ToolShortcutManager.lookupAction(for: "") == nil)
            #expect(ToolShortcutManager.displayString(for: .rectangle) == "None")
        }
    }

    @Test func testDisplayStringsNameTheSpaceKey() {
        withDefaults([toolsKey: nil]) {
            #expect(ToolShortcutManager.displayString(for: .moveSelection) == "Space")
            #expect(ToolShortcutManager.displayString(for: .pencil) == "P")
        }
    }

    @Test func testUnboundCharactersResolveToNothing() {
        withDefaults([toolsKey: nil]) {
            ToolShortcutManager.setKey(ToolShortcutManager.key(for: .pencil), for: .pencil)  // force a cache rebuild
            #expect(ToolShortcutManager.lookupAction(for: "~") == nil)
        }
    }

    @Test func testEveryActionHasALabel() {
        for action in ToolShortcutManager.Action.allCases {
            #expect(!action.label.isEmpty, "\(action.rawValue) has no label for the settings list")
        }
    }
}

/// Global hotkeys stay physical key-code bindings; only their display strings
/// are translated. These cover the parts that don't touch Carbon registration.
final class HotkeyManagerTests {

    @Test func testEverySlotHasDistinctDefaultsKeys() {
        var seen = Set<String>()
        for slot in HotkeyManager.HotkeySlot.allCases {
            for key in [slot.keyCodeKey, slot.modifiersKey, slot.disabledKey] {
                #expect(seen.insert(key).inserted, "`\(key)` is used by two hotkey slots, so they'd overwrite each other")
            }
        }
    }

    @Test func testSavingAndReadingAHotkeyRoundTrips() {
        let slot = HotkeyManager.HotkeySlot.captureArea
        withDefaults([slot.keyCodeKey: nil, slot.modifiersKey: nil, slot.disabledKey: nil]) {
            HotkeyManager.saveHotkey(for: slot, keyCode: 12, modifiers: UInt32(cmdKey | shiftKey))
            let read = HotkeyManager.readHotkey(for: slot)
            #expect(read.keyCode == 12)
            #expect(read.modifiers == UInt32(cmdKey | shiftKey))
        }
    }

    @Test func testAnUnsetHotkeyReportsItsDefault() {
        let slot = HotkeyManager.HotkeySlot.captureArea
        withDefaults([slot.keyCodeKey: nil, slot.modifiersKey: nil, slot.disabledKey: nil]) {
            let read = HotkeyManager.readHotkey(for: slot)
            #expect(read.keyCode == slot.defaultKeyCode)
            #expect(read.modifiers == slot.defaultModifiers)
        }
    }

    @Test func testOnlyCaptureAreaTakesAGlobalChordByDefault() {
        for slot in HotkeyManager.HotkeySlot.allCases {
            #expect((slot.defaultModifiers != 0) == (slot == .captureArea), "\(slot) default")
        }
    }

    @Test func testDisablingAHotkeyReportsNoBinding() {
        let slot = HotkeyManager.HotkeySlot.captureOCR
        withDefaults([slot.keyCodeKey: nil, slot.modifiersKey: nil, slot.disabledKey: nil]) {
            HotkeyManager.disableHotkey(for: slot)
            let read = HotkeyManager.readHotkey(for: slot)
            #expect(read.keyCode == 0)
            #expect(read.modifiers == 0)
            #expect(HotkeyManager.displayString(for: slot) == "None")
        }
    }

    @Test func testSavingAfterDisablingReEnables() {
        let slot = HotkeyManager.HotkeySlot.captureOCR
        withDefaults([slot.keyCodeKey: nil, slot.modifiersKey: nil, slot.disabledKey: nil]) {
            HotkeyManager.disableHotkey(for: slot)
            HotkeyManager.saveHotkey(for: slot, keyCode: 15, modifiers: UInt32(cmdKey))
            #expect(HotkeyManager.readHotkey(for: slot).keyCode == 15)
        }
    }

    @Test func testModifierSymbolsAreInTheOrderMacOSShowsThem() {
        let all = HotkeyManager.modifierString(from: UInt32(controlKey | optionKey | shiftKey | cmdKey))
        #expect(all == "\u{2303}\u{2325}\u{21E7}\u{2318}", "macOS renders modifiers as ⌃⌥⇧⌘")
        #expect(HotkeyManager.modifierString(from: 0) == "")
    }

    @Test func testFunctionKeysAreRecognized() {
        #expect(HotkeyManager.isFunctionKey(UInt32(kVK_F1)))
        #expect(HotkeyManager.isFunctionKey(UInt32(kVK_F20)))
        #expect(!HotkeyManager.isFunctionKey(UInt32(kVK_ANSI_A)), "a plain letter needs a modifier, so it mustn't be treated like F1")
    }

    @Test func testAGlobalChordNeedsCommandOptionOrControl() {
        let a = UInt32(kVK_ANSI_A)
        #expect(!HotkeyManager.isAllowedGlobalChord(keyCode: a, modifiers: UInt32(shiftKey)),
                "⇧A would take every capital A from all typing")
        #expect(!HotkeyManager.isAllowedGlobalChord(keyCode: a, modifiers: 0))
        #expect(HotkeyManager.isAllowedGlobalChord(keyCode: a, modifiers: UInt32(cmdKey)))
        #expect(HotkeyManager.isAllowedGlobalChord(keyCode: a, modifiers: UInt32(optionKey | shiftKey)))
        #expect(HotkeyManager.isAllowedGlobalChord(keyCode: a, modifiers: UInt32(controlKey)))
        #expect(HotkeyManager.isAllowedGlobalChord(keyCode: UInt32(kVK_F5), modifiers: 0))
        #expect(HotkeyManager.isAllowedGlobalChord(keyCode: UInt32(kVK_F5), modifiers: UInt32(shiftKey)))
    }

    @Test func testAShiftOnlyChordSavedEarlierIsReportedNotRegistered() {
        let slot = HotkeyManager.HotkeySlot.clearHistory
        let keys: [String: Any?] = [slot.keyCodeKey: kVK_ANSI_A, slot.modifiersKey: shiftKey, slot.disabledKey: nil]
        withDefaults(keys) {
            defer { HotkeyManager.shared.unregisterAll() }
            #expect(!HotkeyManager.shared.register(slot: slot) {})
            #expect(HotkeyManager.shared.failures[slot] == .needsModifier)
            let message = HotkeyManager.failureMessage(for: [slot: .needsModifier])
            // The letter depends on the keyboard layout, so only the modifier is checked.
            #expect(message.hasPrefix("\u{21E7}"))
            #expect(message.contains("for Clear History does not work: a global shortcut needs \u{2318}, \u{2325} or \u{2303}."))
        }
    }

    @Test func testSpecialKeysGetStableNames() {
        #expect(HotkeyManager.keyString(from: UInt32(kVK_Space)) == "Space")
        #expect(HotkeyManager.keyString(from: UInt32(kVK_F5)) == "F5")
    }

    @Test func testEverySlotHasALabelAndADisplayString() {
        for slot in HotkeyManager.HotkeySlot.allCases {
            #expect(!slot.label.isEmpty, "slot \(slot) has no label")
            #expect(!HotkeyManager.displayString(for: slot).isEmpty)
        }
    }

    @Test func testAFailureNamesTheChordTheSlotAndWhatToDo() {
        let area = HotkeyManager.HotkeySlot.captureArea
        let screen = HotkeyManager.HotkeySlot.captureFullScreen
        let keys: [String: Any?] = [
            area.keyCodeKey: kVK_F13, area.modifiersKey: cmdKey | shiftKey, area.disabledKey: nil,
            screen.keyCodeKey: kVK_F13, screen.modifiersKey: cmdKey | shiftKey, screen.disabledKey: nil,
        ]
        withDefaults(keys) {
            let taken = HotkeyManager.failureMessage(for: [screen: .usedBy(area)])
            #expect(taken.contains("\u{21E7}\u{2318}F13 for Capture Screen"))
            #expect(taken.contains("Capture Area already uses it"))
            #expect(taken.hasSuffix("Choose a different shortcut in Settings → Shortcuts."))

            let refused = HotkeyManager.failureMessage(for: [area: .refused(-9878)])
            #expect(refused.contains("another app uses it"))
        }
    }

    @Test func testSeveralFailuresAreListedInSlotOrder() {
        let area = HotkeyManager.HotkeySlot.captureArea
        let history = HotkeyManager.HotkeySlot.historyOverlay
        withDefaults([area.disabledKey: nil, history.disabledKey: nil]) {
            let message = HotkeyManager.failureMessage(for: [history: .refused(-9878), area: .refused(-9878)])
            let lines = message.components(separatedBy: "\n")
            #expect(lines.count == 3)
            #expect(lines[0].contains("Capture Area"))
            #expect(lines[1].contains("History"))
            #expect(lines[2] == "Choose different shortcuts in Settings → Shortcuts.")
        }
    }
}
