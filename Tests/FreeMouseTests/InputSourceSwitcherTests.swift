import Foundation
import Testing
@testable import FreeMouse

struct InputSourceSwitcherTests {
    private let rule = AppInputRule(bundleIdentifier: "test.editor", name: "Editor", sourceID: "source.abc")

    @Test func decisionRequiresEnabledMatchingAvailableDifferentSource() {
        var settings = AppInputSettings(enabled: true, rules: [rule])
        #expect(settings.target(for: "test.editor", current: "source.other", available: ["source.abc"], ownBundleID: "test.omnidesk") == "source.abc")
        #expect(settings.target(for: "test.editor", current: "source.abc", available: ["source.abc"], ownBundleID: nil) == nil)
        #expect(settings.target(for: "test.unknown", current: nil, available: ["source.abc"], ownBundleID: nil) == nil)
        #expect(settings.target(for: "test.editor", current: nil, available: [], ownBundleID: nil) == nil)
        #expect(settings.target(for: "test.editor", current: nil, available: ["source.abc"], ownBundleID: "test.editor") == nil)
        settings.enabled = false
        #expect(settings.target(for: "test.editor", current: nil, available: ["source.abc"], ownBundleID: nil) == nil)
    }

    @Test func settingsRoundTrip() throws {
        let settings = AppInputSettings(enabled: true, rules: [rule])
        #expect(AppInputSettings.decode(try JSONEncoder().encode(settings)) == settings)
    }

    @Test func invalidDataDefaultsToPaused() {
        #expect(AppInputSettings.decode(nil) == AppInputSettings())
        #expect(AppInputSettings.decode(Data("invalid".utf8)) == AppInputSettings())
        #expect(AppInputSettings.decode(Data("{}".utf8)) == AppInputSettings())
    }

    @Test func validationDropsEmptyAndDuplicateRules() throws {
        let data = try JSONEncoder().encode(AppInputSettings(enabled: true, rules: [
            rule, rule,
            AppInputRule(bundleIdentifier: " ", name: "Bad", sourceID: "source.abc"),
            AppInputRule(bundleIdentifier: "test.bad", name: "Bad", sourceID: "")
        ]))
        #expect(AppInputSettings.decode(data).rules == [rule])
    }
}
