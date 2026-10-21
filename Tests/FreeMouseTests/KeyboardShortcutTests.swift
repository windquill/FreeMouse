import AppKit
import Carbon
import Testing
@testable import FreeMouse

@MainActor struct KeyboardShortcutTests {
    private final class MemoryPreferences: ShortcutPreferences {
        var values: [String: Data] = [:]
        func data(forKey key: String) -> Data? { values[key] }
        func save(_ data: Data, forKey key: String) { values[key] = data }
    }
    private func settings() -> (ShortcutSettings, MemoryPreferences) {
        let defaults = MemoryPreferences()
        let settings = ShortcutSettings(preferences: defaults)
        settings.registry.register = { _, _ in UUID() }
        settings.registry.unregister = { _ in }
        return (settings, defaults)
    }
    @Test func newMenuActionsPersistWithoutChangingExistingBindings() throws {
        for name in ["translate", "toolbox", "openImage", "recordFull", "network", "settings", "camera", "startup", "fans", "inputSource"] {
            let action = try #require(ShortcutAction(rawValue: name))
            let (s, preferences) = settings()
            let key = KeyboardShortcut(keyCode: 17, modifiers: UInt32(cmdKey | optionKey))
            #expect(s.set(key, for: action))
            #expect(ShortcutSettings(preferences: preferences).bindings[action] == key)
            #expect(s.bindings[.region] == KeyboardShortcut.defaults[.region])
            #expect(!s.set(KeyboardShortcut.defaults[.region], for: action))
            #expect(s.set(nil, for: action))
        }
        #expect(ShortcutAction.ocr.hotKeyID == 6)
    }

    @Test func persistClearAndReload() {
        let (s, defaults) = settings()
        let key = KeyboardShortcut(keyCode: 3, modifiers: UInt32(cmdKey | shiftKey))
        #expect(s.set(key, for: .full))
        #expect(ShortcutSettings(preferences: defaults).bindings[.full] == key)
        #expect(s.set(nil, for: .region))
        #expect(ShortcutSettings(preferences: defaults).bindings[.region] == nil)
    }
    @Test func ocrBindingPersistsAndCanBeCleared() throws {
        let action = try #require(ShortcutAction(rawValue: "ocr"))
        let (s, preferences) = settings()
        #expect(s.bindings[action] == nil)
        let key = KeyboardShortcut(keyCode: 31, modifiers: UInt32(cmdKey | optionKey))
        #expect(s.set(key, for: action))
        #expect(s.registry.active[action] == key)
        #expect(ShortcutSettings(preferences: preferences).bindings[action] == key)
        #expect(!s.set(KeyboardShortcut.defaults[.region], for: action))
        #expect(s.bindings[action] == key)
        #expect(s.set(nil, for: action))
        #expect(ShortcutSettings(preferences: preferences).bindings[action] == nil)
    }

    @Test func existingPreferencesAndHotKeyIDsSurviveOCRAddition() throws {
        let preferences = MemoryPreferences()
        preferences.values["keyboardShortcuts.v1"] = try JSONEncoder().encode([
            "region": KeyboardShortcut(keyCode: 3, modifiers: UInt32(cmdKey | shiftKey))
        ])
        let s = ShortcutSettings(preferences: preferences)
        let action = try #require(ShortcutAction(rawValue: "ocr"))
        #expect(s.bindings[.region]?.keyCode == 3)
        #expect(s.bindings[action] == nil)
        #expect([ShortcutAction.region, .scroll, .full, .window, .record].map(\.hotKeyID) == [1, 2, 3, 4, 5])
        #expect(Set(ShortcutAction.allCases.map(\.hotKeyID)).count == ShortcutAction.allCases.count)
    }
    @Test func rejectDuplicatesAndPlainKeysWithoutChangingSettings() {
        let (s, _) = settings(), original = KeyboardShortcut.defaults
        #expect(!s.set(original[.region], for: .full))
        let plain = s.set(KeyboardShortcut(keyCode: 0, modifiers: 0), for: .region)
        #expect(plain == false)
        let shift = s.set(KeyboardShortcut(keyCode: 0, modifiers: UInt32(shiftKey)), for: .region)
        #expect(shift == false)
        #expect(s.bindings == original)
    }
    @Test func registrationFailureRollsBackAndDoesNotPersist() {
        let (s, defaults) = settings()
        var registered: [UUID: KeyboardShortcut] = [:]
        s.registry.register = { _, key in
            if key.keyCode == 3 { return nil }
            let token = UUID(); registered[token] = key; return token
        }
        s.registry.unregister = { registered.removeValue(forKey: $0) }
        #expect(s.registry.apply(s.bindings))
        let failed = s.set(KeyboardShortcut(keyCode: 3, modifiers: UInt32(cmdKey)), for: .full)
        #expect(failed == false)
        #expect(s.bindings == KeyboardShortcut.defaults)
        #expect(registered.count == 3)
        #expect(defaults.data(forKey: "keyboardShortcuts.v1") == nil)
    }
    @Test func recordingSuspendsThenCancelRestoresKeys() {
        let (s, _) = settings()
        var count = 0
        s.registry.register = { _, _ in count += 1; return UUID() }
        s.registry.unregister = { _ in count -= 1 }
        #expect(s.registry.apply(s.bindings)); #expect(count == 3)
        s.beginRecording(.region); #expect(count == 0)
        s.cancelRecording(); #expect(count == 3)
    }
    @Test func restoreDefaultsReplacesCustomAssignments() {
        let (s, _) = settings()
        #expect(s.set(.init(keyCode: 3, modifiers: UInt32(cmdKey)), for: .full))
        s.restoreDefaults()
        #expect(s.bindings == KeyboardShortcut.defaults)
    }
    @Test func modifierConversionAndDisplay() {
        let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command,.option,.control,.capsLock], timestamp: 0,
            windowNumber: 0, context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!
        #expect(KeyboardShortcut.from(e) == KeyboardShortcut.defaults[.region])
        #expect(KeyboardShortcut.from(e).display == "⌃⌥⌘A")
    }
    @Test func startupConflictKeepsOtherShortcutsActive() {
        let registry = ShortcutRegistry()
        var count = 0
        registry.register = { action, _ in
            guard action != .scroll else { return nil }
            count += 1; return UUID()
        }
        registry.unregister = { _ in count -= 1 }
        #expect(registry.activateAvailable(KeyboardShortcut.defaults) == [.scroll])
        #expect(count == 2)
    }

}
