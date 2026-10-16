import Testing
import AppKit
@testable import FreeMouse

struct EditorTests {
    // A missing inverse zoom would move annotations on a Retina/zoomed canvas.
    @Test func zoomCoordinatesRemainInOriginalPixels() {
        let p = EditorRasterizer.imagePoint(CGPoint(x: 37.5, y: 75), scale: 0.25,
                                           size: CGSize(width: 200, height: 400))
        #expect(p.x == 150)
        #expect(p.y == 300)
        let edge = EditorRasterizer.imagePoint(CGPoint(x: -5, y: 999), scale: 0.5,
                                               size: CGSize(width: 200, height: 400))
        #expect(edge.x == 0)
        #expect(edge.y == 400)
    }

    // A flipped y axis or transparent mask would expose the chosen top-left pixels.
    @Test func opaqueRedactionUsesTopLeftImageCoordinatesAndKeepsResolution() throws {
        let input = try fixture()
        let mask = EditorAnnotation(kind: .redact, points: [.init(x: 0, y: 0), .init(x: 2, y: 2)],
                                    color: .red, width: 1, text: "")
        let output = try #require(EditorRasterizer.render(image: input, annotations: [mask]))
        #expect(output.width == 4)
        #expect(output.height == 4)
        let bitmap = NSBitmapImageRep(cgImage: output)
        let hidden = try #require(bitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB))
        #expect(hidden.redComponent < 0.01)
        #expect(hidden.greenComponent < 0.01)
        #expect(abs(hidden.alphaComponent - 1) < 0.01)
        let untouched = try #require(bitmap.colorAt(x: 3, y: 3)?.usingColorSpace(.deviceRGB))
        #expect(abs(untouched.blueComponent - 1) < 0.01)
        #expect(untouched.redComponent < 0.01)
    }

    // Reversing source image rows during export corrupts every screenshot.
    @Test func exportWithoutAnnotationsPreservesSourceCorners() throws {
        let output = try #require(EditorRasterizer.render(image: fixture(), annotations: []))
        let bitmap = NSBitmapImageRep(cgImage: output)
        let top = try #require(bitmap.colorAt(x: 3, y: 0)?.usingColorSpace(.deviceRGB))
        let bottom = try #require(bitmap.colorAt(x: 3, y: 3)?.usingColorSpace(.deviceRGB))
        #expect(abs(top.redComponent - 1) < 0.01)
        #expect(abs(bottom.blueComponent - 1) < 0.01)
    }

    // Reject integer overflow while allowing dimensions above the former cap.
    @Test func renderSizeRejectsOverflowWithoutAnArbitraryPixelCeiling() {
        #expect(!EditorRasterizer.isSafeSize(width: Int.max, height: 2))
        #expect(EditorRasterizer.isSafeSize(width: 20_000, height: 20_000))
        #expect(EditorRasterizer.isSafeSize(width: 1200, height: 20_000))
    }

    private func fixture() throws -> CGImage {
        var bytes = [UInt8]()
        for row in 0..<4 {
            for _ in 0..<4 { bytes += row < 2 ? [255, 0, 0, 255] : [0, 0, 255, 255] }
        }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        return try #require(CGImage(width: 4, height: 4, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 16, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }
}
