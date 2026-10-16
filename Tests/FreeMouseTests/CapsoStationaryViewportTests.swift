import CoreGraphics
import Testing
@testable import FreeMouse

struct CapsoStationaryViewportTests {
    private func frame(offset: Int = 0, caret: Bool = false) -> CGImage {
        let c = CGContext(data: nil, width: 400, height: 500, bitsPerComponent: 8,
            bytesPerRow: 1600, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(gray: 1, alpha: 1); c.fill(CGRect(x: 0, y: 0, width: 400, height: 500))
        for row in 0..<25 {
            c.setFillColor(red: CGFloat((row * 37) % 255) / 255, green: 0.2, blue: 0.4, alpha: 1)
            c.fill(CGRect(x: 20 + row % 7, y: row * 20 - offset, width: 210 + row % 13, height: 9))
        }
        if caret { c.setFillColor(gray: 0, alpha: 1); c.fill(CGRect(x: 290, y: 100, width: 2, height: 16)) }
        return c.makeImage()!
    }
    @Test func blinkingCaretDoesNotReportMissingTail() throws {
        let a = frame(), b = frame(caret: true)
        let offset = try #require(CapsoScrolling.ScrollCaptureController.verticalOffset(from: a, to: b, ignoring: .init()))
        #expect(CapsoScrolling.ScrollCaptureController.isStationaryViewport(from: a, to: b, offset: offset))
    }
    @Test func actualScrollingIsNotStationary() {
        #expect(!CapsoScrolling.ScrollCaptureController.isStationaryViewport(from: frame(), to: frame(offset: 80), offset: 80))
        #expect(!CapsoScrolling.ScrollCaptureController.isStationaryViewport(from: frame(), to: frame(offset: 80), offset: 0))
    }
    @Test func unknownAlignmentCannotConfirmTail() {
        #expect(!CapsoScrolling.ScrollCaptureController.isStationaryViewport(from: frame(), to: frame(caret: true), offset: nil))
    }
    @Test func sparseTextInLargeFixedAreaIsNotStationary() {
        func sparse(_ y: Int) -> CGImage {
            let c = CGContext(data: nil, width: 4000, height: 2000, bitsPerComponent: 8,
                bytesPerRow: 16000, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.setFillColor(gray: 1, alpha: 1); c.fill(CGRect(x: 0, y: 0, width: 4000, height: 2000))
            c.setFillColor(gray: 0, alpha: 1); c.fill(CGRect(x: 500, y: y, width: 80, height: 12))
            return c.makeImage()!
        }
        #expect(!CapsoScrolling.ScrollCaptureController.isStationaryViewport(from: sparse(100), to: sparse(120), offset: 0))
    }

}
