import Testing
import AppKit
import Foundation
@testable import FreeMouse

/// Real antialiased text and repeated chat layouts exercise the foreground
/// evidence that uniformly noisy row fixtures do not cover.
struct ScrollTextEvidenceTests {
    private let width = 650
    private let viewportHeight = 900
    private let documentHeight = 6000

    @Test func testExactForwardTextMatchWinsOverApproximateReverseTemplate() throws {
        let document = documentBytes()
        let stitcher = ScrollStitcher()
        _ = try stitcher.append(viewport(document, start: 40))
        try #require(try stitcher.append(viewport(document, start: 80)) == .appended(40))
        #expect(stitcher.totalHeight == 940)
        let followsDocument = renderedBytes(try #require(stitcher.image)) == slice(document, start: 40, height: 940)
        #expect(followsDocument)
    }

    @Test func testSparseForwardTextMatchDoesNotRequireDenseRandomTexture() throws {
        let document = documentBytes()
        let stitcher = ScrollStitcher()
        _ = try stitcher.append(viewport(document, start: 40))
        try #require(try stitcher.append(viewport(document, start: 120)) == .appended(80))
        #expect(stitcher.totalHeight == 980)
        let followsDocument = renderedBytes(try #require(stitcher.image)) == slice(document, start: 40, height: 980)
        #expect(followsDocument)
    }

    @Test func testRepeatedTextTemplateWithNoTrueOverlapCannotInventDistance() throws {
        let document = documentBytes()
        let stitcher = ScrollStitcher()
        _ = try stitcher.append(viewport(document, start: 2040))
        let before = renderedBytes(try #require(stitcher.image))
        #expect(throws: CaptureError.noOverlap) { try stitcher.append(viewport(document, start: 3000)) }
        #expect(stitcher.totalHeight == viewportHeight)
        let preservesResult = renderedBytes(try #require(stitcher.image)) == before
        #expect(preservesResult)
    }

    @Test(arguments: [2, 6]) func testNarrowContentBetweenCoarseColumnsRetainsItsExactOffset(contentWidth: Int) throws {
        func narrowFrame(start: Int, height: Int = 900) -> CGImage {
            var bytes = [UInt8](repeating: 255, count: width * height * 4)
            for y in 0..<height {
                let row = start + y
                let value = UInt8(truncatingIfNeeded: (row &* 1_664_525) ^ ((row / 9) &* 1_013_904_223))
                for x in 40..<(40 + contentWidth) {
                    let index = (y * width + x) * 4
                    bytes[index] = value; bytes[index + 1] = value; bytes[index + 2] = value
                }
            }
            return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
                shouldInterpolate: false, intent: .defaultIntent)!
        }
        let stitcher = ScrollStitcher()
        _ = try stitcher.append(narrowFrame(start: 0))
        try #require(try stitcher.append(narrowFrame(start: 40)) == .appended(40))
        #expect(stitcher.totalHeight == 940)
        let followsDocument = renderedBytes(try #require(stitcher.image)) == renderedBytes(narrowFrame(start: 0, height: 940))
        #expect(followsDocument)
    }

    private func documentBytes() -> [UInt8] {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: width, height: documentHeight,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: documentHeight))
        context.translateBy(x: 0, y: CGFloat(documentHeight)); context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        for section in 0..<31 {
            let y = section * 193 + 18
            text("Capture report \(section): Verify scrolling screenshot overlap.", x: 34, y: y)
            text("The application contains logs, messages, and large blank margins.", x: 34, y: y + 24)
            if section % 3 == 0 {
                NSColor(calibratedRed: 0.9, green: 0.95, blue: 1, alpha: 1).setFill()
                NSBezierPath(roundedRect: CGRect(x: 135, y: y + 65, width: 425, height: 58), xRadius: 12, yRadius: 12).fill()
                text("Message \(section * 37): The scroll should preserve document order.", x: 149, y: y + 82)
            } else if section % 3 == 1 {
                NSColor(calibratedWhite: 0.95, alpha: 1).setFill()
                NSBezierPath(roundedRect: CGRect(x: 38, y: y + 59, width: 510, height: 75), xRadius: 11, yRadius: 11).fill()
                text("let frame = try capture(region: selectedRegion)", x: 54, y: y + 73, size: 13)
                text("// sequence \(section * 19 + 3), request \(section * 11 + 7)", x: 54, y: y + 98, size: 13)
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        return renderedBytes(context.makeImage()!)
    }

    private func text(_ string: String, x: Int, y: Int, size: CGFloat = 14) {
        string.draw(at: CGPoint(x: x, y: y), withAttributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.darkGray])
    }

    private func slice(_ document: [UInt8], start: Int, height: Int) -> [UInt8] {
        Array(document[(start * width * 4)..<((start + height) * width * 4)])
    }

    private func viewport(_ document: [UInt8], start: Int) -> CGImage {
        CGImage(width: width, height: viewportHeight, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(slice(document, start: start, height: viewportHeight)) as CFData)!,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    private func renderedBytes(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }
}
