import CoreGraphics
import Foundation
import Testing
@testable import FreeMouse

@MainActor
struct ScrollAntialiasEvidenceTests {
    private let width = 320
    private let viewportHeight = 600

    @Test func smallAlternatingRasterizationChangePreservesKnownScrollAndOriginalPixels() throws {
        let reference = try textViewport(offset: 0)
        let next = try textViewport(offset: 52, rasterizationDelta: 4)
        let stitcher = ScrollStitcher()
        let first = try stitcher.append(reference)
        #expect(first == .appended(viewportHeight))
        let appended = try stitcher.append(next)
        #expect(appended == .appended(52))
        #expect(stitcher.totalHeight == 652)
        #expect(stitcher.frameCount == 2)

        // Geometry is specified by the generated document, not estimated by
        // another matcher. Verification must never blur the exported pixels.
        let expected = Data(try bytes(reference).prefix(52 * width * 4))
            + Data(try bytes(next))
        let actual = Data(try bytes(try #require(stitcher.image)))
        #expect(actual == expected)
    }

    @Test func stationaryTextWithRasterizationChangeDoesNotGrow() throws {
        try expectNoGrowth(
            reference: textViewport(offset: 0),
            next: textViewport(offset: 0, rasterizationDelta: 4)
        )
    }

    @Test func unrelatedTextDoesNotGrow() throws {
        try expectNoGrowth(
            reference: textViewport(offset: 0),
            next: textViewport(offset: 52, salt: 0xD6E8FEB86659FD93,
                               rasterizationDelta: 4)
        )
    }

    @Test func periodicTextCannotEstablishUniqueScroll() throws {
        try expectNoGrowth(
            reference: textViewport(offset: 0, linePeriod: 3),
            next: textViewport(offset: 13, rasterizationDelta: 4, linePeriod: 3)
        )
    }

    @Test(arguments: [false, true])
    func nyquistRowsOrCheckerboardCannotGainMotionEvidenceByDisappearing(checkerboard: Bool) throws {
        let reference = try image { x, y in
            ((y + (checkerboard ? x : 0)) & 1) == 0 ? 60 : 200
        }
        let next = try image { x, y in
            ((y + (checkerboard ? x : 0)) & 1) == 0 ? 200 : 60
        }
        try expectNoGrowth(reference: reference, next: next)
    }

    @Test func sharedTextSkeletonCannotHideLargeAlternatingInkChanges() throws {
        // Only the ink changes, keeping the whole-frame average small. Its
        // substantial different high-frequency detail must not be forgiven
        // merely because both images share broad glyph positions.
        try expectNoGrowth(
            reference: textViewport(offset: 0),
            next: textViewport(offset: 52, rasterizationDelta: 24, inkOnly: true)
        )
    }

    private func expectNoGrowth(reference: CGImage, next: CGImage) throws {
        let stitcher = ScrollStitcher()
        let first = try stitcher.append(reference)
        #expect(first == .appended(viewportHeight))
        let before = Data(try bytes(try #require(stitcher.image)))
        do {
            let result = try stitcher.append(next)
            #expect(result == .duplicate)
        } catch CaptureError.noOverlap {
            // Uncertain rendering and unrelated images may be refused safely.
        }
        #expect(stitcher.totalHeight == viewportHeight)
        #expect(stitcher.frameCount == 1)
        let after = Data(try bytes(try #require(stitcher.image)))
        #expect(after == before)
    }

    // Self-contained generated glyph strokes: no user conversation or
    // diagnostic image is bundled. The 25px line pitch and per-line glyph code
    // establish independent known coordinates. Alternating one-pixel coverage
    // simulates a changed rasterization phase, without moving the geometry.
    private func textViewport(offset: Int, salt: UInt64 = 0,
                              rasterizationDelta: Int = 0, inkOnly: Bool = false,
                              linePeriod: Int? = nil) throws -> CGImage {
        try image { x, viewportY in
            let y = viewportY + offset
            let line = linePeriod.map { (y / 25) % $0 } ?? y / 25
            let localY = y % 25
            let localX = x % 9
            var code = UInt64(line + 1) &* 0x9E3779B97F4A7C15
            code ^= UInt64(x / 9 + 1) &* 0xBF58476D1CE4E5B9
            code ^= salt
            code ^= code >> 30
            code &*= 0x94D049BB133111EB
            code ^= code >> 27
            let horizontal = localY == 5 || localY == 11 || localY == 18
            let vertical = localX == 2 || (localX == 6 && (code & 2) != 0)
            let ink = x >= 24 && x < width - 24 && localY >= 5 && localY <= 18
                && localX >= 2 && localX <= 6
                && (vertical || (horizontal && (code & 1) != 0))
            let base = ink ? 60 + Int((code >> 8) % 70) : 224
            let change = (inkOnly && !ink) ? 0
                : (((y & 1) == 0 ? 1 : -1) * rasterizationDelta)
            return UInt8(base + change)
        }
    }

    private func image(_ level: (Int, Int) -> UInt8) throws -> CGImage {
        var pixels = [UInt8](repeating: 255, count: width * viewportHeight * 4)
        for y in 0..<viewportHeight {
            for x in 0..<width {
                let index = (y * width + x) * 4
                let value = level(x, y)
                pixels[index] = value
                pixels[index + 1] = value
                pixels[index + 2] = value
            }
        }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        return try #require(CGImage(
            width: width, height: viewportHeight, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent
        ))
    }

    private func bytes(_ image: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return pixels
    }
}
