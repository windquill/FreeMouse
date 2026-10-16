import Testing
import CoreGraphics
import Foundation
@testable import FreeMouse

struct CaptureTests {
    // A row contains deterministic non-periodic texture: matching the wrong
    // offset, appending a duplicate or accepting unrelated content breaks these.
    private func fixture(start: Int, width: Int = 96, height: Int = 120, seed: Int = 7, header: Int = 0, footer: Int = 0, period: Int = 0, zeroRed: Bool = false) -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let contentRow = period > 0 ? (start + y) % period : start + y
                let row = y < header ? y : (y >= height - footer ? 100_000 + y - (height - footer) : contentRow)
                let value = UInt32(truncatingIfNeeded: (row &* 1_664_525) ^ (x &* 1_013_904_223) ^ seed)
                let i = (y * width + x) * 4
                bytes[i] = zeroRed ? 0 : UInt8(truncatingIfNeeded: value ^ (value >> 13))
                bytes[i + 1] = UInt8(truncatingIfNeeded: (value >> 8) ^ UInt32(truncatingIfNeeded: row &* 47))
                bytes[i + 2] = UInt8(truncatingIfNeeded: (value >> 16) ^ UInt32(truncatingIfNeeded: x &* 71))
            }
        }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    @Test func testContinuousSmallScrollCanExceedTwoHundredFrames() throws {
        let stitcher = ScrollStitcher()
        for index in 0...220 { _ = try stitcher.append(fixture(start: index * 8)) }
        #expect(stitcher.frameCount == 221)
        #expect(stitcher.totalHeight == 1880)
    }

    @Test func testKnownOverlapAppendsOnlyNewRows() throws {
        let stitcher = ScrollStitcher()
        _ = try stitcher.append(fixture(start: 0))
        #expect(try stitcher.append(fixture(start: 40)) == .appended(40))
        #expect(stitcher.image?.height == 160)
        #expect(try stitcher.append(fixture(start: 75)) == .appended(35))
        #expect(stitcher.image?.height == 195)
    }

    @Test func testDuplicateDoesNotIncreaseHeight() throws {
        let stitcher = ScrollStitcher()
        _ = try stitcher.append(fixture(start: 0))
        #expect(try stitcher.append(fixture(start: 0)) == .duplicate)
        #expect(stitcher.image?.height == 120)
    }

    @Test func testUnrelatedFrameRejectedWithoutMutatingResult() throws {
        let stitcher = ScrollStitcher()
        _ = try stitcher.append(fixture(start: 0))
        #expect(throws: (any Error).self) { try stitcher.append(fixture(start: 9000, seed: 129)) }
        #expect(stitcher.image?.height == 120)
        #expect(try stitcher.append(fixture(start: 40)) == .appended(40))
    }

    @Test func testChangedDimensionsRejected() throws {
        let stitcher = ScrollStitcher()
        _ = try stitcher.append(fixture(start: 0))
        #expect(throws: (any Error).self) { try stitcher.append(fixture(start: 40, width: 90)) }
    }

    @Test func testMemoryCeilingPreservesExistingImage() throws {
        let stitcher = ScrollStitcher(maxPixels: 96 * 140)
        _ = try stitcher.append(fixture(start: 0))
        #expect(throws: (any Error).self) { try stitcher.append(fixture(start: 40)) }
        #expect(stitcher.image?.height == 120)
    }

    @Test func testFixedHeaderIsNotRepeated() throws {
        let stitcher = ScrollStitcher()
        _ = try stitcher.append(fixture(start: 0, header: 16))
        #expect(try stitcher.append(fixture(start: 40, header: 16)) == .appended(40))
        #expect(stitcher.image?.height == 160)
    }

    @Test func testStitchedPixelsFollowDocumentOrder() throws {
        let stitcher = ScrollStitcher()
        _ = try stitcher.append(fixture(start: 0))
        _ = try stitcher.append(fixture(start: 40))
        let expected = renderedBytes(fixture(start: 0, height: 160))
        let actual = try #require(stitcher.image)
        #expect(renderedBytes(actual) == expected)
    }

    @Test func testFixedFooterKeptOnlyAtFinalEnd() throws {
        let stitcher = ScrollStitcher()
        _ = try stitcher.append(fixture(start: 0, footer: 12))
        #expect(try stitcher.append(fixture(start: 40, footer: 12)) == .appended(40))
        let actual = try #require(stitcher.image)
        #expect(renderedBytes(actual) == renderedBytes(fixture(start: 0, height: 160, footer: 12)))
    }

    @Test func testRepetitiveRowsRefuseAmbiguousAlignment() throws {
        let stitcher = ScrollStitcher()
        _ = try stitcher.append(fixture(start: 0, period: 12))
        #expect(throws: (any Error).self) { try stitcher.append(fixture(start: 4, period: 12)) }
        #expect(stitcher.image?.height == 120)
    }

    @Test func testLargeRetinaFrameMatchesExactPixelOffset() throws {
        let stitcher = ScrollStitcher()
        _ = try stitcher.append(fixture(start: 0, width: 1440, height: 900))
        #expect(try stitcher.append(fixture(start: 321, width: 1440, height: 900)) == .appended(321))
        #expect(stitcher.image?.height == 1221)
    }

    @Test(arguments: [8, 16, 319, 643]) func testSmallAndRetinaOffsetsPreserveExactRows(offset: Int) throws {
        let stitcher = ScrollStitcher()
        _ = try stitcher.append(fixture(start: 0, width: 320, height: 900))
        #expect(try stitcher.append(fixture(start: offset, width: 320, height: 900)) == .appended(offset))
        #expect(renderedBytes(try #require(stitcher.image)) == renderedBytes(fixture(start: 0, width: 320, height: 900 + offset)))
    }

    @Test func testSparseTextPageMatchesSmallScroll() throws {
        let stitcher = ScrollStitcher()
        _ = try stitcher.append(textFixture(start: 0))
        #expect(try stitcher.append(textFixture(start: 8)) == .appended(8))
        #expect(try stitcher.append(textFixture(start: 24)) == .appended(16))
        #expect(renderedBytes(try #require(stitcher.image)) == renderedBytes(textFixture(start: 0, height: 384)))
    }

    @Test func testReverseScrollDoesNotAppendAlreadyCapturedContent() throws {
        let stitcher = ScrollStitcher()
        _ = try stitcher.append(fixture(start: 0))
        _ = try stitcher.append(fixture(start: 40))
        #expect(try stitcher.append(fixture(start: 24)) == .duplicate)
        #expect(try stitcher.append(fixture(start: 40)) == .duplicate)
        #expect(try stitcher.append(fixture(start: 48)) == .appended(8))
        #expect(renderedBytes(try #require(stitcher.image)) == renderedBytes(fixture(start: 0, height: 168)))
    }

    @Test func testPreviewShowsLatestBottomWithinBoundsWithoutChangingCapture() throws {
        let stitcher = ScrollStitcher()
        #expect(stitcher.preview() == nil)
        _ = try stitcher.append(fixture(start: 0))
        _ = try stitcher.append(fixture(start: 40))
        let preview = try #require(stitcher.preview(maxWidth: 96, maxHeight: 64))
        #expect(preview.width == 96)
        #expect(preview.height == 64)
        #expect(renderedBytes(preview) == renderedBytes(fixture(start: 96, height: 64)))
        #expect(stitcher.totalHeight == 160)
        #expect(stitcher.width == 96)
        #expect(stitcher.frameCount == 2)
        #expect(stitcher.preview(maxWidth: 0, maxHeight: 64) == nil)
        #expect(stitcher.preview(maxWidth: 96, maxHeight: 0) == nil)
        #expect(try stitcher.append(fixture(start: 40)) == .duplicate)
        #expect(stitcher.frameCount == 2)
        _ = try stitcher.append(fixture(start: 75))
        #expect(renderedBytes(preview) == renderedBytes(fixture(start: 96, height: 64)))
    }

    @Test func testRetinaPreviewIsSmallWhileCaptureKeepsFullResolution() throws {
        let stitcher = ScrollStitcher()
        _ = try stitcher.append(fixture(start: 0, width: 2880, height: 1800))
        _ = try stitcher.append(fixture(start: 643, width: 2880, height: 1800))
        let preview = try #require(stitcher.preview(maxWidth: 180, maxHeight: 120))
        #expect(preview.width == 180)
        #expect(preview.height == 120)
        #expect(stitcher.totalHeight == 2443)
        #expect(stitcher.image?.width == 2880)
    }

    private func textFixture(start: Int, width: Int = 320, height: Int = 360) -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            let row = start + y
            let line = row / 30
            for x in 24..<(width - 24) where row % 30 < 11 {
                let glyph = UInt32(truncatingIfNeeded: (line &* 1_664_525) ^ ((x / 6) &* 1_013_904_223))
                if (glyph >> UInt32(row % 11)) & 1 == 0 { continue }
                let index = (y * width + x) * 4
                bytes[index] = 30; bytes[index + 1] = 40; bytes[index + 2] = 50
            }
        }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent)!
    }

    @Test func testTextureInGreenAndBlueStillMatches() throws {
        let stitcher = ScrollStitcher()
        _ = try stitcher.append(fixture(start: 0, zeroRed: true))
        #expect(try stitcher.append(fixture(start: 40, zeroRed: true)) == .appended(40))
    }

    @Test func testBlankFramesDoNotInventScrollDistance() throws {
        func blank(_ gray: UInt8) -> CGImage {
            var bytes = [UInt8](repeating: gray, count: 96 * 120 * 4)
            for index in stride(from: 3, to: bytes.count, by: 4) { bytes[index] = 255 }
            return CGImage(width: 96, height: 120, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: 96 * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
                shouldInterpolate: false, intent: .defaultIntent)!
        }
        let stitcher = ScrollStitcher()
        _ = try stitcher.append(blank(100))
        #expect(throws: (any Error).self) { try stitcher.append(blank(102)) }
        #expect(stitcher.image?.height == 120)
    }

    private func renderedBytes(_ image: CGImage) -> Data {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return Data(bytes)
    }

    @Test func testDisplayRelativeCropHandlesNegativeSecondaryScreenAndRetina() {
        let display = CGRect(x: -1440, y: 200, width: 1440, height: 900)
        let selection = CGRect(x: -1400, y: 750, width: 300, height: 200)
        let region = CaptureRegion.from(selection: selection, screenFrame: display, displayID: 42, scale: 2)
        #expect(region.rect == CGRect(x: 40, y: 150, width: 300, height: 200))
        #expect(region.pixelRect == CGRect(x: 80, y: 300, width: 600, height: 400))
    }
}
