import CoreGraphics
import Foundation
import Testing
@testable import FreeMouse

struct ScrollBackpressureTests {
    private func image(width: Int = 20, height: Int = 40) throws -> CGImage {
        let bytes = Data(repeating: 255, count: width * height * 4)
        let provider = try #require(CGDataProvider(data: bytes as CFData))
        return try #require(CGImage(width: width, height: height, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    // A transient full queue must not erase already accepted bridge frames.
    @Test func fullQueueRetainsItsOrderedTailAndKeepsTheProducerAlive() throws {
        let buffer = ScrollFrameBuffer(maxFrames: 2, maxPixels: 6_400)
        let token = buffer.begin(), frame = try image()
        for time in 1...3 { buffer.publish(frame, timestamp: Double(time), token: token) }
        #expect(buffer.failure == nil)
        #expect(buffer.isActive(token: token))
        let first = try #require(buffer.nextFrame(after: 0))
        let second = try #require(buffer.nextFrame(after: first.sequence))
        #expect(first.timestamp == 1)
        #expect(second.timestamp == 2)
        #expect(buffer.nextFrame(after: second.sequence) == nil)
    }

    @Test func producerResumesAfterTheConsumerCatchesUp() throws {
        let buffer = ScrollFrameBuffer(maxFrames: 2, maxPixels: 6_400)
        let token = buffer.begin(), frame = try image()
        for time in 1...3 { buffer.publish(frame, timestamp: Double(time), token: token) }
        var sequence: UInt64 = 0
        while let next = buffer.nextFrame(after: sequence) { sequence = next.sequence }
        buffer.publish(frame, timestamp: 4, token: token)
        let recovered = try #require(buffer.nextFrame(after: sequence))
        #expect(recovered.timestamp == 4)
        #expect(buffer.failure == nil)
    }

    @Test func pixelPressureDoesNotBecomeAPermanentCaptureFailure() throws {
        let buffer = ScrollFrameBuffer(maxFrames: 8, maxPixels: 1_599)
        let token = buffer.begin(), frame = try image()
        buffer.publish(frame, timestamp: 1, token: token)
        buffer.publish(frame, timestamp: 2, token: token)
        #expect(buffer.failure == nil)
        let first = try #require(buffer.nextFrame(after: 0))
        buffer.publish(frame, timestamp: 3, token: token)
        #expect(try #require(buffer.nextFrame(after: first.sequence)).timestamp == 3)
    }

    @Test func finishDuringPressureStillDrainsEveryAcceptedBridge() throws {
        let buffer = ScrollFrameBuffer(maxFrames: 2, maxPixels: 6_400)
        let token = buffer.begin(), frame = try image()
        for time in 1...3 { buffer.publish(frame, timestamp: Double(time), token: token) }
        buffer.sealPreservingPending(token: token)
        buffer.publish(frame, timestamp: 4, token: token)
        buffer.fail("late callback", token: token)
        let first = try #require(buffer.nextFrame(after: 0))
        let second = try #require(buffer.nextFrame(after: first.sequence))
        #expect(first.timestamp == 1)
        #expect(second.timestamp == 2)
        #expect(buffer.failure == nil)
        #expect(buffer.nextFrame(after: second.sequence) == nil)
    }

    @Test func oneFrameLargerThanTheEntireBudgetStillFailsExplicitly() throws {
        let buffer = ScrollFrameBuffer(maxFrames: 8, maxPixels: 799)
        let token = buffer.begin()
        buffer.publish(try image(), timestamp: 1, token: token)
        #expect(buffer.failure != nil)
        #expect(!buffer.isActive(token: token))
        #expect(buffer.nextFrame(after: 0) == nil)
    }

    @Test func automaticScrollHoldUsesHighAndLowWatermarks() throws {
        let buffer = ScrollFrameBuffer(maxFrames: 8, maxPixels: 64_000)
        let token = buffer.begin(), frame = try image()
        for time in 1...4 { buffer.publish(frame, timestamp: Double(time), token: token) }
        #expect(buffer.isBackpressured)
        let first = try #require(buffer.nextFrame(after: 0))
        #expect(buffer.isBackpressured)
        _ = try #require(buffer.nextFrame(after: first.sequence))
        #expect(!buffer.isBackpressured)
    }

    @Test func equalOrReversedTimestampsCannotHideADeferredTail() throws {
        let buffer = ScrollFrameBuffer(maxFrames: 1, maxPixels: 800)
        let token = buffer.begin(), frame = try image()
        buffer.publish(frame, timestamp: 20, token: token)
        buffer.publish(frame, timestamp: 20, token: token)
        buffer.publish(frame, timestamp: 1, token: token)
        let accepted = try #require(buffer.nextFrame(after: 0))
        #expect(accepted.sequence == 1)
        #expect(buffer.lastDeferredSequence == 3)
        buffer.publish(frame, timestamp: 0, token: token)
        let recovered = try #require(buffer.nextFrame(after: accepted.sequence))
        #expect(recovered.sequence == 4)
        #expect(recovered.sequence > buffer.lastDeferredSequence)
    }

    @Test func sealedPressureCannotBeChangedByLateNativeCallbacks() throws {
        let buffer = ScrollFrameBuffer(maxFrames: 1, maxPixels: 800)
        let token = buffer.begin(), frame = try image()
        buffer.publish(frame, timestamp: 1, token: token)
        buffer.publish(frame, timestamp: 2, token: token)
        buffer.sealPreservingPending(token: token)
        buffer.publish(frame, timestamp: 3, token: token)
        buffer.fail("late failure", token: token)
        buffer.discardPending(token: token)
        #expect(buffer.lastDeferredSequence == 2)
        #expect(try #require(buffer.nextFrame(after: 0)).timestamp == 1)
        #expect(buffer.lastDeferredSequence == 2)
        #expect(buffer.failure == nil)
    }

    @Test func explicitPauseDiscardClearsPressureAndAbandonsItsOldGap() throws {
        let buffer = ScrollFrameBuffer(maxFrames: 1, maxPixels: 800)
        let token = buffer.begin(), frame = try image()
        buffer.publish(frame, timestamp: 1, token: token)
        buffer.publish(frame, timestamp: 2, token: token)
        buffer.discardPending(token: token)
        #expect(!buffer.isBackpressured)
        #expect(buffer.lastDeferredSequence == 0)
        buffer.publish(frame, timestamp: 3, token: token)
        #expect(try #require(buffer.nextFrame(after: 0)).sequence == 3)
    }

    @Test func oldSessionCannotChangeANewSessionsPressureOrGap() throws {
        let buffer = ScrollFrameBuffer(maxFrames: 1, maxPixels: 800)
        let old = buffer.begin(), frame = try image()
        buffer.publish(frame, timestamp: 1, token: old)
        buffer.publish(frame, timestamp: 2, token: old)
        let current = buffer.begin()
        buffer.publish(frame, timestamp: 99, token: old)
        buffer.discardPending(token: old)
        #expect(!buffer.isBackpressured)
        #expect(buffer.lastDeferredSequence == 0)
        buffer.publish(frame, timestamp: 3, token: current)
        #expect(try #require(buffer.nextFrame(after: 0)).timestamp == 3)
        #expect(buffer.failure == nil)
    }

    @Test func continuousBurstsCanRecoverForManyPagesWithoutClosingTheStream() throws {
        let buffer = ScrollFrameBuffer(maxFrames: 8, maxPixels: 6_400)
        let token = buffer.begin(), frame = try image()
        var consumed: UInt64 = 0
        var acceptedFrames = 0
        for burst in 0..<100 {
            for sample in 0..<12 {
                buffer.publish(frame, timestamp: Double(burst * 12 + sample), token: token)
            }
            var expectedTime = burst * 12
            while let next = buffer.nextFrame(after: consumed) {
                #expect(next.timestamp == Double(expectedTime))
                #expect(next.sequence > consumed)
                expectedTime += 1; acceptedFrames += 1; consumed = next.sequence
            }
            #expect(expectedTime == burst * 12 + 8)
            #expect(buffer.isActive(token: token))
            #expect(buffer.failure == nil)
        }
        #expect(acceptedFrames == 800)
        buffer.publish(frame, timestamp: 1_200, token: token)
        let recovered = try #require(buffer.nextFrame(after: consumed))
        #expect(recovered.sequence == 1_201)
        #expect(recovered.sequence > buffer.lastDeferredSequence)
    }

    @Test func processingBacklogDoesNotExpireTheAutomaticScrollProgressTimer() {
        var flow = ScrollCaptureFlow()
        flow.started(at: 0); flow.accepted(at: 0); flow.setAutomatic(true, at: 0)
        flow.processingBacklog(at: 3)
        let expired = flow.unchanged(at: 3.1)
        #expect(!expired)
        #expect(flow.shouldScroll)
        let expiredWithoutFurtherWork = flow.unchanged(at: 4.5)
        #expect(expiredWithoutFurtherWork)
        #expect(!flow.shouldScroll)
    }

    @Test func backlogWorkCannotEnableAutomaticScrollingOrResumeAUserPause() {
        var flow = ScrollCaptureFlow()
        flow.started(at: 0); flow.accepted(at: 0)
        flow.processingBacklog(at: 3)
        #expect(flow.mode == .manual)
        flow.setAutomatic(true, at: 4); flow.togglePause(at: 5)
        flow.processingBacklog(at: 9)
        #expect(flow.phase == .paused)
        #expect(!flow.shouldScroll)
    }

    @Test func reported1897By1409OverflowRecoversWithoutErasingEightFrames() throws {
        let buffer = ScrollFrameBuffer()
        let token = buffer.begin(), frame = try image(width: 1897, height: 1409)
        for time in 1...9 { buffer.publish(frame, timestamp: Double(time), token: token) }
        #expect(buffer.failure == nil)
        #expect(buffer.isActive(token: token))
        var sequence: UInt64 = 0
        for time in 1...8 {
            let accepted = try #require(buffer.nextFrame(after: sequence))
            #expect(accepted.timestamp == Double(time))
            sequence = accepted.sequence
        }
        #expect(buffer.lastDeferredSequence == 9)
        buffer.publish(frame, timestamp: 10, token: token)
        let recovered = try #require(buffer.nextFrame(after: sequence))
        #expect(recovered.sequence == 10)
        #expect(recovered.sequence > buffer.lastDeferredSequence)
        #expect(buffer.failure == nil)
    }
}
