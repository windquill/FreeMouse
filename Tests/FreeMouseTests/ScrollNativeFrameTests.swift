import Testing
import AppKit
import Foundation
import ImageIO

@testable import FreeMouse

@MainActor
struct ScrollNativeFrameTests {
    @Test
    func normalNativeFramesAppend59Pixels() throws {
        try expectNativeAppend(
            referenceName: "normal-reference", nextName: "normal-next", offset: 59
        )
    }

    @Test
    func fastNativeFramesAppend499Pixels() throws {
        try expectNativeAppend(
            referenceName: "fast-reference", nextName: "fast-next", offset: 499
        )
    }

    @Test
    func stationaryBodyWithReplacedNativeToolbarDoesNotGrow() throws {
        let reference = try fixture("normal-reference")
        let toolbarSource = try fixture("normal-incomplete-output")
        #expect(toolbarSource.width == reference.width)
        var pixels = try rgba(reference)
        let toolbarPixels = try rgba(toolbarSource)
        let toolbarByteCount = 64 * reference.width * 4
        pixels.replaceSubrange(
            0..<toolbarByteCount, with: toolbarPixels.prefix(toolbarByteCount)
        )
        let candidate = try makeImage(
            width: reference.width, height: reference.height, pixels: pixels
        )
        try expectRejectedOrDuplicate(reference: reference, candidate: candidate)
    }

    @Test(arguments: [1, 8, 32])
    func stationaryBodyWithToolbarBrightnessChangesDoesNotGrow(delta: Int) throws {
        let reference = try fixture("normal-reference")
        var pixels = try rgba(reference)
        for y in 8..<56 {
            for x in 16..<144 {
                let index = (y * reference.width + x) * 4
                for channel in 0..<3 {
                    pixels[index + channel] = UInt8(
                        min(255, Int(pixels[index + channel]) + delta)
                    )
                }
            }
        }
        let candidate = try makeImage(
            width: reference.width, height: reference.height, pixels: pixels
        )
        try expectRejectedOrDuplicate(reference: reference, candidate: candidate)
    }

    @Test
    func stationaryBodyWithOneLevelBrightnessDriftDoesNotGrow() throws {
        let reference = try fixture("normal-reference")
        var pixels = try rgba(reference)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            guard pixels[index + 3] == 255 else { continue }
            for channel in 0..<3 {
                pixels[index + channel] = UInt8(
                    min(255, Int(pixels[index + channel]) + 1)
                )
            }
        }
        let candidate = try makeImage(
            width: reference.width, height: reference.height, pixels: pixels
        )
        try expectRejectedOrDuplicate(reference: reference, candidate: candidate)
    }

    @Test
    func smoothGradientWithUniformBrightnessDriftDoesNotGrow() throws {
        let reference = try syntheticImage { _, y in
            let level = UInt8(40 + y * 120 / 863)
            return (level, level + 10, level + 20)
        }
        let candidate = try syntheticImage { _, y in
            let level = UInt8(48 + y * 120 / 863)
            return (level, level + 10, level + 20)
        }
        try expectRejectedOrDuplicate(reference: reference, candidate: candidate)
    }

    @Test
    func periodicColorContentDoesNotAcceptAmbiguousTranslation() throws {
        let palette: [(UInt8, UInt8, UInt8)] = [
            (230, 40, 55), (30, 180, 210), (245, 190, 35), (110, 65, 215),
            (35, 205, 90), (225, 75, 180), (40, 95, 230), (235, 135, 45)
        ]
        let reference = try syntheticImage { x, y in
            guard y >= 64 else { return (35, 36, 40) }
            let row = (y - 64) % 96
            return palette[(x / 32 + row / 12) % palette.count]
        }
        let candidate = try syntheticImage { x, y in
            guard y >= 64 else { return (35, 36, 40) }
            let row = (y - 64 + 48) % 96
            return palette[(x / 32 + row / 12) % palette.count]
        }
        try expectRejectedOrDuplicate(reference: reference, candidate: candidate)
    }

    @Test
    func unrelatedNativeContentIsRejectedWithoutChangingOutput() throws {
        let reference = try fixture("normal-reference")
        let candidate = try fixture("fast-next")
        try expectRejectedOrDuplicate(
            reference: reference, candidate: candidate, requiresNoOverlap: true
        )
    }

    private func fixture(_ name: String) throws -> CGImage {
        let url = try #require(Bundle.module.url(
            forResource: name, withExtension: "png", subdirectory: "ScrollNative121"
        ))
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private func expectNativeAppend(
        referenceName: String, nextName: String, offset: Int
    ) throws {
        let reference = try fixture(referenceName)
        let next = try fixture(nextName)
        #expect(reference.width == 800)
        #expect(reference.height == 864)
        #expect(next.width == 800)
        #expect(next.height == 864)
        let matcher = ScrollStitcher()
        let firstResult = try matcher.append(reference)
        #expect(firstResult == .appended(864))
        let result = try matcher.append(next)
        #expect(result == .appended(offset))
        #expect(matcher.totalHeight == 864 + offset)
        #expect(matcher.frameCount == 2)
        let output = try #require(matcher.image)
        #expect(output.width == 800)
        #expect(output.height == 864 + offset)

        // These fixtures have a known 64-pixel fixed toolbar. The next frame
        // replaces the provisional overlap, including its subpixel rendering.
        let referencePixels = try rgba(reference)
        let nextPixels = try rgba(next)
        let expected = Data(referencePixels.prefix((64 + offset) * 800 * 4))
            + Data(nextPixels.dropFirst(64 * 800 * 4))
        let actual = Data(try rgba(output))
        #expect(actual == expected)
    }

    private func expectRejectedOrDuplicate(
        reference: CGImage, candidate: CGImage, requiresNoOverlap: Bool = false
    ) throws {
        let matcher = ScrollStitcher()
        let firstResult = try matcher.append(reference)
        #expect(firstResult == .appended(reference.height))
        let previousHeight = matcher.totalHeight
        let previousFrameCount = matcher.frameCount
        let previousData = try #require(matcher.image?.dataProvider?.data) as Data
        do {
            let result = try matcher.append(candidate)
            #expect(!requiresNoOverlap, "Unrelated content must throw CaptureError.noOverlap")
            #expect(result == .duplicate)
        } catch CaptureError.noOverlap {
            // An ambiguous or unrelated frame may be rejected safely.
        }
        #expect(matcher.totalHeight == previousHeight)
        #expect(matcher.frameCount == previousFrameCount)
        let currentData = try #require(matcher.image?.dataProvider?.data) as Data
        #expect(currentData == previousData)
    }

    private func rgba(_ image: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(
                data: buffer.baseAddress,
                width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            ))
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(
                x: 0, y: 0, width: image.width, height: image.height
            ))
        }
        return pixels
    }

    private func makeImage(width: Int, height: Int, pixels: [UInt8]) throws -> CGImage {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        return try #require(CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue:
                CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            ),
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent
        ))
    }

    private func syntheticImage(
        _ pixel: (Int, Int) -> (UInt8, UInt8, UInt8)
    ) throws -> CGImage {
        var pixels = [UInt8](repeating: 255, count: 800 * 864 * 4)
        for y in 0..<864 {
            for x in 0..<800 {
                let (red, green, blue) = pixel(x, y)
                let index = (y * 800 + x) * 4
                pixels[index] = red
                pixels[index + 1] = green
                pixels[index + 2] = blue
            }
        }
        return try makeImage(width: 800, height: 864, pixels: pixels)
    }
}
