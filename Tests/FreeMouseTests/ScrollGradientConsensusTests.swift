import CoreGraphics
import Foundation
import Testing
@testable import FreeMouse

@MainActor
struct ScrollGradientConsensusTests {
    private let width = 320
    private let viewportHeight = 600

    @Test func rerasterizedConversationContinuesForThirtyViewportHeightsWithoutChangingOutputPixels() throws {
        let matcher = ScrollStitcher()
        var previous = try viewport(offset: 0, phase: 0)
        let first = try matcher.append(previous)
        #expect(first == .appended(600))
        var committed = Data()
        var offset = 0
        let advances = [13, 41, 100, 180]
        let phases = [0.18, 0.07, 0.27, 0.0]
        // 55 cycles advance 18,370 pixels, independently specified by the
        // document generator. Incorrect offsets, missing steps, or blurred
        // exports must all fail even if the matcher still reports success.
        for step in 0..<220 {
            let advance = advances[step % advances.count]
            committed.append(contentsOf: try bytes(previous).prefix(advance * width * 4))
            offset += advance
            let next = try viewport(offset: offset, phase: phases[step % phases.count])
            let result: ScrollStitcher.AppendResult
            do { result = try matcher.append(next) }
            catch { throw SequenceFailure(step: step, offset: offset, cause: error) }
            #expect(result == .appended(advance), "step \(step), document offset \(offset)")
            #expect(matcher.totalHeight == viewportHeight + offset)
            previous = next
        }
        #expect(offset == 18_370)
        #expect(matcher.totalHeight == 18_970)
        #expect(matcher.frameCount == 221)
        committed.append(contentsOf: try bytes(previous))
        let output = try #require(matcher.image)
        #expect(output.width == width && output.height == 18_970)
        #expect(Data(try bytes(output)) == committed)
    }

    @Test func aSmallMatchingPatchCannotJoinOtherwiseUnrelatedText() throws {
        try expectNoGrowth(
            reference: viewport(offset: 0, phase: 0),
            next: viewport(offset: 100, phase: 0.18, salt: 0xD6E8FEB86659FD93,
                           commonPatch: CGRect(x: 96, y: 180, width: 64, height: 50))
        )
    }

    @Test func aSingleMatchingHorizontalBandCannotJoinOtherwiseUnrelatedText() throws {
        try expectNoGrowth(
            reference: viewport(offset: 0, phase: 0),
            next: viewport(offset: 100, phase: 0.18, salt: 0xD6E8FEB86659FD93,
                           commonPatch: CGRect(x: 0, y: 140, width: width, height: 140))
        )
    }

    @Test func unrelatedTextWithSimilarLineLayoutCannotEstablishMotion() throws {
        try expectNoGrowth(
            reference: viewport(offset: 0, phase: 0),
            next: viewport(offset: 100, phase: 0.18, salt: 0xD6E8FEB86659FD93)
        )
    }

    @Test func repeatedParagraphsRemainAmbiguousAfterRerasterization() throws {
        try expectNoGrowth(
            reference: viewport(offset: 0, phase: 0, linePeriod: 3),
            next: viewport(offset: 13, phase: 0.18, linePeriod: 3)
        )
    }

    @Test func stationaryTextWithChangedOverlayCannotGrow() throws {
        try expectNoGrowth(
            reference: viewport(offset: 0, phase: 0),
            next: viewport(offset: 0, phase: 0.18, overlayVariant: true)
        )
    }

    @Test func matchingGlyphSkeletonCannotForgiveLargeHighFrequencyInkChanges() throws {
        try expectNoGrowth(
            reference: viewport(offset: 0, phase: 0),
            next: viewport(offset: 100, phase: 0.18, alternatingInkDelta: 24)
        )
    }

    private func expectNoGrowth(reference: CGImage, next: CGImage) throws {
        let matcher = ScrollStitcher()
        let first = try matcher.append(reference)
        #expect(first == .appended(viewportHeight))
        let before = Data(try bytes(try #require(matcher.image)))
        do {
            let result = try matcher.append(next)
            #expect(result == .duplicate)
        } catch CaptureError.noOverlap {
            // An uncertain view can be refused, but never appended.
        }
        #expect(matcher.totalHeight == viewportHeight)
        #expect(matcher.frameCount == 1)
        let afterImage = try #require(matcher.image)
        #expect(Data(try bytes(afterImage)) == before)
    }

    // Generated document only; no user screenshot or conversation is bundled.
    // Pixel coordinates specify scrolling geometry. The sidebar ramp keeps
    // each top row distinct but lies outside the matcher's comparison body.
    // The last 80 rows simulate a viewport-fixed translucent composer.
    private func viewport(offset: Int, phase: Double, salt: UInt64 = 0,
                          commonPatch: CGRect? = nil, linePeriod: Int? = nil,
                          overlayVariant: Bool = false,
                          alternatingInkDelta: Int = 0) throws -> CGImage {
        var pixels = [UInt8](repeating: 255, count: width * viewportHeight * 4)
        for y in 0..<viewportHeight {
            for x in 0..<width {
                let worldY = offset + y
                let localSalt = commonPatch?.contains(CGPoint(x: x, y: y)) == true ? 0 : salt
                let current = documentLevel(x: x, y: worldY, salt: localSalt, linePeriod: linePeriod)
                let below = documentLevel(x: x, y: worldY + 1, salt: localSalt, linePeriod: linePeriod)
                var value = Double(current) * (1 - phase) + Double(below) * phase
                if current < 180 && x >= 32 {
                    value += Double((worldY & 1) == 0 ? alternatingInkDelta : -alternatingInkDelta)
                }
                if y >= viewportHeight - 80 && x >= 32 {
                    let alpha = min(1, Double(y - (viewportHeight - 80)) / 56)
                    value = value * (1 - alpha) + (overlayVariant ? 236 : 248) * alpha
                    if y > viewportHeight - 20 && (x - 32) % 71 < 23 {
                        value = overlayVariant ? 160 : 204
                    }
                }
                let pixel = UInt8(clamping: Int(value.rounded()))
                let index = (y * width + x) * 4
                pixels[index] = pixel
                pixels[index + 1] = pixel
                pixels[index + 2] = pixel
            }
        }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        return try #require(CGImage(width: width, height: viewportHeight,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func documentLevel(x: Int, y: Int, salt: UInt64, linePeriod: Int?) -> Int {
        if x < 32 { return linePeriod == nil ? y % 251 : 224 }
        let line = linePeriod.map { (y / 25) % $0 } ?? y / 25
        let localY = y % 25, localX = x % 9
        var code = UInt64(line + 1) &* 0x9E3779B97F4A7C15
        code ^= UInt64(x / 9 + 1) &* 0xBF58476D1CE4E5B9
        code ^= salt
        code ^= code >> 30
        code &*= 0x94D049BB133111EB
        code ^= code >> 27
        let horizontal = localY == 5 || localY == 11 || localY == 18
        let vertical = localX == 2 || (localX == 6 && (code & 2) != 0)
        let ink = x < width - 24 && localY >= 5 && localY <= 18
            && localX >= 2 && localX <= 6
            && (vertical || (horizontal && (code & 1) != 0))
        return ink ? 60 + Int((code >> 8) % 70) : 224
    }

    private func bytes(_ image: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(data: buffer.baseAddress,
                width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return pixels
    }

    private struct SequenceFailure: Error, CustomStringConvertible {
        let step: Int
        let offset: Int
        let cause: Error
        var description: String { "step \(step), document offset \(offset): \(cause)" }
    }
}
