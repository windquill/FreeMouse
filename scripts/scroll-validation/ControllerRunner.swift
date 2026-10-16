import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct LiveState: Decodable {
    let sequence: Int
    let pid: Int32
    let windowID: Int
    let displayID: UInt32
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let scale: Double
    let offset: Double
    var region: CaptureRegion {
        CaptureRegion(displayID: displayID, rect: CGRect(x: x, y: y, width: width, height: height), scale: scale)
    }
}

enum ValidationError: Error { case failed(String) }

@MainActor final class ValidationDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { .terminateCancel }
}

@main struct LiveValidationMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = ValidationDelegate()
        app.delegate = delegate
        Task { @MainActor in
            await validate()
            exit(0)
        }
        app.run()
        withExtendedLifetime(delegate) {}
    }

    @MainActor static func validate() async {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        var lines: [String] = []
        func log(_ text: String) { lines.append(text); print(text) }
        do {
            guard CGPreflightScreenCaptureAccess() else {
                throw ValidationError.failed("BLOCKED: CGPreflightScreenCaptureAccess=false; no capture or permission prompt attempted")
            }
            log("SCREEN_CAPTURE_AUTHORIZED=true")
            let state = try readState(directory)
            guard state.pid != ProcessInfo.processInfo.processIdentifier else { throw ValidationError.failed("Target must be a different process") }
            log("TARGET_PID=\(state.pid) TARGET_WINDOW=\(state.windowID) REGION=\(state.width)x\(state.height) SCALE=\(state.scale)")
            let controller = ScrollCaptureController()
            defer { controller.cancel() }
            var output: CGImage?
            var deliveries = 0
            controller.onOutput = { image, _ in
                log("OUTPUT_AT \(ProcessInfo.processInfo.systemUptime) height=\(image.height)")
                output = image; deliveries += 1
            }
            controller.start(region: state.region) { image in output = image; deliveries += 1 }
            let origin = state.offset
            let width = Int(state.width * state.scale)
            for (index, offset) in [0.0, 48, 96, 144, 240, 384, 528, 672, 816, 960, 1104, 1248, 1392, 1536, 1680].enumerated() {
                try send(directory, sequence: index + 1, offset: origin + offset)
                let actual = try await awaitState(directory, sequence: index + 1)
                let expected = Int((state.height + actual.offset - origin) * state.scale)
                try await waitForHeight(width: width, height: expected)
                log("CONTROLLER_STEP_PASS offset=\(actual.offset) height=\(expected)")
            }
            // A real final viewport arrives 220ms after clicking Done: beyond
            // the former fixed 180ms sleep, but within the new settle window.
            let finishTime = ProcessInfo.processInfo.systemUptime
            let lateScroll = Task { @MainActor in
                log("LATE_TASK_START \(ProcessInfo.processInfo.systemUptime - finishTime)")
                let remaining = max(0, finishTime + 0.220 - ProcessInfo.processInfo.systemUptime)
                try await Task.sleep(for: .seconds(remaining))
                log("LATE_COMMAND_AT \(ProcessInfo.processInfo.systemUptime - finishTime)")
                try send(directory, sequence: 100, offset: origin + 1800)
                _ = try await awaitState(directory, sequence: 100)
                log("LATE_ACK_AT \(ProcessInfo.processInfo.systemUptime - finishTime)")
            }
            guard let finish = buttons().first(where: { $0.title == "完成 / 编辑" }), finish.isEnabled else {
                throw ValidationError.failed("Finish button unavailable")
            }
            log("FINISH_CLICK_AT \(finishTime)")
            finish.performClick(nil)
            log("FINISH_CLICK_RETURN \(ProcessInfo.processInfo.systemUptime - finishTime)")
            for _ in 0..<500 {
                if output != nil { break }
                if let modal = NSApp.modalWindow {
                    log("UNEXPECTED_MODAL \(modal.title)")
                    NSApp.abortModal()
                    throw ValidationError.failed("Unexpected incomplete-tail alert")
                }
                try await Task.sleep(for: .milliseconds(15))
            }
            _ = try await lateScroll.value
            guard let image = output else { throw ValidationError.failed("Controller output timeout") }
            let expectedHeight = Int((state.height + 1800) * state.scale)
            guard image.width == width, image.height == expectedHeight else {
                throw ValidationError.failed("Controller tail height \(image.width)x\(image.height), expected \(width)x\(expectedHeight)")
            }
            try writePNG(image, to: directory.appendingPathComponent("controller-assembled.png"))
            log("CONTROLLER_TAIL_PASS size=\(image.width)x\(image.height) seconds=\(ProcessInfo.processInfo.systemUptime-finishTime) deliveries=\(deliveries)")
            // Exercise cancellation of an actual finishing controller session.
            output = nil
            controller.start(region: state.region) { image in output = image; deliveries += 1 }
            try await waitForHeight(width: width, height: Int(state.height * state.scale))
            guard let finishAgain = buttons().first(where: { $0.title == "完成 / 编辑" }), finishAgain.isEnabled else {
                throw ValidationError.failed("Second finish button unavailable")
            }
            finishAgain.performClick(nil)
            controller.cancel()
            try await Task.sleep(for: .milliseconds(600))
            guard deliveries == 1, output == nil, !controller.isActive else {
                throw ValidationError.failed("Cancelled finishing session delivered output")
            }
            log("CONTROLLER_CANCEL_PASS deliveries=\(deliveries)")
            // Paused movement driven by the target process, without any wheel
            // event, must still produce an explicit incomplete-tail warning.
            output = nil
            controller.start(region: state.region) { image in output = image; deliveries += 1 }
            try await waitForHeight(width: width, height: Int(state.height * state.scale))
            guard let pause = buttons().first(where: { $0.title == "暂停" }), pause.isEnabled else {
                throw ValidationError.failed("Pause button unavailable")
            }
            pause.performClick(nil)
            guard buttons().contains(where: { $0.title == "继续" && $0.isEnabled }) else {
                throw ValidationError.failed("Pause action did not enter the paused state")
            }
            log("PAUSED_TARGET_BEFORE offset=\(try readState(directory).offset) deliveries=\(deliveries)")
            try send(directory, sequence: 200, offset: origin + 1848)
            _ = try await awaitState(directory, sequence: 200)
            log("PAUSED_TARGET_AFTER offset=\(try readState(directory).offset)")
            try await Task.sleep(for: .milliseconds(300))
            var warned = false
            let warningObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { notification in
                MainActor.assumeIsolated {
                    guard let window = notification.object as? NSWindow, let content = window.contentView else { return }
                    if views(content).compactMap({ $0 as? NSTextField }).contains(where: {
                        $0.stringValue == "最后一段未完整拼接"
                    }) { warned = true }
                }
            }
            guard let pausedFinish = buttons().first(where: { $0.title == "完成 / 编辑" }) else {
                throw ValidationError.failed("Paused finish unavailable")
            }
            pausedFinish.performClick(nil)
            for _ in 0..<400 {
                if let proceed = buttons().first(where: { $0.title == "输出已有内容" }) {
                    warned = true
                    proceed.performClick(nil)
                }
                if output != nil { break }
                try await Task.sleep(for: .milliseconds(15))
            }
            NotificationCenter.default.removeObserver(warningObserver)
            guard warned, output != nil, deliveries == 2 else {
                throw ValidationError.failed("Paused native movement: warning=\(warned) output=\(output?.height ?? 0) deliveries=\(deliveries)")
            }
            log("CONTROLLER_PAUSED_NATIVE_MOVEMENT_PASS warning=true deliveries=\(deliveries)")
            if AXIsProcessTrusted() {
                output = nil
                let automaticOrigin = try readState(directory).offset
                controller.start(region: state.region) { image in output = image; deliveries += 1 }
                try await waitForHeight(width: width, height: Int(state.height * state.scale))
                guard let automatic = buttons().first(where: { $0.title == "自动滚动" }) else {
                    throw ValidationError.failed("Automatic button unavailable")
                }
                automatic.performClick(nil)
                var advanced = false
                for _ in 0..<500 {
                    if try readState(directory).offset - automaticOrigin >= 200 { advanced = true; break }
                    try await Task.sleep(for: .milliseconds(15))
                }
                guard advanced else { throw ValidationError.failed("Automatic capture did not advance") }
                buttons().first(where: { $0.title == "停止自动" })?.performClick(nil)
                buttons().first(where: { $0.title == "完成 / 编辑" })?.performClick(nil)
                for _ in 0..<500 {
                    if output != nil { break }
                    if NSApp.modalWindow != nil {
                        NSApp.abortModal()
                        throw ValidationError.failed("Automatic capture reported incomplete tail")
                    }
                    try await Task.sleep(for: .milliseconds(15))
                }
                let actualOffset = try readState(directory).offset
                let automaticHeight = Int(((state.height + actualOffset - automaticOrigin) * state.scale).rounded())
                guard let automaticImage = output, automaticImage.height == automaticHeight else {
                    throw ValidationError.failed("Automatic height mismatch: expected \(automaticHeight), got \(output?.height ?? 0)")
                }
                log("CONTROLLER_AUTOMATIC_PASS offset=\(actualOffset - automaticOrigin) height=\(automaticImage.height)")
            } else {
                log("CONTROLLER_AUTOMATIC_SKIPPED accessibility=false; no permission prompt attempted")
            }
            log("RESULT_PASS controller=true")
        } catch {
            log("RESULT_FAIL \(error)")
        }
        try? lines.joined(separator: "\n").write(to: directory.appendingPathComponent("controller-result.log"), atomically: true, encoding: .utf8)
        try? send(directory, sequence: 1_000_000, offset: 0, quit: true)
    }

    @MainActor static func views(_ root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap { views($0) }
    }
    @MainActor static func buttons() -> [NSButton] {
        NSApp.windows.filter(\.isVisible).compactMap(\.contentView).flatMap { views($0) }.compactMap { $0 as? NSButton }
    }
    @MainActor static func waitForHeight(width: Int, height: Int) async throws {
        let prefix = "\(width) × \(height) px"
        for _ in 0..<500 {
            let labels = NSApp.windows.filter(\.isVisible).compactMap(\.contentView).flatMap { views($0) }.compactMap { $0 as? NSTextField }
            if labels.contains(where: { $0.stringValue.hasPrefix(prefix) }),
               buttons().contains(where: { $0.title == "完成 / 编辑" && $0.isEnabled }) { return }
            try await Task.sleep(for: .milliseconds(15))
        }
        throw ValidationError.failed("Controller preview height timeout \(prefix)")
    }

    static func readState(_ directory: URL) throws -> LiveState {
        try JSONDecoder().decode(LiveState.self, from: Data(contentsOf: directory.appendingPathComponent("state.json")))
    }
    static func send(_ directory: URL, sequence: Int, offset: Double, quit: Bool = false) throws {
        let data = try JSONSerialization.data(withJSONObject: ["sequence": sequence, "offset": offset, "quit": quit])
        try data.write(to: directory.appendingPathComponent("command.json"), options: .atomic)
    }
    static func awaitState(_ directory: URL, sequence: Int) async throws -> LiveState {
        for _ in 0..<200 {
            if let state = try? readState(directory), state.sequence == sequence { return state }
            try await Task.sleep(for: .milliseconds(15))
        }
        throw ValidationError.failed("TARGET_ACK_TIMEOUT")
    }
    static func rgba(_ image: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { throw ValidationError.failed("colorSpace") }
        try pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
                throw ValidationError.failed("context")
            }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return pixels
    }
    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw ValidationError.failed("PNG destination") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ValidationError.failed("PNG encode") }
    }
}
