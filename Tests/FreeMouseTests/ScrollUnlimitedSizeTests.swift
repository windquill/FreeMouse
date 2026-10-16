import AppKit
import Foundation
import ImageIO
import Testing
@testable import FreeMouse

@Suite(.serialized)
struct ScrollUnlimitedSizeTests {
    // These are real viewport appends, not a test-only height override. Width 96
    // isolates the old height cap; width 960 also crosses the former capture,
    // editor-export, and image-import pixel caps.
    @Test(arguments: [96, 960])
    func continuousCaptureCrossesFormerLimitsAndExportsLosslessPNG(width: Int) throws {
        let stitcher = ScrollStitcher()
        let viewportHeight = 480
        let advance = 320
        let steps = 218
        _ = try stitcher.append(frame(start: 0, width: width, height: viewportHeight))
        for step in 1...steps {
            try autoreleasepool {
                let result = try stitcher.append(frame(start: step * advance, width: width, height: viewportHeight))
                #expect(result == .appended(advance))
            }
        }
        let expectedHeight = viewportHeight + steps * advance
        #expect(expectedHeight == 70_240)
        #expect(stitcher.totalHeight == expectedHeight)
        #expect(stitcher.frameCount == steps + 1)
        let image = try #require(stitcher.image)
        #expect(image.width == width)
        #expect(image.height == expectedHeight)
        #expect(matchesDocument(image))
        let preview = try #require(stitcher.preview())
        #expect(preview.width <= 180)
        #expect(preview.height <= 420)

        // Use the editor's actual render + PNG encoding path. Decode again and
        // verify every pixel, so a truncated or downscaled export cannot pass.
        let rendered = try #require(EditorRasterizer.render(image: image, annotations: []))
        let png = try #require(NSBitmapImageRep(cgImage: rendered).representation(using: .png, properties: [:]))
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == width)
        #expect(decoded.height == expectedHeight)
        #expect(matchesDocument(decoded))

        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("FreeMouse-long-size-\(UUID().uuidString).png")
        try png.write(to: file, options: .withoutOverwriting)
        defer { try? FileManager.default.removeItem(at: file) }
        let reopened = try FileTools.loadImage(file)
        #expect(reopened.width == width)
        #expect(reopened.height == expectedHeight)
        #expect(matchesDocument(reopened))
    }

    @Test func editorAcceptsImagesBeyondItsFormerPixelLimit() {
        #expect(EditorRasterizer.isSafeSize(width: 2_016, height: 60_000))
        #expect(EditorRasterizer.isSafeSize(width: 1_000, height: 60_001))
    }

    @Test func editorStillRejectsInvalidDimensionsAndRGBAIntegerOverflow() {
        #expect(!EditorRasterizer.isSafeSize(width: 0, height: 100))
        #expect(!EditorRasterizer.isSafeSize(width: 100, height: -1))
        #expect(!EditorRasterizer.isSafeSize(width: Int.max, height: 2))
        #expect(!EditorRasterizer.isSafeSize(width: Int.max / 4 + 1, height: 1))
        #expect(EditorRasterizer.isSafeSize(width: Int.max / 4, height: 1))
    }

    @Test func explicitCallerBudgetStillPreservesAlreadyCapturedPixels() throws {
        let stitcher = ScrollStitcher(maxPixels: 96 * 600)
        _ = try stitcher.append(frame(start: 0, width: 96, height: 480))
        #expect(throws: (any Error).self) {
            try stitcher.append(frame(start: 320, width: 96, height: 480))
        }
        #expect(stitcher.totalHeight == 480)
        #expect(matchesDocument(try #require(stitcher.image)))
    }

    private func color(row: Int, column: Int) -> (UInt8, UInt8, UInt8) {
        let value = UInt32(truncatingIfNeeded: (row &* 1_664_525) ^ (column &* 1_013_904_223) ^ 7)
        return (UInt8(truncatingIfNeeded: value ^ (value >> 13)),
                UInt8(truncatingIfNeeded: (value >> 8) ^ UInt32(truncatingIfNeeded: row &* 47)),
                UInt8(truncatingIfNeeded: (value >> 16) ^ UInt32(truncatingIfNeeded: column &* 71)))
    }

    private func frame(start: Int, width: Int, height: Int) -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let rgb = color(row: start + y, column: x)
                let index = (y * width + x) * 4
                bytes[index] = rgb.0
                bytes[index + 1] = rgb.1
                bytes[index + 2] = rgb.2
            }
        }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent)!
    }

    private func matchesDocument(_ image: CGImage) -> Bool {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard drawn else { return false }
        for y in 0..<image.height {
            for x in 0..<image.width {
                let rgb = color(row: y, column: x)
                let index = (y * image.width + x) * 4
                if bytes[index] != rgb.0 || bytes[index + 1] != rgb.1 ||
                   bytes[index + 2] != rgb.2 || bytes[index + 3] != 255 { return false }
            }
        }
        return true
    }
}
