import AppKit
import Testing
@testable import FreeMouse

struct ScrollShortcutTests {
    @Test func typingInAnotherApplicationCannotTriggerLocalCaptureOutput() {
        #expect(!ScrollShortcutPolicy.handlesLocalOutput(modifiers: [], panelHasFocus: false))
        #expect(!ScrollShortcutPolicy.handlesLocalOutput(modifiers: [.shift], panelHasFocus: true))
        #expect(ScrollShortcutPolicy.handlesLocalOutput(modifiers: [], panelHasFocus: true))
        #expect(!ScrollShortcutPolicy.handlesLocalOutput(modifiers: [.command, .option, .control], panelHasFocus: true))
    }
}
