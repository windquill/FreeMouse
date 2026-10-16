import AppKit
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

@main struct LiveValidationMain {
    @MainActor static func main() async {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        var lines: [String] = []
        func log(_ text: String) { lines.append(text); print(text) }
        var source: ScrollFrameSource?
        do {
            guard CGPreflightScreenCaptureAccess() else {
                throw ValidationError.failed("BLOCKED: CGPreflightScreenCaptureAccess=false; no capture or permission prompt attempted")
            }
            log("SCREEN_CAPTURE_AUTHORIZED=true")
            let state = try readState(directory)
            guard state.pid != ProcessInfo.processInfo.processIdentifier else { throw ValidationError.failed("Target must be a different process") }
            log("TARGET_PID=\(state.pid) TARGET_WINDOW=\(state.windowID) REGION=\(state.width)x\(state.height) SCALE=\(state.scale)")
            let frameSource = ScrollFrameSource()
            source = frameSource
            try await frameSource.start(region: state.region)
            let stitcher = ScrollStitcher()
            var sequence: UInt64 = 0
            var lastImage: CGImage?
            var accepted = 0
            var rejected = 0
            let origin = state.offset
            let offsets: [Double] = [0, 48, 96, 144, 240, 384, 528, 672, 816, 960, 1104, 1248, 1392, 1536, 1680, 1800]
            for (step, relative) in offsets.enumerated() {
                try send(directory, sequence: step + 1, offset: origin + relative)
                let actual = try await awaitState(directory, sequence: step + 1)
                let expectedHeight = Int((state.height + actual.offset - origin) * state.scale)
                let deadline = ProcessInfo.processInfo.systemUptime + 8
                var reached = false
                repeat {
                    if let failure = frameSource.failure { throw ValidationError.failed("SOURCE_FAILURE: \(failure)") }
                    if let frame = frameSource.nextFrame(after: sequence) {
                        sequence = frame.sequence
                        do {
                            let result = try stitcher.append(frame.image)
                            switch result {
                            case .appended(let rows):
                                accepted += 1
                                lastImage = frame.image
                                log("FRAME step=\(step) seq=\(sequence) add=\(rows) total=\(stitcher.totalHeight) expected=\(expectedHeight)")
                            case .duplicate: break
                            }
                        } catch CaptureError.noOverlap {
                            rejected += 1
                            log("REJECT step=\(step) seq=\(sequence) noOverlap")
                        }
                        if stitcher.totalHeight == expectedHeight {
                            reached = true
                            break
                        }
                        if stitcher.totalHeight > expectedHeight { throw ValidationError.failed("HEIGHT_OVERSHOOT step=\(step) actual=\(stitcher.totalHeight) expected=\(expectedHeight)") }
                    }
                    try await Task.sleep(for: .milliseconds(15))
                } while ProcessInfo.processInfo.systemUptime < deadline
                guard reached else { throw ValidationError.failed("HEIGHT_TIMEOUT step=\(step) actual=\(stitcher.totalHeight) expected=\(expectedHeight)") }
                log("STEP_PASS \(step) offset=\(actual.offset) height=\(stitcher.totalHeight)")
            }
            // Stop while preserving the accepted queue, then drain exactly as a finishing session does.
            await frameSource.stop(preservingPending: true)
            while let frame = frameSource.nextFrame(after: sequence) {
                sequence = frame.sequence
                let result = try stitcher.append(frame.image)
                if case .appended = result { lastImage = frame.image }
            }
            guard let result = stitcher.image, let tail = lastImage else { throw ValidationError.failed("No output image") }
            let pixels = try rgba(result)
            let tailPixels = try rgba(tail)
            // The compositor must preserve the final native capture's last 64 rows exactly.
            let tailBytes = min(64, tail.height) * tail.width * 4
            guard pixels.suffix(tailBytes) == tailPixels.suffix(tailBytes) else { throw ValidationError.failed("TAIL_PIXELS_DIFFER") }
            try writePNG(result, to: directory.appendingPathComponent("assembled.png"))
            try writePNG(tail, to: directory.appendingPathComponent("last-accepted-frame.png"))
            log("TAIL_EXACT_PASS rows=64")
            log("RESULT_PASS accepted=\(accepted) rejected=\(rejected) width=\(result.width) height=\(result.height) finalSequence=\(sequence)")
        } catch {
            log("RESULT_FAIL \(error)")
        }
        await source?.stop()
        try? lines.joined(separator: "\n").write(to: directory.appendingPathComponent("result.log"), atomically: true, encoding: .utf8)
        try? send(directory, sequence: 1_000_000, offset: 0, quit: true)
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
