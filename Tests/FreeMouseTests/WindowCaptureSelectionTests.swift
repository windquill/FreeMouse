import AppKit
import Testing
@testable import FreeMouse

@MainActor
struct WindowCaptureSelectionTests {
    @Test func identicalWindowTitlesRemainSeparateCaptureTargets() throws {
        let picker = WindowCapturePicker.make(choices: [
            .init(windowID: 101, title: "Editor — Untitled"),
            .init(windowID: 202, title: "Editor — Untitled"),
            .init(windowID: 303, title: "Fixture — Test page")
        ])
        #expect(picker.numberOfItems == 3)
        picker.selectItem(at: 0)
        #expect(WindowCapturePicker.selectedWindowID(in: picker) == 101)
        picker.selectItem(at: 1)
        #expect(WindowCapturePicker.selectedWindowID(in: picker) == 202)
        picker.selectItem(at: 2)
        #expect(WindowCapturePicker.selectedWindowID(in: picker) == 303)
    }

    @Test func selectedIdentitySurvivesMenuReordering() throws {
        let picker = WindowCapturePicker.make(choices: [
            .init(windowID: 400, title: "A"), .init(windowID: 500, title: "B")
        ])
        let menu = try #require(picker.menu)
        let item = try #require(menu.item(at: 1))
        menu.removeItem(item)
        menu.insertItem(item, at: 0)
        picker.selectItem(at: 0)
        #expect(WindowCapturePicker.selectedWindowID(in: picker) == 500)
    }

    @Test func emptyOrInvalidSelectionDoesNotChooseAnotherWindow() {
        let picker = WindowCapturePicker.make(choices: [])
        #expect(WindowCapturePicker.selectedWindowID(in: picker) == nil)
        picker.menu?.addItem(NSMenuItem(title: "invalid", action: nil, keyEquivalent: ""))
        picker.selectItem(at: 0)
        #expect(WindowCapturePicker.selectedWindowID(in: picker) == nil)
    }
}
