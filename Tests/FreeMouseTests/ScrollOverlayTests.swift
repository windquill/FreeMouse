import AppKit
import Testing
@testable import FreeMouse

/// A real, antialiased text page with a viewport-fixed white panel, like the
/// screenshot reported by the user. Every frame is cropped from one raster.
struct ScrollOverlayTests {
    @Test(arguments: [false, true]) func scrollingReplacesObscuredOverlapInsteadOfAccumulatingPanels(changingHeight: Bool) throws {
        let fixture = try OverlayPageFixture()
        let stitcher = ScrollStitcher()
        let positions = [0, 40, 160, 200, 240]
        var previousPosition = 0
        for (index, position) in positions.enumerated() {
            let frame = try fixture.viewport(start: position, overlayHeight: changingHeight ? 86 + ((position / 40) % 4) * 11 : 86)
            let result = try stitcher.append(frame)
            #expect(result == .appended(index == 0 ? 900 : position - previousPosition))
            previousPosition = position
        }
        let image = try #require(stitcher.image)
        let output = OverlayPageFixture.bytes(image)
        #expect(image.height == 1140)
        // Only the final viewport's panel may remain. All earlier panels must
        // be overwritten when the content underneath is seen in later frames.
        let cleanRows = 240 + 740
        let changedRows = (0..<cleanRows).filter { row in
            let range = (row * 650 * 4)..<((row + 1) * 650 * 4)
            return output[range] != fixture.document[range]
        }.count
        #expect(changedRows == 0)
    }

    @Test func unoccludedTextPagePreservesEveryPixelThroughManySeams() throws {
        let fixture = try OverlayPageFixture()
        let stitcher = ScrollStitcher()
        for position in stride(from: 0, through: 480, by: 40) { _ = try stitcher.append(fixture.viewport(start: position, overlayHeight: nil)) }
        let image = try #require(stitcher.image)
        let matchesDocument = OverlayPageFixture.bytes(image) == Array(fixture.document.prefix(1380 * 650 * 4))
        #expect(matchesDocument)
    }
}

private struct OverlayPageFixture {
    let document: [UInt8]
    private static let width = 650
    private static let space = CGColorSpace(name: CGColorSpace.sRGB)!

    init() throws {
        let image = try Self.draw(height: 3000) { context in
            for section in 0..<15 {
                let y = section * 193 + 18
                Self.text("Capture report \(section): Verify scrolling screenshot overlap.", x: 34, y: y)
                Self.text("The application contains logs, messages, and large blank margins.", x: 34, y: y + 24)
                if section % 3 == 0 {
                    NSColor(calibratedRed: 0.9, green: 0.95, blue: 1, alpha: 1).setFill()
                    NSBezierPath(roundedRect: CGRect(x: 135, y: y + 65, width: 425, height: 58), xRadius: 12, yRadius: 12).fill()
                    Self.text("Message \(section * 37): The scroll should preserve document order.", x: 149, y: y + 82)
                } else if section % 3 == 1 {
                    NSColor(calibratedWhite: 0.95, alpha: 1).setFill()
                    NSBezierPath(roundedRect: CGRect(x: 38, y: y + 59, width: 510, height: 75), xRadius: 11, yRadius: 11).fill()
                    Self.text("let frame = try capture(region: selectedRegion)", x: 54, y: y + 73, size: 13)
                    Self.text("// sequence \(section * 19 + 3), request \(section * 11 + 7)", x: 54, y: y + 98, size: 13)
                }
            }
        }
        document = Self.bytes(image)
    }

    func viewport(start: Int, overlayHeight: Int?) throws -> CGImage {
        let cropped = Array(document[(start * 650 * 4)..<((start + 900) * 650 * 4)])
        let raw = try #require(CGImage(width: 650, height: 900, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 650 * 4, space: Self.space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(cropped) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        guard let overlayHeight else { return raw }
        return try Self.draw(height: 900) { c in
            c.saveGState(); c.translateBy(x: 0, y: 900); c.scaleBy(x: 1, y: -1)
            c.draw(raw, in: CGRect(x: 0, y: 0, width: 650, height: 900)); c.restoreGState()
            let y = 900 - 8 - overlayHeight
            c.setShadow(offset: CGSize(width: 0, height: 3), blur: 10, color: NSColor.black.withAlphaComponent(0.15).cgColor)
            NSColor.white.setFill()
            NSBezierPath(roundedRect: CGRect(x: 82, y: y, width: 476, height: overlayHeight), xRadius: 13, yRadius: 13).fill()
            c.setShadow(offset: .zero, blur: 0)
            Self.text("↓", x: 312, y: y + 12, size: 28)
            Self.text("Selected region · continuous scrolling capture", x: 158, y: y + 57, size: 9)
        }
    }
    private static func text(_ value: String, x: Int, y: Int, size: CGFloat = 14) {
        value.draw(at: CGPoint(x: x, y: y), withAttributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.darkGray])
    }
    private static func draw(height: Int, body: (CGContext) -> Void) throws -> CGImage {
        let c = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        c.setFillColor(NSColor.white.cgColor); c.fill(CGRect(x: 0, y: 0, width: width, height: height))
        c.translateBy(x: 0, y: CGFloat(height)); c.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: true)
        body(c); return try #require(c.makeImage())
    }
    static func bytes(_ image: CGImage) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: image.width * image.height * 4)
        result.withUnsafeMutableBytes { storage in
            let c = CGContext(data: storage.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return result
    }
}
