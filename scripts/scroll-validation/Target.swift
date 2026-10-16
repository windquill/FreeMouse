import AppKit
import CoreGraphics
import Foundation

struct TargetCommand: Codable {
    let sequence: Int
    let offset: Double
    let caret: Bool?
    let quit: Bool
}

@MainActor final class SyntheticDocument: NSView {
    var caretY: CGFloat?
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        dirtyRect.fill()
        let first = max(0, Int(dirtyRect.minY / 24))
        let last = min(Int(bounds.height / 24), Int(dirtyRect.maxY / 24) + 1)
        for row in first...last {
            let y = CGFloat(row * 24)
            let hash = UInt64(row + 1) &* 6364136223846793005 &+ 1442695040888963407
            NSColor(calibratedRed: CGFloat((hash >> 8) & 127) / 255 + 0.25,
                    green: CGFloat((hash >> 24) & 127) / 255 + 0.25,
                    blue: CGFloat((hash >> 40) & 127) / 255 + 0.25, alpha: 1).setFill()
            NSRect(x: 0, y: y, width: 9 + CGFloat(hash % 17), height: 14).fill()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: NSColor(calibratedWhite: 0.1, alpha: 1)
            ]
            let text = String(format: "Synthetic row %04d | code %08llx | scrolling capture", row, hash & 0xffff_ffff)
            text.draw(at: NSPoint(x: 38, y: y + 2), withAttributes: attrs)
            for block in 0..<5 {
                let value = hash &* UInt64(17 + block * 101)
                NSColor(calibratedRed: CGFloat(value & 255) / 255,
                        green: CGFloat((value >> 16) & 255) / 255,
                        blue: CGFloat((value >> 32) & 255) / 255, alpha: 1).setFill()
                NSRect(x: bounds.width - 105 + CGFloat(block * 19), y: y + 1,
                       width: 8 + CGFloat(value % 9), height: 7 + CGFloat((value >> 8) % 13)).fill()
            }
        }
        if let caretY {
            NSColor.black.setFill()
            NSRect(x: 495, y: caretY, width: 1, height: 12).fill()
        }
    }
}

@MainActor final class TargetDelegate: NSObject, NSApplicationDelegate {
    let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    var window: NSWindow!
    var scroll: NSScrollView!
    var poll: Timer?
    var sequence = -1
    var publishedOffset: CGFloat = -1

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard CGPreflightScreenCaptureAccess() else {
            print("TARGET_BLOCKED_SCREEN_CAPTURE_PERMISSION")
            NSApp.terminate(nil)
            return
        }
        guard let screen = NSScreen.main else { NSApp.terminate(nil); return }
        let width = min(640.0, screen.visibleFrame.width - 100)
        let height = min(480.0, screen.visibleFrame.height - 100)
        let frame = NSRect(x: screen.visibleFrame.minX + 45,
                           y: screen.visibleFrame.maxY - height - 55,
                           width: width, height: height)
        window = NSWindow(contentRect: frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "FreeMouse Synthetic Capture Validation"
        window.level = .screenSaver
        window.isOpaque = true
        window.backgroundColor = .white
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        scroll = NSScrollView(frame: NSRect(origin: .zero, size: frame.size))
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = true
        scroll.backgroundColor = .white
        scroll.borderType = .noBorder
        scroll.verticalScrollElasticity = .none
        scroll.horizontalScrollElasticity = .none
        let document = SyntheticDocument(frame: NSRect(x: 0, y: 0, width: width, height: 7200))
        scroll.documentView = document
        window.contentView = scroll
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.displayIfNeeded()
        publish(sequence: 0)
        poll = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.readCommand()
                if self.scroll.contentView.bounds.origin.y != self.publishedOffset {
                    self.publish(sequence: self.sequence)
                }
            }
        }
    }

    func readCommand() {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("command.json")),
              let command = try? JSONDecoder().decode(TargetCommand.self, from: data),
              command.sequence != sequence else { return }
        sequence = command.sequence
        if command.quit {
            poll?.invalidate()
            window.orderOut(nil)
            NSApp.terminate(nil)
            return
        }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: command.offset))
        if let document = scroll.documentView as? SyntheticDocument {
            document.caretY = command.caret == true ? command.offset + 100 : nil
            document.needsDisplay = true
        }
        scroll.reflectScrolledClipView(scroll.contentView)
        window.displayIfNeeded()
        publish(sequence: command.sequence)
    }

    func publish(sequence: Int) {
        guard let screen = window.screen,
              let display = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return }
        // Exclude the window border; all sampled pixels belong to this opaque synthetic document.
        let viewRect = scroll.contentView.bounds.insetBy(dx: 3, dy: 3)
        let windowRect = scroll.contentView.convert(viewRect, to: nil)
        let rect = window.convertToScreen(windowRect)
        publishedOffset = scroll.contentView.bounds.origin.y
        let state: [String: Any] = [
            "sequence": sequence, "pid": ProcessInfo.processInfo.processIdentifier,
            "windowID": window.windowNumber, "displayID": display.uint32Value,
            "x": rect.minX - screen.frame.minX, "y": screen.frame.maxY - rect.maxY,
            "width": rect.width, "height": rect.height, "scale": screen.backingScaleFactor,
            "offset": scroll.contentView.bounds.origin.y
        ]
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys, .prettyPrinted]) {
            try? data.write(to: directory.appendingPathComponent("state.json"), options: .atomic)
        }
    }
}

@main struct SyntheticTargetMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = TargetDelegate()
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
