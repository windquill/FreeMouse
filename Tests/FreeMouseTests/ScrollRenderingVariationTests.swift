import AppKit
import Foundation
import Testing
@testable import FreeMouse

/// These pairs preserve document overlap while changing viewport composition.
/// Unlike exact row crops, a subpixel translation resamples antialiased edges.
@MainActor
struct ScrollRenderingVariationTests {
    private let width = 480
    private let height = 640
    private let documentHeight = 2200

    @Test func exactRenderedTextCropEstablishesKnownFortyPixelOverlap() throws {
        let document = renderedDocument()
        let stitcher = ScrollStitcher()
        _ = try stitcher.append(viewport(document, start: 0))
        #expect(try stitcher.append(viewport(document, start: 40)) == .appended(40))
        #expect(stitcher.totalHeight == 680)
    }

    @Test func quarterPixelCompositionStillRecognizesFortyPixelDocumentAdvance() throws {
        let document = renderedDocument()
        let stitcher = ScrollStitcher()
        _ = try stitcher.append(viewport(document, start: 0))
        #expect(try stitcher.append(viewport(document, start: 40, quarterPixel: true)) == .appended(40))
        #expect(stitcher.totalHeight == 680)
    }

    @Test func fixedSidebarDoesNotHideIndependentScrollingDocumentOverlap() throws {
        let document = renderedDocument()
        let stitcher = ScrollStitcher()
        _ = try stitcher.append(viewport(document, start: 0, sidebar: true))
        #expect(try stitcher.append(viewport(document, start: 40, sidebar: true)) == .appended(40))
        #expect(stitcher.totalHeight == 680)
    }

    @Test func wideNonperiodicFixedSidebarLeavesDocumentPixelsInOrder() throws {
        let document = renderedDocument()
        let stitcher = ScrollStitcher()
        _ = try stitcher.append(viewport(document, start: 0, sidebar: true,
                                        sidebarWidth: 180, nonperiodicSidebar: true))
        #expect(try stitcher.append(viewport(document, start: 40, sidebar: true,
                                            sidebarWidth: 180, nonperiodicSidebar: true)) == .appended(40))
        #expect(stitcher.totalHeight == 680)
        let output = Array(try #require(stitcher.image?.dataProvider?.data) as Data)
        let matchesDocument = (0..<680).allSatisfy { y in
            let begin = (y * width + 180) * 4
            let end = (y + 1) * width * 4
            return output[begin..<end].elementsEqual(document[begin..<end])
        }
        #expect(matchesDocument)
    }

    @Test func wideFixedSidebarCannotSupplyOverlapForAnUnrelatedViewport() throws {
        let document = renderedDocument()
        let stitcher = ScrollStitcher()
        _ = try stitcher.append(viewport(document, start: 0, sidebar: true,
                                        sidebarWidth: 180, nonperiodicSidebar: true))
        let before = try #require(stitcher.image?.dataProvider?.data)
        #expect(throws: CaptureError.noOverlap) {
            try stitcher.append(viewport(document, start: 900, sidebar: true,
                                        sidebarWidth: 180, nonperiodicSidebar: true))
        }
        #expect(stitcher.totalHeight == 640)
        #expect(stitcher.frameCount == 1)
        #expect(stitcher.image?.dataProvider?.data == before)
    }

    @Test func returningFromFractionalToSharpRenderingKeepsDocumentAdvance() throws {
        let document = renderedDocument()
        let stitcher = ScrollStitcher()
        _ = try stitcher.append(viewport(document, start: 0, quarterPixel: true))
        #expect(try stitcher.append(viewport(document, start: 40)) == .appended(40))
        #expect(stitcher.totalHeight == 680)
    }

    @Test(arguments: [false, true])
    func subpixelRenderingCannotMatchRepeatedTextWithoutActualOverlap(sidebar: Bool) throws {
        let document = renderedDocument()
        let stitcher = ScrollStitcher()
        _ = try stitcher.append(viewport(document, start: 0, sidebar: sidebar))
        let before = try #require(stitcher.image?.dataProvider?.data)
        #expect(throws: CaptureError.noOverlap) {
            try stitcher.append(viewport(document, start: 900, quarterPixel: true, sidebar: sidebar))
        }
        #expect(stitcher.totalHeight == 640)
        #expect(stitcher.frameCount == 1)
        #expect(stitcher.image?.dataProvider?.data == before)
    }

    private func renderedDocument() -> [UInt8] {
        let context = CGContext(data: nil, width: width, height: documentHeight,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: documentHeight))
        context.translateBy(x: 0, y: CGFloat(documentHeight))
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        for row in 0..<48 {
            let line = "Row \(row * 37 + 11): scroll capture keeps unique text \(row * 53)."
            line.draw(at: CGPoint(x: 120, y: row * 43 + 12), withAttributes: [
                .font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.darkGray
            ])
        }
        NSGraphicsContext.restoreGraphicsState()
        var bytes = [UInt8](repeating: 0, count: width * documentHeight * 4)
        memcpy(&bytes, context.data!, bytes.count)
        return bytes
    }

    private func viewport(_ document: [UInt8], start: Int,
                          quarterPixel: Bool = false, sidebar: Bool = false,
                          sidebarWidth: Int = 100, nonperiodicSidebar: Bool = false) -> CGImage {
        var bytes = Array(document[(start * width * 4)..<((start + height) * width * 4)])
        if quarterPixel {
            for y in 0..<height {
                for x in 0..<width {
                    let target = (y * width + x) * 4
                    let below = ((start + y + 1) * width + x) * 4
                    for channel in 0..<3 {
                        bytes[target + channel] = UInt8((3 * Int(bytes[target + channel]) + Int(document[below + channel])) / 4)
                    }
                }
            }
        }
        if sidebar {
            for y in 0..<height {
                for x in 0..<sidebarWidth {
                    let pattern = ((y / 3) &* 1_664_525) ^ ((x / 3) &* 1_013_904_223)
                    let value: UInt8 = nonperiodicSidebar
                        ? ((pattern ^ (pattern >> 13)) & 1 == 0 ? 30 : 240)
                        : (x >= 10 && x < 90 && y % 43 < 12 ? UInt8(40 + (y / 43) * 7) : 240)
                    let index = (y * width + x) * 4
                    bytes[index] = value; bytes[index + 1] = value; bytes[index + 2] = value
                }
            }
        }
        return CGImage(width: width, height: height, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent)!
    }
}
