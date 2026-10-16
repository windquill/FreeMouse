import AppKit

struct CaptureWindowChoice {
    let windowID: CGWindowID
    let title: String
}

@MainActor
enum WindowCapturePicker {
    static func make(choices: [CaptureWindowChoice]) -> NSPopUpButton {
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 420, height: 30), pullsDown: false)
        for choice in choices {
            // addItem(withTitle:) coalesces duplicate titles. Window names are not identities.
            let item = NSMenuItem(title: choice.title, action: nil, keyEquivalent: "")
            item.tag = Int(choice.windowID)
            picker.menu?.addItem(item)
        }
        return picker
    }

    static func selectedWindowID(in picker: NSPopUpButton) -> CGWindowID? {
        guard let item = picker.selectedItem, item.tag > 0 else { return nil }
        return CGWindowID(exactly: item.tag)
    }
}
