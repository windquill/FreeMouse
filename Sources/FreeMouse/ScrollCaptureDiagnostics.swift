import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Actor-owned, bounded evidence for a single scrolling capture session.
final class ScrollCaptureDiagnostics {
    private(set) var snapshot: ScrollCaptureDiagnosticSnapshot?
    private(set) var unavailableReason: String? = "尚未记录拼接失败。"
    private let maximumFramePixels: Int
    private var reference: ScrollVideoFrame?
    private var referenceExceededBudget = false
    private var attemptedFailure = false

    init(maximumFramePixels: Int = 4_000_000) {
        precondition(maximumFramePixels > 0)
        self.maximumFramePixels = maximumFramePixels
    }

    func recordAccepted(_ frame: ScrollVideoFrame, appended: Bool) {
        // Any verified match resolves the current failure episode. A duplicate
        // does not replace the stitcher's last appended viewport, so it must not
        // replace our reference either (including a verified reverse scroll).
        snapshot = nil
        attemptedFailure = false
        guard appended else {
            unavailableReason = referenceExceededBudget
                ? "截图选区超过诊断容量；正常长截图不受影响。请缩小选区后重新采集诊断。"
                : "尚未记录拼接失败。"
            return
        }
        guard fitsBudget(frame.image) else {
            reference = nil
            referenceExceededBudget = true
            unavailableReason = "截图选区超过诊断容量；正常长截图不受影响。请缩小选区后重新采集诊断。"
            return
        }
        reference = frame
        referenceExceededBudget = false
        unavailableReason = "尚未记录拼接失败。"
    }

    func recordNoOverlap(_ frame: ScrollVideoFrame, totalHeight: Int,
                         lastDeferredSequence: UInt64, reason: String) {
        let latest = ScrollCaptureDiagnosticFailure(sequence: frame.sequence,
            timestamp: frame.timestamp, totalHeight: totalHeight,
            lastDeferredSequence: lastDeferredSequence, reason: reason)
        if let existing = snapshot {
            // Preserve the first failed comparison in this unresolved episode,
            // while making the most recent state explicit without retaining a
            // third image or mistaking the first failure for the final state.
            snapshot = ScrollCaptureDiagnosticSnapshot(reference: existing.reference,
                failed: existing.failed, totalHeight: existing.totalHeight,
                lastDeferredSequence: existing.lastDeferredSequence, reason: existing.reason,
                failureCount: existing.failureCount == Int.max ? Int.max : existing.failureCount + 1,
                latestFailure: latest)
            return
        }
        guard !attemptedFailure else { return }
        attemptedFailure = true
        guard fitsBudget(frame.image) else {
            unavailableReason = "失败帧超过诊断容量；正常长截图不受影响。请缩小选区后重新采集诊断。"
            return
        }
        guard let reference else {
            if !referenceExceededBudget {
                unavailableReason = "没有已拼接的参考帧，无法导出此次诊断。"
            }
            return
        }
        snapshot = ScrollCaptureDiagnosticSnapshot(reference: reference, failed: frame,
            totalHeight: totalHeight, lastDeferredSequence: lastDeferredSequence, reason: reason,
            failureCount: 1, latestFailure: latest)
        unavailableReason = nil
    }

    func clear() {
        snapshot = nil
        reference = nil
        referenceExceededBudget = false
        attemptedFailure = false
        unavailableReason = "尚未记录拼接失败。"
    }

    private func fitsBudget(_ image: CGImage) -> Bool {
        let pixels = image.width.multipliedReportingOverflow(by: image.height)
        return !pixels.overflow && pixels.partialValue > 0 && pixels.partialValue <= maximumFramePixels
    }
}

/// Metadata only: later rejected images are not retained by the diagnostic pair.
struct ScrollCaptureDiagnosticFailure: Encodable, Sendable {
    let sequence: UInt64
    let timestamp: TimeInterval
    let totalHeight: Int
    let lastDeferredSequence: UInt64
    let reason: String
}

/// CGImage is immutable; this value never exposes a mutable image buffer.
struct ScrollCaptureDiagnosticSnapshot: @unchecked Sendable {
    let reference: ScrollVideoFrame
    let failed: ScrollVideoFrame
    let totalHeight: Int
    let lastDeferredSequence: UInt64
    let reason: String
    let failureCount: Int
    let latestFailure: ScrollCaptureDiagnosticFailure

    func export(to parentDirectory: URL, version: String, build: String) throws -> URL {
        guard parentDirectory.isFileURL else { throw ScrollCaptureDiagnosticExportError.invalidDirectory }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Prepare the report first; an encoding error must not leave an apparent result directory.
        let report = try encoder.encode(Report(schemaVersion: 2, appVersion: version, appBuild: build,
            reference: FrameInfo(reference), failed: FrameInfo(failed), totalHeight: totalHeight,
            lastDeferredSequence: lastDeferredSequence, reason: reason,
            evidenceScope: "firstFailureSinceLastVerifiedMatch", failureCount: failureCount,
            latestFailure: latestFailure))
        let destination = parentDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        // mkdir reserves this exact UUID directory atomically and fails if it already exists.
        guard destination.path.withCString({ mkdir($0, S_IRWXU) }) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var completed = false
        defer {
            if !completed { try? FileManager.default.removeItem(at: destination) }
        }
        try writePNG(reference.image, to: destination.appendingPathComponent("reference.png"))
        try writePNG(failed.image, to: destination.appendingPathComponent("failed.png"))
        // report.json is the final completion marker; no existing file may be replaced.
        try report.write(to: destination.appendingPathComponent("report.json"), options: .withoutOverwriting)
        completed = true
        return destination
    }

    private func writePNG(_ image: CGImage, to url: URL) throws {
        guard let writer = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ScrollCaptureDiagnosticExportError.pngEncoding
        }
        CGImageDestinationAddImage(writer, image, nil)
        guard CGImageDestinationFinalize(writer) else { throw ScrollCaptureDiagnosticExportError.pngEncoding }
    }

    private struct FrameInfo: Encodable {
        let width: Int
        let height: Int
        let sequence: UInt64
        let timestamp: TimeInterval

        init(_ frame: ScrollVideoFrame) {
            width = frame.image.width
            height = frame.image.height
            sequence = frame.sequence
            timestamp = frame.timestamp
        }
    }

    private struct Report: Encodable {
        let schemaVersion: Int
        let appVersion: String
        let appBuild: String
        let reference: FrameInfo
        let failed: FrameInfo
        let totalHeight: Int
        let lastDeferredSequence: UInt64
        let reason: String
        let evidenceScope: String
        let failureCount: Int
        let latestFailure: ScrollCaptureDiagnosticFailure
    }
}

private enum ScrollCaptureDiagnosticExportError: LocalizedError {
    case invalidDirectory, pngEncoding

    var errorDescription: String? {
        switch self {
        case .invalidDirectory: return "请选择本机文件夹保存诊断。"
        case .pngEncoding: return "诊断图片保存失败，未生成完整诊断报告。"
        }
    }
}
