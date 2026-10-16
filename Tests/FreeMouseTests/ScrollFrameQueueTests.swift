import CoreGraphics
import Foundation
import Testing
@testable import FreeMouse

struct ScrollFrameQueueTests {
    private func image(marker: UInt8 = 1) throws -> CGImage {
        let width = 20, height = 40
        var bytes = [UInt8](repeating: marker, count: width * height * 4)
        for index in stride(from: 3, to: bytes.count, by: 4) { bytes[index] = 255 }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        return try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    @Test func queuedNativeFramesAreConsumedInOrderWithoutJumpingToNewest() throws {
        let buffer = ScrollFrameBuffer(maxFrames: 8, maxPixels: 8 * 800)
        let token = buffer.begin()
        for value in 1...3 { buffer.publish(try image(marker: UInt8(value)), timestamp: Double(value), token: token) }
        let first = try #require(buffer.nextFrame(after: 0))
        #expect(first.sequence == 1)
        #expect(first.timestamp == 1)
        let second = try #require(buffer.nextFrame(after: first.sequence))
        #expect(second.sequence == 2)
        #expect(second.timestamp == 2)
        let third = try #require(buffer.nextFrame(after: second.sequence))
        #expect(third.sequence == 3)
        #expect(third.timestamp == 3)
        #expect(buffer.nextFrame(after: third.sequence) == nil)
        #expect(buffer.failure == nil)
    }

    @Test func invalidatedProducerCannotAffectANewQueue() throws {
        let buffer = ScrollFrameBuffer(maxFrames: 8, maxPixels: 8 * 800)
        let old = buffer.begin()
        buffer.publish(try image(), timestamp: 1, token: old)
        buffer.invalidate(token: old)
        let current = buffer.begin()
        buffer.publish(try image(), timestamp: 2, token: current)
        buffer.publish(try image(), timestamp: 99, token: old)
        buffer.fail("stale failure", token: old)
        buffer.discardPending(token: old)
        buffer.sealPreservingPending(token: old)
        let frame = try #require(buffer.nextFrame(after: 0))
        #expect(frame.sequence == 2)
        #expect(frame.timestamp == 2)
        #expect(buffer.failure == nil)
        #expect(buffer.isActive(token: current))
        #expect(buffer.nextFrame(after: frame.sequence) == nil)
    }

    @Test func pauseDiscardDropsPendingFramesAndAcceptsFreshFramesAfterResume() throws {
        let buffer = ScrollFrameBuffer(maxFrames: 8, maxPixels: 8 * 800)
        let token = buffer.begin()
        buffer.publish(try image(), timestamp: 1, token: token)
        buffer.publish(try image(), timestamp: 2, token: token)
        buffer.discardPending(token: token)
        #expect(buffer.nextFrame(after: 0) == nil)
        #expect(buffer.isActive(token: token))
        buffer.publish(try image(), timestamp: 3, token: token)
        let fresh = try #require(buffer.nextFrame(after: 0))
        #expect(fresh.sequence == 3)
        #expect(fresh.timestamp == 3)
        #expect(buffer.nextFrame(after: fresh.sequence) == nil)
    }

    @Test func finishSealStopsPublicationButPreservesTheOrderedTailForDraining() throws {
        let buffer = ScrollFrameBuffer(maxFrames: 8, maxPixels: 8 * 800)
        let token = buffer.begin()
        buffer.publish(try image(), timestamp: 1, token: token)
        buffer.publish(try image(), timestamp: 2, token: token)
        buffer.sealPreservingPending(token: token)
        #expect(!buffer.isActive(token: token))
        buffer.publish(try image(), timestamp: 3, token: token)
        // A native stop callback must not erase a tail that was already sealed.
        buffer.fail("late native stop", token: token)
        buffer.invalidate(token: token)
        #expect(buffer.failure == nil)
        let first = try #require(buffer.nextFrame(after: 0))
        #expect(first.sequence == 1)
        let last = try #require(buffer.nextFrame(after: first.sequence))
        #expect(last.sequence == 2)
        #expect(last.timestamp == 2)
        #expect(buffer.nextFrame(after: last.sequence) == nil)
    }

    @Test func frameCapacityPressurePreservesTheBridgeAndCanRecover() throws {
        let buffer = ScrollFrameBuffer(maxFrames: 2, maxPixels: 8 * 800)
        let token = buffer.begin()
        buffer.publish(try image(), timestamp: 1, token: token)
        buffer.publish(try image(), timestamp: 2, token: token)
        #expect(buffer.failure == nil)
        buffer.publish(try image(), timestamp: 3, token: token)
        #expect(buffer.failure == nil)
        #expect(buffer.isActive(token: token))
        let first = try #require(buffer.nextFrame(after: 0))
        let second = try #require(buffer.nextFrame(after: first.sequence))
        #expect(first.timestamp == 1)
        #expect(second.timestamp == 2)
        #expect(buffer.lastDeferredSequence > second.sequence)
    }

    @Test func pixelCapacityIsEnforcedIndependentlyOfFrameCount() throws {
        let buffer = ScrollFrameBuffer(maxFrames: 8, maxPixels: 1_599)
        let token = buffer.begin()
        buffer.publish(try image(), timestamp: 1, token: token)
        #expect(buffer.failure == nil)
        buffer.publish(try image(), timestamp: 2, token: token)
        #expect(buffer.failure == nil)
        #expect(buffer.isActive(token: token))
        #expect(try #require(buffer.nextFrame(after: 0)).timestamp == 1)
        buffer.publish(try image(), timestamp: 3, token: token)
        #expect(try #require(buffer.nextFrame(after: 1)).timestamp == 3)
    }

    @Test func consumptionReturnsItsPixelBudgetForTheNextNativeFrame() throws {
        let buffer = ScrollFrameBuffer(maxFrames: 8, maxPixels: 800)
        let token = buffer.begin()
        buffer.publish(try image(), timestamp: 1, token: token)
        let first = try #require(buffer.nextFrame(after: 0))
        buffer.publish(try image(), timestamp: 2, token: token)
        #expect(buffer.failure == nil)
        let second = try #require(buffer.nextFrame(after: first.sequence))
        #expect(second.sequence == 2)
        #expect(second.timestamp == 2)
    }

    @Test func discardReturnsItsPixelBudgetWithoutClosingTheProducer() throws {
        let buffer = ScrollFrameBuffer(maxFrames: 8, maxPixels: 800)
        let token = buffer.begin()
        buffer.publish(try image(), timestamp: 1, token: token)
        buffer.discardPending(token: token)
        buffer.publish(try image(), timestamp: 2, token: token)
        #expect(buffer.failure == nil)
        let fresh = try #require(buffer.nextFrame(after: 0))
        #expect(fresh.sequence == 2)
        #expect(fresh.timestamp == 2)
        #expect(buffer.isActive(token: token))
    }
}
