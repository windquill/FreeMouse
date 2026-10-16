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
            guard controller.isActive, controller.capturedHeight == 0 else { throw ValidationError.failed("Ready state invalid") }
            controller.beginCapture()
            let origin = state.offset
            let width = Int(state.width * state.scale)
            for (index, offset) in [0.0, 48, 96, 144, 240, 384, 528, 672, 816, 960, 1104, 1248, 1392, 1536, 1680, 1800].enumerated() {
                try send(directory, sequence: index + 1, offset: origin + offset)
                let actual = try await awaitState(directory, sequence: index + 1)
                let expected = Int((state.height + actual.offset - origin) * state.scale)
                try await waitForHeight(controller, height: expected)
                log("CAPSO_STEP_PASS offset=\(actual.offset) height=\(expected)")
            }
            // Scroll immediately before Done, without waiting for the next periodic sample.
            try send(directory, sequence: 100, offset: origin + 1848)
            _ = try await awaitState(directory, sequence: 100)
            controller.finishCapture()
            for _ in 0..<500 {
                if output != nil { break }
                try await Task.sleep(for: .milliseconds(15))
            }
            let expectedHeight = Int((state.height + 1848) * state.scale)
            guard let image = output, image.width == width, image.height == expectedHeight, deliveries == 1 else {
                throw ValidationError.failed("Capso output dimensions or delivery mismatch")
            }
            try writePNG(image, to: directory.appendingPathComponent("controller-assembled.png"))
            log("CAPSO_OUTPUT_PASS size=\(image.width)x\(image.height) deliveries=\(deliveries)")
            output = nil
            controller.start(region: state.region) { image in output = image; deliveries += 1 }
            controller.beginCapture()
            try await waitForHeight(controller, height: Int(state.height * state.scale))
            controller.finishCapture()
            controller.cancel()
            try await Task.sleep(for: .milliseconds(600))
            guard deliveries == 1, output == nil, !controller.isActive else {
                throw ValidationError.failed("Cancelled finishing session delivered output")
            }
            log("CAPSO_CANCEL_PASS deliveries=\(deliveries)")
            controller.start(region: state.region) { _ in deliveries += 1 }
            controller.beginCapture()
            controller.cancel()
            controller.start(region: state.region) { _ in deliveries += 1 }
            try await Task.sleep(for: .milliseconds(600))
            guard controller.isActive, controller.capturedHeight == 0, deliveries == 1 else {
                throw ValidationError.failed("Old session affected replacement session")
            }
            controller.cancel()
            log("CAPSO_RESTART_PASS")
            output = nil
            controller.start(region: state.region) { image in output = image; deliveries += 1 }
            controller.beginCapture()
            try await waitForHeight(controller, height: Int(state.height * state.scale))
            try send(directory, sequence: 200, offset: origin + 5000)
            _ = try await awaitState(directory, sequence: 200)
            var warned = false
            let observer = Timer(timeInterval: 0.05, repeats: true) { _ in
                MainActor.assumeIsolated {
                    guard let modal = NSApp.modalWindow, let content = modal.contentView,
                          let cancel = views(content).compactMap({ $0 as? NSButton }).first(where: { $0.title == "取消" }) else { return }
                    warned = true
                    cancel.performClick(nil)
                }
            }
            RunLoop.main.add(observer, forMode: .common)
            RunLoop.main.add(observer, forMode: .modalPanel)
            controller.finishCapture()
            for _ in 0..<500 {
                if warned || output != nil { break }
                try await Task.sleep(for: .milliseconds(15))
            }
            observer.invalidate()
            guard !warned, deliveries == 2, output != nil, !controller.isActive else {
                throw ValidationError.failed("Finish did not deliver existing image without confirmation")
            }
            log("CAPSO_FINISH_NO_DIALOG_PASS existingImage=true")
            let still = ScrollCaptureController()
            var stillOutput: CGImage?
            still.start(region: state.region) { stillOutput = $0 }
            still.beginCapture()
            try await waitForHeight(still, height: Int(state.height * state.scale))
            let caretData = try JSONSerialization.data(withJSONObject: ["sequence": 300, "offset": origin + 5000, "quit": false, "caret": true])
            try caretData.write(to: directory.appendingPathComponent("command.json"), options: .atomic)
            _ = try await awaitState(directory, sequence: 300)
            try await Task.sleep(for: .milliseconds(400))
            var unexpectedWarning = false
            let alertCloser = Timer(timeInterval: 0.05, repeats: true) { _ in
                MainActor.assumeIsolated {
                    if let modal = NSApp.modalWindow, let content = modal.contentView,
                       let cancel = views(content).compactMap({ $0 as? NSButton }).first(where: { $0.title == "取消" }) {
                        unexpectedWarning = true; cancel.performClick(nil)
                    }
                }
            }
            RunLoop.main.add(alertCloser, forMode: .common)
            RunLoop.main.add(alertCloser, forMode: .modalPanel)
            still.finishCapture()
            for _ in 0..<500 {
                if stillOutput != nil || unexpectedWarning { break }
                try await Task.sleep(for: .milliseconds(15))
            }
            alertCloser.invalidate(); still.cancel()
            guard !unexpectedWarning, stillOutput?.height == Int(state.height * state.scale) else {
                throw ValidationError.failed("Stationary caret caused false incomplete-tail warning")
            }
            log("CAPSO_STATIONARY_CARET_PASS noWarning=true height=\(stillOutput!.height)")
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
    @MainActor static func waitForHeight(_ controller: ScrollCaptureController, height: Int) async throws {
        for _ in 0..<500 {
            if controller.capturedHeight == height { return }
            if controller.capturedHeight > height { throw ValidationError.failed("Height overshoot: \(controller.capturedHeight) > \(height)") }
            try await Task.sleep(for: .milliseconds(15))
        }
        throw ValidationError.failed("Capso preview timeout actual=\(controller.capturedHeight) expected=\(height)")
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
