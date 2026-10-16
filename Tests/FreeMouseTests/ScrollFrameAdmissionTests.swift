import CoreGraphics
import Foundation
import Testing
@testable import FreeMouse

struct ScrollFrameAdmissionTests {
    private func image() throws -> CGImage {
        let bytes = Data(repeating: 255, count: 20 * 40 * 4)
        let provider = try #require(CGDataProvider(data: bytes as CFData))
        return try #require(CGImage(width: 20, height: 40, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: 80, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    @Test func admittedConversionRemainsPendingUntilPublishedAndConsumed() throws {
        let buffer = ScrollFrameBuffer()
        let token = buffer.begin(), frame = try image()
        #expect(buffer.prepareFrame(width: 20, height: 40, token: token))
        #expect(buffer.hasPendingFrames)
        #expect(buffer.nextFrame(after: 0) == nil)
        #expect(buffer.hasPendingFrames)
        buffer.publish(frame, timestamp: 1, token: token)
        #expect(buffer.hasPendingFrames)
        #expect(try #require(buffer.nextFrame(after: 0)).sequence == 1)
        #expect(!buffer.hasPendingFrames)
    }

    @Test func pausingWithoutFramesDoesNotInventAnUnconfirmedTail() throws {
        let buffer = ScrollFrameBuffer()
        let token = buffer.begin(), frame = try image()
        buffer.setPaused(true, token: token)
        #expect(buffer.lastDeferredSequence == 0)
        #expect(!buffer.hasPendingFrames)
        buffer.setPaused(false, token: token)
        #expect(buffer.prepareFrame(width: 20, height: 40, token: token))
        buffer.publish(frame, timestamp: 1, token: token)
        #expect(try #require(buffer.nextFrame(after: 0)).sequence == 1)
        #expect(buffer.lastDeferredSequence == 0)
    }

    @Test func pausingQueuedFramesRecordsTheActualDiscardedTail() throws {
        let buffer = ScrollFrameBuffer()
        let token = buffer.begin(), frame = try image()
        for time in 1...3 { buffer.publish(frame, timestamp: Double(time), token: token) }
        let accepted = try #require(buffer.nextFrame(after: 0))
        #expect(accepted.sequence == 1)
        buffer.setPaused(true, token: token)
        #expect(!buffer.hasPendingFrames)
        #expect(buffer.lastDeferredSequence == 3)
        #expect(buffer.lastDeferredSequence > accepted.sequence)
        buffer.setPaused(false, token: token)
        #expect(buffer.lastDeferredSequence == 3)
    }

    @Test func completeNativeSamplesWhilePausedRecordChangesWithoutCaching() throws {
        let buffer = ScrollFrameBuffer()
        let token = buffer.begin(), frame = try image()
        buffer.setPaused(true, token: token)
        #expect(!buffer.prepareFrame(width: 20, height: 40, token: token))
        #expect(!buffer.prepareFrame(width: 20, height: 40, token: token))
        #expect(!buffer.hasPendingFrames)
        #expect(buffer.lastDeferredSequence == 2)
        #expect(buffer.failure == nil)
        buffer.setPaused(false, token: token)
        #expect(buffer.prepareFrame(width: 20, height: 40, token: token))
        buffer.publish(frame, timestamp: 3, token: token)
        let resumed = try #require(buffer.nextFrame(after: 0))
        #expect(resumed.sequence == 3)
        #expect(resumed.sequence > buffer.lastDeferredSequence)
    }

    @Test func sealingRecordsInFlightTailAndStillDrainsAcceptedFrames() throws {
        let buffer = ScrollFrameBuffer()
        let token = buffer.begin(), frame = try image()
        #expect(buffer.prepareFrame(width: 20, height: 40, token: token))
        buffer.publish(frame, timestamp: 1, token: token)
        #expect(buffer.prepareFrame(width: 20, height: 40, token: token))
        buffer.sealPreservingPending(token: token)
        #expect(buffer.lastDeferredSequence == 2)
        #expect(buffer.hasPendingFrames)
        buffer.publish(frame, timestamp: 2, token: token)
        buffer.fail("late callback", token: token)
        #expect(try #require(buffer.nextFrame(after: 0)).sequence == 1)
        #expect(!buffer.hasPendingFrames)
        #expect(buffer.lastDeferredSequence == 2)
        #expect(buffer.failure == nil)
    }

    @Test func fullBufferRejectsConversionAndRetainsOrderedBridgeFrames() throws {
        let buffer = ScrollFrameBuffer(maxFrames: 2, maxPixels: 6_400)
        let token = buffer.begin(), frame = try image()
        for time in 1...2 {
            #expect(buffer.prepareFrame(width: 20, height: 40, token: token))
            buffer.publish(frame, timestamp: Double(time), token: token)
        }
        #expect(!buffer.prepareFrame(width: 20, height: 40, token: token))
        #expect(buffer.lastDeferredSequence == 3)
        #expect(buffer.failure == nil)
        #expect(buffer.hasPendingFrames)
        let first = try #require(buffer.nextFrame(after: 0))
        let second = try #require(buffer.nextFrame(after: first.sequence))
        #expect(first.sequence == 1)
        #expect(second.sequence == 2)
        #expect(!buffer.hasPendingFrames)
    }

    @Test func rejectedSamplesCountGapsAndAdmissionResumesAfterDrain() throws {
        let buffer = ScrollFrameBuffer(maxFrames: 1, maxPixels: 800)
        let token = buffer.begin(), frame = try image()
        #expect(buffer.prepareFrame(width: 20, height: 40, token: token))
        buffer.publish(frame, timestamp: 1, token: token)
        #expect(!buffer.prepareFrame(width: 20, height: 40, token: token))
        #expect(!buffer.prepareFrame(width: 20, height: 40, token: token))
        #expect(buffer.lastDeferredSequence == 3)
        let first = try #require(buffer.nextFrame(after: 0))
        #expect(buffer.prepareFrame(width: 20, height: 40, token: token))
        buffer.publish(frame, timestamp: 4, token: token)
        let resumed = try #require(buffer.nextFrame(after: first.sequence))
        #expect(resumed.sequence == 4)
        #expect(resumed.sequence > buffer.lastDeferredSequence)
    }

    @Test func pixelBudgetRejectsConversionBeforeTheFrameCountLimit() throws {
        let buffer = ScrollFrameBuffer(maxFrames: 8, maxPixels: 1_599)
        let token = buffer.begin(), frame = try image()
        #expect(buffer.prepareFrame(width: 20, height: 40, token: token))
        buffer.publish(frame, timestamp: 1, token: token)
        #expect(!buffer.prepareFrame(width: 20, height: 40, token: token))
        #expect(buffer.lastDeferredSequence == 2)
        #expect(buffer.failure == nil)
        #expect(try #require(buffer.nextFrame(after: 0)).sequence == 1)
    }

    @Test func pauseDropsPendingFramesButPreservesTheUnconfirmedGap() throws {
        let buffer = ScrollFrameBuffer(maxFrames: 1, maxPixels: 800)
        let token = buffer.begin(), frame = try image()
        buffer.publish(frame, timestamp: 1, token: token)
        #expect(!buffer.prepareFrame(width: 20, height: 40, token: token))
        buffer.setPaused(true, token: token)
        #expect(!buffer.hasPendingFrames)
        #expect(!buffer.isBackpressured)
        #expect(buffer.lastDeferredSequence == 2)
        #expect(!buffer.prepareFrame(width: 20, height: 40, token: token))
        #expect(buffer.lastDeferredSequence == 3)
        buffer.publish(frame, timestamp: 3, token: token)
        #expect(!buffer.hasPendingFrames)
        buffer.setPaused(false, token: token)
        #expect(buffer.lastDeferredSequence == 4)
        #expect(buffer.prepareFrame(width: 20, height: 40, token: token))
        buffer.publish(frame, timestamp: 4, token: token)
        #expect(try #require(buffer.nextFrame(after: 0)).sequence == 5)
    }

    @Test func pauseAndImmediateResumeRejectAlreadyAdmittedConversion() throws {
        let buffer = ScrollFrameBuffer()
        let token = buffer.begin(), frame = try image()
        #expect(buffer.prepareFrame(width: 20, height: 40, token: token))
        buffer.setPaused(true, token: token)
        #expect(!buffer.hasPendingFrames)
        #expect(buffer.lastDeferredSequence == 1)
        buffer.setPaused(false, token: token)
        buffer.publish(frame, timestamp: 1, token: token)
        #expect(!buffer.hasPendingFrames)
        #expect(buffer.lastDeferredSequence == 1)
        #expect(buffer.prepareFrame(width: 20, height: 40, token: token))
        buffer.publish(frame, timestamp: 2, token: token)
        let fresh = try #require(buffer.nextFrame(after: 0))
        #expect(fresh.sequence == 2)
        #expect(fresh.timestamp == 2)
    }

    @Test func staleSessionCannotPauseOrInvalidateCurrentAdmission() throws {
        let buffer = ScrollFrameBuffer()
        let old = buffer.begin(), frame = try image()
        #expect(buffer.prepareFrame(width: 20, height: 40, token: old))
        buffer.setPaused(true, token: old)
        buffer.invalidate(token: old)
        let current = buffer.begin()
        buffer.setPaused(true, token: old)
        #expect(!buffer.prepareFrame(width: 20, height: 40, token: old))
        #expect(buffer.prepareFrame(width: 20, height: 40, token: current))
        buffer.publish(frame, timestamp: 1, token: old)
        buffer.publish(frame, timestamp: 2, token: current)
        let fresh = try #require(buffer.nextFrame(after: 0))
        #expect(fresh.timestamp == 2)
        #expect(fresh.sequence == 2)
        #expect(buffer.lastDeferredSequence == 0)
        #expect(buffer.failure == nil)
    }

    @Test func oversizedNativeFrameFailsBeforeConversion() {
        let buffer = ScrollFrameBuffer(maxFrames: 8, maxPixels: 799)
        let token = buffer.begin()
        #expect(!buffer.prepareFrame(width: 20, height: 40, token: token))
        #expect(buffer.failure != nil)
        #expect(!buffer.isActive(token: token))
        #expect(!buffer.hasPendingFrames)
    }

    @Test(arguments: [(0, 40), (-20, -40), (Int.max, 2)])
    func malformedNativeDimensionsFailBeforeConversion(dimensions: (Int, Int)) {
        let buffer = ScrollFrameBuffer()
        let token = buffer.begin()
        #expect(!buffer.prepareFrame(width: dimensions.0, height: dimensions.1, token: token))
        #expect(buffer.failure != nil)
        #expect(!buffer.isActive(token: token))
    }

    @Test @MainActor func oversizedRegionFailsBeforeNativeStreamSetup() async {
        let source = ScrollFrameSource()
        let region = CaptureRegion(displayID: 0, rect: CGRect(x: 0, y: 0, width: 5_000, height: 5_000), scale: 1)
        do {
            try await source.start(region: region)
            Issue.record("An over-budget region must be rejected before starting ScreenCaptureKit.")
        } catch CaptureError.invalidRegion {
            #expect(!source.hasPendingFrames)
        } catch {
            Issue.record("Expected invalidRegion before native setup, got \(error).")
        }
    }
}
