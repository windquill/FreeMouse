import CoreGraphics
import Foundation
import Testing
@testable import FreeMouse

struct ScrollPausedViewportTests {
    private func viewport(marker: UInt8, width: Int = 20) throws -> CGImage {
        var pixels = [UInt8](repeating: 255, count: width * 40 * 4)
        pixels[4 * width * 15] = marker
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        return try #require(CGImage(width: width, height: 40, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    @Test func pausedViewportVerificationNeverAppendsOrReplacesCapturedPixels() throws {
        let stitcher = ScrollStitcher()
        _ = try stitcher.append(viewport(marker: 0))
        let original = try #require(stitcher.image?.dataProvider?.data) as Data
        #expect(try stitcher.matchesLastViewport(viewport(marker: 0)))
        #expect(try !stitcher.matchesLastViewport(viewport(marker: 128)))
        #expect(try !stitcher.matchesLastViewport(viewport(marker: 0, width: 21)))
        #expect(stitcher.totalHeight == 40)
        #expect(stitcher.frameCount == 1)
        #expect(stitcher.image?.dataProvider?.data as Data? == original)
    }
}
