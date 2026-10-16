import AppKit
import Foundation
import Testing

@testable import FreeMouse

@MainActor
struct ScrollLargeRasterTests {
    @Test
    func largeSparseBodyKeepsEveryRowAcrossMoreThanEightSmallScrolls() throws {
        let matcher = ScrollStitcher()
        let offsets = [0, 71, 147, 223, 291, 377, 461, 547, 633, 719, 805, 891, 977]
        let increments = [1409, 71, 76, 76, 68, 86, 84, 86, 86, 86, 86, 86, 86]
        for (index, offset) in offsets.enumerated() {
            let result = try matcher.append(sparseDocument(height: 1409, offset: offset))
            #expect(result == .appended(increments[index]))
        }
        #expect(matcher.totalHeight == 2386)
        #expect(matcher.frameCount == 13)
        let output = try #require(matcher.image)
        let expected = try sparseDocument(height: 2386, offset: 0)
        #expect(try rgba(output) == rgba(expected))
    }

    @Test
    func largeSparseBodyFindsOddLongOffsetAndRejectsReverseGrowth() throws {
        let matcher = ScrollStitcher()
        let first = try sparseDocument(height: 1409, offset: 0)
        let second = try sparseDocument(height: 1409, offset: 799)
        let initial = try matcher.append(first)
        let advance = try matcher.append(second)
        #expect(initial == .appended(1409))
        #expect(advance == .appended(799))
        let before = try #require(matcher.image?.dataProvider?.data) as Data
        let reverse = try matcher.append(first)
        #expect(reverse == .duplicate)
        #expect(matcher.totalHeight == 2208)
        #expect(matcher.frameCount == 2)
        let after = try #require(matcher.image?.dataProvider?.data) as Data
        #expect(after == before)
    }

    /// A narrow document with generated glyph-like marks leaves almost every
    /// sampled column white, which forces discovery to evaluate many offsets.
    /// The complete expected image is rendered independently at the final
    /// document height, so a missing, duplicated, or wrong row changes pixels.
    private func sparseDocument(height: Int, offset: Int) throws -> CGImage {
        let width = 1897
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            let row = y + offset
            let seed = ((row / 23) * 1103515245 + 12345) & 0x7fffffff
            guard row % 23 < 6 else { continue }
            for x in 1540..<1620 where (x + seed % 137) % 211 < 95 + seed % 55 {
                let index = (y * width + x) * 4
                bytes[index] = UInt8(25 + seed % 90)
                bytes[index + 1] = UInt8(30 + (seed / 100) % 90)
                bytes[index + 2] = UInt8(40 + (seed / 10000) % 90)
            }
        }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        return try #require(CGImage(width: width, height: height, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent))
    }

    private func rgba(_ image: CGImage) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
            let context = try #require(CGContext(data: buffer.baseAddress,
                width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return Data(bytes)
    }
}
