import CoreGraphics
import Foundation
import Testing
@testable import FreeMouse

struct ScrollFrameSourceTests {
    private final class Lifetime {}
    private final class WeakLifetime {
        weak var value: Lifetime?
        init(_ value: Lifetime) { self.value = value }
    }

    private func fixture() -> (CGImage, Lifetime) {
        let lifetime = Lifetime()
        let bytes = UnsafeMutablePointer<UInt8>.allocate(capacity: 4)
        bytes.initialize(repeating: 255, count: 4)
        let info = Unmanaged.passRetained(lifetime).toOpaque()
        let provider = CGDataProvider(dataInfo: info, data: bytes, size: 4) { info, data, _ in
            data.assumingMemoryBound(to: UInt8.self).deallocate()
            if let info { Unmanaged<Lifetime>.fromOpaque(info).release() }
        }!
        let image = CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        return (image, lifetime)
    }

    // Every retained bridge frame must be released after ordered consumption.
    @Test func queuedFramesReleaseImagesAsTheyAreConsumed() throws {
        let buffer = ScrollFrameBuffer(maxFrames: 8, maxPixels: 8)
        let token = buffer.begin()
        var lifetimes: [WeakLifetime] = []
        var sequence: UInt64 = 0
        for start in stride(from: 1, through: 200, by: 8) {
            let end = min(200, start + 7)
            for timestamp in start...end {
                autoreleasepool {
                    let (image, lifetime) = fixture()
                    lifetimes.append(WeakLifetime(lifetime))
                    buffer.publish(image, timestamp: TimeInterval(timestamp), token: token)
                }
            }
            #expect(lifetimes.filter { $0.value != nil }.count == end - start + 1)
            for timestamp in start...end {
                try autoreleasepool {
                    let frame = try #require(buffer.nextFrame(after: sequence))
                    #expect(frame.sequence == UInt64(timestamp))
                    #expect(frame.timestamp == TimeInterval(timestamp))
                    sequence = frame.sequence
                }
            }
            #expect(lifetimes.filter { $0.value != nil }.isEmpty)
            #expect(buffer.nextFrame(after: sequence) == nil)
            #expect(buffer.failure == nil)
        }
        #expect(sequence == 200)
        #expect(buffer.nextFrame(after: 500) == nil)
    }

    @Test func pressureReleasesRejectedImagesAndRetainsAcceptedTailUntilConsumed() throws {
        let buffer = ScrollFrameBuffer(maxFrames: 2, maxPixels: 8)
        let token = buffer.begin()
        var lifetimes: [WeakLifetime] = []
        for timestamp in 1...3 {
            autoreleasepool {
                let (image, lifetime) = fixture()
                lifetimes.append(WeakLifetime(lifetime))
                buffer.publish(image, timestamp: TimeInterval(timestamp), token: token)
            }
        }
        #expect(buffer.failure == nil)
        #expect(lifetimes.filter { $0.value != nil }.count == 2)
        #expect(lifetimes[2].value == nil)
        var sequence: UInt64 = 0
        for time in 1...2 {
            try autoreleasepool {
                let frame = try #require(buffer.nextFrame(after: sequence))
                #expect(frame.timestamp == Double(time))
                sequence = frame.sequence
            }
        }
        #expect(lifetimes.filter { $0.value != nil }.isEmpty)
    }

    // A callback arriving after stop must neither retain pixels nor increment sequence.
    @Test func invalidatedSessionCannotPublishFrames() throws {
        let buffer = ScrollFrameBuffer()
        let old = buffer.begin()
        let (image, _) = fixture()
        buffer.publish(image, timestamp: 1, token: old)
        buffer.invalidate(token: old)
        buffer.publish(image, timestamp: 2, token: old)
        #expect(buffer.latestFrame(after: 0) == nil)
        let current = buffer.begin()
        buffer.publish(image, timestamp: 3, token: old)
        buffer.publish(image, timestamp: 4, token: current)
        let frame = try #require(buffer.latestFrame(after: 1))
        #expect(frame.sequence == 2)
        #expect(frame.timestamp == 4)
    }

    // An old delegate error must never invalidate a later session.
    @Test func failureStopsPublicationAndIgnoresStaleDelegates() throws {
        let buffer = ScrollFrameBuffer()
        let old = buffer.begin()
        let (image, _) = fixture()
        buffer.publish(image, timestamp: 1, token: old)
        buffer.fail("stream failed", token: old)
        #expect(buffer.failure == "stream failed")
        buffer.publish(image, timestamp: 2, token: old)
        #expect(buffer.latestFrame(after: 0) == nil)
        let current = buffer.begin()
        #expect(buffer.failure == nil)
        buffer.fail("stale failure", token: old)
        buffer.invalidate(token: old)
        buffer.publish(image, timestamp: 3, token: current)
        #expect(buffer.failure == nil)
        #expect(try #require(buffer.latestFrame(after: 1)).timestamp == 3)
    }
}
