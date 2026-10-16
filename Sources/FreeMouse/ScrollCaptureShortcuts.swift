import AppKit
import Carbon

enum ScrollShortcutPolicy {
    static let globalOutputModifiers = UInt32(cmdKey | controlKey | optionKey)

    static func handlesLocalOutput(modifiers: NSEvent.ModifierFlags, panelHasFocus: Bool) -> Bool {
        panelHasFocus && modifiers.intersection([.command, .control, .option, .shift]).isEmpty
    }
}
