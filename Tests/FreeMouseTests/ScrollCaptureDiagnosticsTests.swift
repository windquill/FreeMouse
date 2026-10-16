import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import FreeMouse

struct ScrollCaptureDiagnosticsTests {
    private func image(_ seed: UInt8 = 10, width: Int = 3, height: Int = 2) throws -> CGImage {
        var bytes: [UInt8] = []
        for index in 0..<(width * height) {
            bytes += [seed + UInt8(index), 90 + UInt8(index), 160 + UInt8(index), 255]
        }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        return try #require(CGImage(width: width, height: height, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func frame(_ sequence: UInt64, seed: UInt8 = 10, width: Int = 3, height: Int = 2) throws -> ScrollVideoFrame {
        ScrollVideoFrame(image: try image(seed, width: width, height: height),
                         sequence: sequence, timestamp: Double(sequence) + 0.25)
    }

    private func freeze(_ collector: ScrollCaptureDiagnostics) throws -> ScrollCaptureDiagnosticSnapshot {
        collector.recordAccepted(try frame(2), appended: true)
        collector.recordNoOverlap(try frame(4, seed: 20), totalHeight: 802,
                                 lastDeferredSequence: 3, reason: "无法可靠匹配两帧。")
        return try #require(collector.snapshot)
    }

    // Replacing the reference on a duplicate would export a pair the matcher never compared.
    @Test func duplicateFramesDoNotReplaceTheActualAppendReference() throws {
        let collector = ScrollCaptureDiagnostics()
        collector.recordAccepted(try frame(1), appended: true)
        collector.recordAccepted(try frame(2, seed: 20), appended: false)
        collector.recordNoOverlap(try frame(3, seed: 30), totalHeight: 2,
                                 lastDeferredSequence: 0, reason: "noOverlap")
        let snapshot = try #require(collector.snapshot)
        #expect(snapshot.reference.sequence == 1)
        #expect(snapshot.failed.sequence == 3)
        #expect(snapshot.reference.timestamp == 1.25)
        #expect(snapshot.failed.timestamp == 3.25)
    }

    @Test func successfulAppendDropsRecoveredEvidenceAndStartsTheNextFailureEpisode() throws {
        let collector = ScrollCaptureDiagnostics()
        _ = try freeze(collector)
        collector.recordAccepted(try frame(8, seed: 50), appended: true)
        #expect(collector.snapshot == nil)
        collector.recordNoOverlap(try frame(9, seed: 60), totalHeight: 9_000,
                                 lastDeferredSequence: 7, reason: "later")
        let snapshot = try #require(collector.snapshot)
        #expect(snapshot.reference.sequence == 8)
        #expect(snapshot.failed.sequence == 9)
        #expect(snapshot.totalHeight == 9_000)
        #expect(snapshot.lastDeferredSequence == 7)
        #expect(snapshot.reason == "later")
        #expect(collector.unavailableReason == nil)
    }

    @Test func verifiedDuplicateClearsTheEpisodeWithoutReplacingTheAppendReference() throws {
        let collector = ScrollCaptureDiagnostics()
        let first = try freeze(collector)
        collector.recordAccepted(try frame(6, seed: 60), appended: false)
        #expect(collector.snapshot == nil)
        collector.recordNoOverlap(try frame(7, seed: 70), totalHeight: 802,
                                 lastDeferredSequence: 0, reason: "next episode")
        let snapshot = try #require(collector.snapshot)
        #expect(snapshot.reference.sequence == 2)
        #expect(snapshot.reference.image === first.reference.image)
        #expect(snapshot.failed.sequence == 7)
        #expect(snapshot.reason == "next episode")
    }

    @Test func unresolvedEpisodeKeepsItsFirstPairAndReportsTheLatestFailureState() throws {
        let collector = ScrollCaptureDiagnostics()
        let first = try freeze(collector)
        collector.recordNoOverlap(try frame(9, seed: 60), totalHeight: 802,
                                 lastDeferredSequence: 8, reason: "still unmatched")
        let snapshot = try #require(collector.snapshot)
        #expect(snapshot.reference.sequence == 2)
        #expect(snapshot.failed.sequence == 4)
        #expect(snapshot.reference.image === first.reference.image)
        #expect(snapshot.failed.image === first.failed.image)
        #expect(snapshot.totalHeight == 802)
        #expect(snapshot.lastDeferredSequence == 3)
        #expect(snapshot.reason == "无法可靠匹配两帧。")
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let directory = try snapshot.export(to: parent, version: "test", build: "test")
        let report = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("report.json"))) as? [String: Any])
        #expect(report["schemaVersion"] as? Int == 2)
        #expect(report["evidenceScope"] as? String == "firstFailureSinceLastVerifiedMatch")
        #expect(report["failureCount"] as? Int == 2)
        let latest = try #require(report["latestFailure"] as? [String: Any])
        #expect(latest["sequence"] as? Int == 9)
        #expect(latest["timestamp"] as? Double == 9.25)
        #expect(latest["totalHeight"] as? Int == 802)
        #expect(latest["lastDeferredSequence"] as? Int == 8)
        #expect(latest["reason"] as? String == "still unmatched")
    }

    @Test func latestRealAppendIsTheFailureReference() throws {
        let collector = ScrollCaptureDiagnostics()
        collector.recordAccepted(try frame(1), appended: true)
        collector.recordAccepted(try frame(2), appended: true)
        collector.recordNoOverlap(try frame(3), totalHeight: 9,
                                 lastDeferredSequence: 0, reason: "noOverlap")
        #expect(try #require(collector.snapshot).reference.sequence == 2)
    }

    @Test func failureWithoutAnAcceptedReferenceIsUnavailable() throws {
        let collector = ScrollCaptureDiagnostics()
        collector.recordAccepted(try frame(1), appended: false)
        collector.recordNoOverlap(try frame(2), totalHeight: 0,
                                 lastDeferredSequence: 0, reason: "noOverlap")
        #expect(collector.snapshot == nil)
        #expect(try #require(collector.unavailableReason).contains("参考"))
    }

    @Test func oversizedReferenceIsNotRetainedAndExplainsUnavailableDiagnostics() throws {
        let collector = ScrollCaptureDiagnostics(maximumFramePixels: 5)
        collector.recordAccepted(try frame(1), appended: true)
        collector.recordNoOverlap(try frame(2, width: 2, height: 2), totalHeight: 2,
                                 lastDeferredSequence: 0, reason: "noOverlap")
        #expect(collector.snapshot == nil)
        #expect(try #require(collector.unavailableReason).contains("容量"))
    }

    @Test func oversizedFailedFrameCannotFreezeAnUnboundedPair() throws {
        let collector = ScrollCaptureDiagnostics(maximumFramePixels: 6)
        collector.recordAccepted(try frame(1), appended: true)
        collector.recordNoOverlap(try frame(2, width: 4), totalHeight: 2,
                                 lastDeferredSequence: 0, reason: "noOverlap")
        #expect(collector.snapshot == nil)
        #expect(try #require(collector.unavailableReason).contains("容量"))
    }

    @Test func successfulRecoveryAllowsDiagnosticsAfterAnOverBudgetFailure() throws {
        let collector = ScrollCaptureDiagnostics(maximumFramePixels: 6)
        collector.recordAccepted(try frame(1), appended: true)
        collector.recordNoOverlap(try frame(2, width: 4), totalHeight: 2,
                                 lastDeferredSequence: 0, reason: "too big")
        collector.recordAccepted(try frame(3, seed: 40), appended: true)
        collector.recordNoOverlap(try frame(4, seed: 50), totalHeight: 4,
                                 lastDeferredSequence: 0, reason: "new episode")
        let snapshot = try #require(collector.snapshot)
        #expect(snapshot.reference.sequence == 3)
        #expect(snapshot.failed.sequence == 4)
        #expect(snapshot.totalHeight == 4)
    }

    @Test func exactPixelBudgetAllowsBothFramesAndClearDropsTheWholeSession() throws {
        let collector = ScrollCaptureDiagnostics(maximumFramePixels: 6)
        _ = try freeze(collector)
        collector.clear()
        #expect(collector.snapshot == nil)
        collector.recordNoOverlap(try frame(12), totalHeight: 0,
                                 lastDeferredSequence: 0, reason: "new session")
        #expect(collector.snapshot == nil)
        #expect(try #require(collector.unavailableReason).contains("参考"))
        collector.clear()
        _ = try freeze(collector)
    }

    private func pixels(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { storage in
            let context = try #require(CGContext(data: storage.baseAddress, width: image.width,
                height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    @Test func explicitExportPreservesPNGDataAndOnlyReportsCaptureMetadata() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let collector = ScrollCaptureDiagnostics()
        let snapshot = try freeze(collector)
        #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty)
        let directory = try snapshot.export(to: parent, version: "1.1.11", build: "13")
        #expect(directory.deletingLastPathComponent().standardizedFileURL == parent.standardizedFileURL)
        #expect(UUID(uuidString: directory.lastPathComponent) != nil)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)) ==
                Set(["reference.png", "failed.png", "report.json"]))
        for (filename, expected) in [("reference.png", snapshot.reference.image), ("failed.png", snapshot.failed.image)] {
            let source = try #require(CGImageSourceCreateWithURL(directory.appendingPathComponent(filename) as CFURL, nil))
            let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            #expect(decoded.width == 3)
            #expect(decoded.height == 2)
            #expect(try pixels(decoded) == pixels(expected))
        }
        let report = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("report.json"))) as? [String: Any])
        #expect(Set(report.keys) == Set(["schemaVersion", "appVersion", "appBuild", "reference", "failed", "totalHeight", "lastDeferredSequence", "reason", "evidenceScope", "failureCount", "latestFailure"]))
        #expect(report["appVersion"] as? String == "1.1.11")
        #expect(report["appBuild"] as? String == "13")
        #expect(report["totalHeight"] as? Int == 802)
        #expect(report["lastDeferredSequence"] as? Int == 3)
        let reference = try #require(report["reference"] as? [String: Any])
        #expect(Set(reference.keys) == Set(["width", "height", "sequence", "timestamp"]))
        #expect(reference["sequence"] as? Int == 2)
        #expect(reference["timestamp"] as? Double == 2.25)
    }

    @Test func repeatedExportsCreateDistinctFoldersWithoutOverwritingExistingData() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let sentinel = parent.appendingPathComponent("existing.txt")
        try Data("keep".utf8).write(to: sentinel, options: .withoutOverwriting)
        let snapshot = try freeze(ScrollCaptureDiagnostics())
        let first = try snapshot.export(to: parent, version: "1", build: "1")
        let firstReport = try Data(contentsOf: first.appendingPathComponent("report.json"))
        let second = try snapshot.export(to: parent, version: "2", build: "2")
        #expect(first != second)
        #expect(try Data(contentsOf: first.appendingPathComponent("report.json")) == firstReport)
        #expect(try String(contentsOf: sentinel, encoding: .utf8) == "keep")
    }
}
