import AppKit
import Foundation
import ImageIO
import Testing
@testable import FreeMouse

/// Reproduces the layout and 2x AppKit rendering of the actual qa118 capture.
/// Each paragraph has a unique marker, but most pixels and most glyphs repeat.
@MainActor
struct ScrollReproduction119Tests {
    private let width = 1400
    private let height = 800

    @Test(arguments: [1, 2, 7, 14, 40, 80, 160, 240, 312, 400, 560, 650])
    func retinaCardLayoutRecognizesDocumentAdvance(advance: Int) throws {
        let stitcher = ScrollStitcher()
        _ = try stitcher.append(render(offset: 0))
        #expect(try stitcher.append(render(offset: Double(advance))) == .appended(advance))
    }

    @Test(arguments: [0.125, 0.25, 0.375, 0.5, 0.75])
    func appKitFractionalTextRenderingRecognizesDocumentAdvance(phase: Double) throws {
        let stitcher = ScrollStitcher()
        _ = try stitcher.append(render(offset: 0))
        let result = try stitcher.append(render(offset: 40 + phase))
        #expect(result == .appended(40) || result == .appended(41))
    }

    @Test(arguments: [1, 40, 160])
    func actualCapturedPixelsRetainDocumentAdvance(advance: Int) throws {
        let url = try #require(Bundle.module.url(forResource: "fast-reference", withExtension: "png",
                                                 subdirectory: "ScrollNative121"))
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let stitcher = ScrollStitcher()
        let first = try #require(image.cropping(to: CGRect(x: 0, y: 0, width: image.width, height: 640)))
        let next = try #require(image.cropping(to: CGRect(x: 0, y: advance, width: image.width, height: 640)))
        _ = try stitcher.append(first)
        #expect(try stitcher.append(next) == .appended(advance))
    }

    @Test func manySmallStepsKeepGrowingAcrossParagraphBoundaries() throws {
        let stitcher = ScrollStitcher()
        _ = try stitcher.append(render(offset: 0))
        for offset in stride(from: 7, through: 700, by: 7) {
            let result = try stitcher.append(render(offset: Double(offset)))
            try #require(result == .appended(7), "offset \(offset): \(result)")
        }
        #expect(stitcher.totalHeight == 1500)
    }

    @Test(arguments: [1, 40, 160, 400])
    func fixedToolbarAndFooterStillAllowDocumentAdvance(advance: Int) throws {
        let stitcher = ScrollStitcher()
        _ = try stitcher.append(render(offset: 0, chrome: true))
        #expect(try stitcher.append(render(offset: Double(advance), chrome: true)) == .appended(advance))
    }

    private func render(offset: Double, chrome: Bool = false) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 2, y: -2)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        for row in 6..<15 {
            let y = Double(row - 7) * 156 - offset / 2
            NSColor(calibratedWhite: 0.96, alpha: 1).setFill()
            NSRect(x: 0, y: y + 118, width: Double(width) / 2, height: 16).fill()
            String(format: "测试段落 %03d", row).draw(at: NSPoint(x: 7, y: y - 4), withAttributes: [
                .font: NSFont.systemFont(ofSize: 23, weight: .bold), .foregroundColor: NSColor.darkGray
            ])
            "第 \(row) 段：缓慢滚动，检查编号连续、无重叠或缺失。".draw(at: NSPoint(x: 7, y: y + 37), withAttributes: [
                .font: NSFont.systemFont(ofSize: 17), .foregroundColor: NSColor.darkGray
            ])
            "Unique marker: \(row * 7919 + 12345) / \(row * row * 43) — ABC 中文 0123456789".draw(at: NSPoint(x: 7, y: y + 74), withAttributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular), .foregroundColor: NSColor.systemBlue
            ])
        }
        if chrome {
            NSColor(calibratedWhite: 0.94, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: 700, height: 34).fill()
            NSRect(x: 0, y: 370, width: 700, height: 30).fill()
            "固定工具栏 — 文档滚动测试".draw(at: NSPoint(x: 14, y: 8), withAttributes: [
                .font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.darkGray
            ])
            "状态：正在浏览测试文档".draw(at: NSPoint(x: 14, y: 378), withAttributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.darkGray
            ])
        }
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()!
    }
}
