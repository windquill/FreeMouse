import AppKit
import SwiftUI
import Carbon
import ScreenCaptureKit
import ImageIO
import UniformTypeIdentifiers

@MainActor final class MemoryPreferences: ShortcutPreferences {
    var values: [String: Data] = [:]
    func data(forKey key: String) -> Data? { values[key] }
    func save(_ data: Data, forKey key: String) { values[key] = data }
}

@main struct ShortcutValidation {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await validate(); print("RESULT_PASS shortcut recorder and Carbon registration") }
            catch { print("RESULT_FAIL \(error)"); exit(1) }
            exit(0)
        }
        app.run()
    }
    @MainActor static func validate() async throws {
        let settings = ShortcutSettings(preferences: MemoryPreferences())
        var count = 0
        settings.registry.register = { _, _ in count += 1; return UUID() }
        settings.registry.unregister = { _ in count -= 1 }
        settings.registry.activateAvailable(settings.bindings)
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 720, height: 330), styleMask: [.titled,.closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "FreeMouse Shortcut Validation"
        let host = NSHostingView(rootView: ShortcutSettingsPane(settings: settings))
        window.contentView = host
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        settings.beginRecording(.full)
        try await Task.sleep(for: .milliseconds(400))
        guard count == 0, window.firstResponder is NSView,
              String(describing: type(of: window.firstResponder!)).contains("ShortcutRecorderView") else { throw NSError(domain: "Recorder focus or suspension", code: 1) }
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command,.control,.option], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3)!
        NSApp.sendEvent(event)
        try await Task.sleep(for: .milliseconds(100))
        guard settings.bindings[.full]?.keyCode == 3, settings.recording == nil, count == 4 else { throw NSError(domain: "Recorder input or resume", code: 2) }
        settings.beginRecording(.window)
        try await Task.sleep(for: .milliseconds(200))
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        NSApp.sendEvent(escape)
        try await Task.sleep(for: .milliseconds(100))
        guard settings.recording == nil, settings.bindings[.window] == nil, count == 4 else { throw NSError(domain: "Escape cancel", code: 3) }
        print("RECORDER_INPUT_CANCEL_PASS")
        // Probe only an uncommon test shortcut, release it immediately.
        var installed = false
        for code in [UInt32(kVK_F11), UInt32(kVK_F9), UInt32(kVK_F12)] {
            var ref: EventHotKeyRef?
            if RegisterEventHotKey(code, UInt32(cmdKey | controlKey | optionKey | shiftKey), EventHotKeyID(signature: 0x46535453, id: code), GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
                UnregisterEventHotKey(ref); installed = true; break
            }
        }
        guard installed else { throw NSError(domain: "No test Carbon shortcut available", code: 4) }
        print("CARBON_REGISTER_UNREGISTER_PASS")
        if CGPreflightScreenCaptureAccess() {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            if let ownWindow = content.windows.first(where: { $0.windowID == CGWindowID(exactly: window.windowNumber) && $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier }) {
                let filter = SCContentFilter(desktopIndependentWindow: ownWindow)
                let config = SCStreamConfiguration()
                config.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
                config.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
                config.showsCursor = false
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                if let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL, UTType.png.identifier as CFString, 1, nil) {
                    CGImageDestinationAddImage(destination, image, nil)
                    guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "Preview encoding", code: 5) }
                }
            }
        }
        settings.registry.suspend()
        window.orderOut(nil)
    }
}
