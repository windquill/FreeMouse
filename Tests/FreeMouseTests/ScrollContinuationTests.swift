import Testing
import AppKit
import Foundation
@testable import FreeMouse

/// Deterministic, native AppKit text fixtures with a wide fixed table and a
/// narrow scrolling document. No screen capture, windows, or external data.
@MainActor
struct ScrollContinuationTests {
    private static let width = 800
    private static let height = 400
    private static let fixedWidth = 600
    private static let contentWidth = width - fixedWidth

    @Test func smallBodyMovementMustNotBeHiddenByFixedTableEdges() throws {
        let fixture = Self.makeFixture(documentHeight: 1000, denseThrough: 0, firstSparseRow: 200)
        let first = fixture.frame(offset: 0)
        let next = fixture.frame(offset: 7)
        let moved = !fixture.document[0..<(Self.height * Self.contentWidth * 4)].elementsEqual(
            fixture.document[(7 * Self.contentWidth * 4)..<((7 + Self.height) * Self.contentWidth * 4)])
        #expect(moved, "The scrolling document must actually change between these two native renders.")

        let stitcher = ScrollStitcher()
        let initial = try stitcher.append(first)
        let result = try stitcher.append(next)
        #expect(initial == .appended(Self.height))
        #expect(result == .appended(7))
        #expect(stitcher.totalHeight == Self.height + 7)
        #expect(stitcher.frameCount == 2)
        try Self.expectScrollingROI(stitcher, follows: fixture.document,
                                    expectedHeight: Self.height + 7)
    }

    @Test func continuationFromDenseIntoSparsePagesMustKeepGrowing() throws {
        // Six additional viewports, in overlapping 100-row steps. At most
        // 800 * 2800 = 2,240,000 assembled pixels, well below the 24 MP cap.
        let finalOffset = 2400
        let fixture = Self.makeFixture(documentHeight: Self.height + finalOffset,
                                       denseThrough: 650, firstSparseRow: 690)
        let stitcher = ScrollStitcher()
        let initial = try stitcher.append(fixture.frame(offset: 0))
        #expect(initial == .appended(Self.height))
        var firstUnexpectedStep: String?
        var unexpectedStepCount = 0
#if SCROLL_CAPTURE_DIAGNOSTICS
        var previousAcceptedOffset = 0
#endif

        for offset in stride(from: 100, through: finalOffset, by: 100) {
#if SCROLL_CAPTURE_DIAGNOSTICS
            stitcher.continuationDiagnosticProbeEnabled = offset == 700 || offset == 1600
#endif
            do {
                let result = try stitcher.append(fixture.frame(offset: offset))
#if SCROLL_CAPTURE_DIAGNOSTICS
                if (offset == 700 || offset == 1600), case .duplicate = result {
                    Self.printContinuationProbe(stitcher, previousOffset: previousAcceptedOffset, offset: offset)
                }
                if case .appended = result { previousAcceptedOffset = offset }
#endif
                if result != .appended(100) || stitcher.totalHeight != Self.height + offset {
                    unexpectedStepCount += 1
                    if firstUnexpectedStep == nil {
                        firstUnexpectedStep = "offset \(offset): \(String(describing: result)), height \(stitcher.totalHeight)"
                    }
                }
            } catch {
#if SCROLL_CAPTURE_DIAGNOSTICS
                if offset == 700 || offset == 1600 {
                    Self.printContinuationProbe(stitcher, previousOffset: previousAcceptedOffset, offset: offset)
                }
#endif
                unexpectedStepCount += 1
                if firstUnexpectedStep == nil {
                    firstUnexpectedStep = "offset \(offset): \(error.localizedDescription), height \(stitcher.totalHeight)"
                }
            }
        }

        #expect(unexpectedStepCount == 0, "First continuation failure: \(firstUnexpectedStep ?? "none"); affected steps: \(unexpectedStepCount)")
        #expect(stitcher.totalHeight == Self.height + finalOffset)
        #expect(stitcher.frameCount == 25)
        try Self.expectScrollingROI(stitcher, follows: fixture.document,
                                    expectedHeight: Self.height + finalOffset)
    }

    @Test func genuinelyStationarySparseBodyRemainsDuplicate() throws {
        let fixture = Self.makeFixture(documentHeight: 1000, denseThrough: 0, firstSparseRow: 200)
        let stitcher = ScrollStitcher()
        let initial = try stitcher.append(fixture.frame(offset: 0))
        #expect(initial == .appended(Self.height))
        let before = try #require(stitcher.image?.dataProvider?.data) as Data

        for _ in 0..<4 {
            // Independently construct the same viewport; this is not merely
            // reusing one CGImage object as the stationary control.
            let result = try stitcher.append(fixture.frame(offset: 0))
            #expect(result == .duplicate)
        }

        #expect(stitcher.totalHeight == Self.height)
        #expect(stitcher.frameCount == 1)
        let after = try #require(stitcher.image?.dataProvider?.data) as Data
        #expect(before == after)
        try Self.expectScrollingROI(stitcher, follows: fixture.document,
                                    expectedHeight: Self.height)
    }

    @Test func nearStationaryBrightnessChangeMustNotGrow() throws {
        let fixture = Self.makeFixture(documentHeight: 1000, denseThrough: 0, firstSparseRow: 200)
        let baseline = fixture.frame(offset: 0)
        let sourceData = try #require(baseline.dataProvider?.data) as Data
        var bytes = [UInt8](sourceData)
        // Repaint brightness only: preserve every pixel position and alpha.
        // White stays white; each nonwhite RGB channel rises by one, capped
        // at 255, without applying any translation or interpolation.
        for index in stride(from: 0, to: bytes.count, by: 4) {
            for channel in 0..<3 {
                if bytes[index + channel] < 255 { bytes[index + channel] += 1 }
            }
        }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        let repainted = try #require(CGImage(width: Self.width, height: Self.height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: Self.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))

        let stitcher = ScrollStitcher()
        let initial = try stitcher.append(baseline)
        #expect(initial == .appended(Self.height))
        let before = try #require(stitcher.image?.dataProvider?.data) as Data
        var safelyRejected = false
        do {
            let result = try stitcher.append(repainted)
            safelyRejected = result == .duplicate
        } catch CaptureError.noOverlap {
            // The fixed table's shallow gray background occupies 75% of
            // the frame. Repainting it by +1 can exceed the original 0.35
            // stillness tolerance; safe refusal must not change the image.
            safelyRejected = true
        }
        #expect(safelyRejected)
        #expect(stitcher.totalHeight == Self.height)
        #expect(stitcher.frameCount == 1)
        let after = try #require(stitcher.image?.dataProvider?.data) as Data
        #expect(after == before)
        try Self.expectScrollingROI(stitcher, follows: fixture.document,
                                    expectedHeight: Self.height)
    }

#if SCROLL_CAPTURE_DIAGNOSTICS
    private static func printContinuationProbe(_ stitcher: ScrollStitcher,
                                               previousOffset: Int, offset: Int) {
        // A duplicate can leave only one alignment event for this pair.
        // Exclude the previous pair's event, whose detailed probe was off.
        let probes = stitcher.matchingDiagnostics.suffix(2)
            .filter { $0["continuation100"] != nil }
            .map { event -> [String: Any] in
                ["previousAcceptedOffset": previousOffset, "incomingOffset": offset,
                 "direction": event["direction"] ?? NSNull(),
                 "top": event["top"] ?? NSNull(),
                 "bottom": event["bottom"] ?? NSNull(),
                 "maximumShift": event["maximumShift"] ?? NSNull(),
                 "decision": event["decision"] ?? NSNull(),
                 "continuation100": event["continuation100"] ?? NSNull()]
            }
        if let data = try? JSONSerialization.data(withJSONObject: probes, options: [.sortedKeys]) {
            print("SCROLL_CONTINUATION_\(offset) " + String(decoding: data, as: UTF8.self))
        } else {
            print("SCROLL_CONTINUATION_\(offset) probe-serialization-failed")
        }
    }
#endif

    @MainActor
    private struct Fixture {
        let document: [UInt8]
        let fixedViewport: [UInt8]
        let documentHeight: Int

        func frame(offset: Int) -> CGImage {
            precondition(offset >= 0 && offset + ScrollContinuationTests.height <= documentHeight)
            let width = ScrollContinuationTests.width
            let height = ScrollContinuationTests.height
            let fixedWidth = ScrollContinuationTests.fixedWidth
            let contentWidth = ScrollContinuationTests.contentWidth
            var bytes = fixedViewport
            bytes.withUnsafeMutableBytes { target in
                document.withUnsafeBytes { source in
                    for y in 0..<height {
                        let destination = (y * width + fixedWidth) * 4
                        let origin = ((offset + y) * contentWidth) * 4
                        memcpy(target.baseAddress!.advanced(by: destination),
                               source.baseAddress!.advanced(by: origin), contentWidth * 4)
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

    private static func makeFixture(documentHeight: Int, denseThrough: Int,
                                    firstSparseRow: Int) -> Fixture {
        let fixed = render(width: width, height: height) { _ in
            NSColor(calibratedWhite: 0.97, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: CGFloat(fixedWidth), height: CGFloat(height)).fill()
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
                .foregroundColor: NSColor.darkGray
            ]
            for row in 0..<(height / 12 + 1) {
                let y = CGFloat(row * 12)
                String(format: "Task %03d  item-%04d.swift  Ready", row, row * 37 + 11)
                    .draw(at: NSPoint(x: 8, y: y), withAttributes: attributes)
                String(format: "Info %03d  read  count=%05d", row, row * 53 + 17)
                    .draw(at: NSPoint(x: 306, y: y), withAttributes: attributes)
                // Ordinary fixed table separators contribute genuine stable
                // edges; they must not vote that the separate body is still.
                NSColor(calibratedWhite: 0.60, alpha: 1).setFill()
                NSRect(x: 0, y: y + 11, width: CGFloat(fixedWidth), height: 1).fill()
            }
            NSColor.gray.setFill()
            NSRect(x: CGFloat(fixedWidth - 1), y: 0, width: 1, height: CGFloat(height)).fill()
        }
        let document = render(width: contentWidth, height: documentHeight) { _ in
            let denseAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular),
                .foregroundColor: NSColor.darkGray
            ]
            for y in stride(from: 0, to: min(denseThrough, documentHeight), by: 12) {
                let row = y / 12
                // Vary the indentation as well as the identifier, so this
                // dense control does not depend on resolving identical rows.
                let x = 8 + (row * 17) % 48
                String(format: "D%04d  value=%04d", y / 12, (y / 12) * 53 + 17)
                    .draw(at: NSPoint(x: CGFloat(x), y: CGFloat(y)), withAttributes: denseAttributes)
            }
            let sparseAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 8, weight: .regular),
                .foregroundColor: NSColor.darkGray
            ]
            for y in stride(from: firstSparseRow, to: documentHeight - 12, by: 220) {
                // Small, uniquely numbered native text with substantial blank
                // margins. Every 300-row overlap contains a complete record.
                let marker = (y - firstSparseRow) / 220
                String(format: "R%05d", marker * 37 + 11)
                    .draw(at: NSPoint(x: 12, y: CGFloat(y)), withAttributes: sparseAttributes)
            }
        }
        return Fixture(document: document, fixedViewport: fixed, documentHeight: documentHeight)
    }

    private static func render(width: Int, height: Int,
                               draw: (CGContext) -> Void) -> [UInt8] {
        let context = CGContext(data: nil, width: width, height: height,
                                bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        draw(context)
        NSGraphicsContext.restoreGraphicsState()
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { target in
            memcpy(target.baseAddress!, context.data!, target.count)
        }
        return bytes
    }

    private static func expectScrollingROI(_ stitcher: ScrollStitcher,
                                           follows document: [UInt8], expectedHeight: Int) throws {
        let image = try #require(stitcher.image)
        let data = try #require(image.dataProvider?.data) as Data
        let output = [UInt8](data)
        #expect(image.width == width)
        #expect(image.height == expectedHeight)
        let rows = min(image.height, expectedHeight)
        var differingRows: [Int] = []
        for y in 0..<rows {
            let actualStart = (y * width + fixedWidth) * 4
            let expectedStart = y * contentWidth * 4
            let matches = output[actualStart..<(actualStart + contentWidth * 4)].elementsEqual(
                document[expectedStart..<(expectedStart + contentWidth * 4)])
            if !matches {
                differingRows.append(y)
                if differingRows.count == 12 { break }
            }
        }
        #expect(differingRows.isEmpty, "Scrolling ROI differs from the known document at rows \(differingRows).")
    }
}
