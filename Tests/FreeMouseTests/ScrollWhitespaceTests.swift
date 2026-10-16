import CoreGraphics
import Foundation
import Testing
@testable import FreeMouse

@MainActor
struct ScrollWhitespaceTests {
    private let width = 320
    private let viewportHeight = 800

    @Test func whitespaceAroundUniqueBandPreservesOneHundredThirtySixPixelAdvance() throws {
        try verifyForwardAdvance(bands: [402..<462], advance: 136, expectedHeight: 936)
    }

    @Test func newlyVisibleBandDoesNotHideFourHundredPixelAdvance() throws {
        try verifyForwardAdvance(bands: [550..<610, 960..<1010],
                                 advance: 400, expectedHeight: 1200)
    }

    @Test func entirelyWhiteViewportDoesNotGrow() throws {
        let document = try makeDocument(height: 1600, bands: [])
        let first = try viewport(document, start: 0)
        let next = try viewport(document, start: 400)
        let stitcher = ScrollStitcher()
        let initial = try stitcher.append(first)
        let repeated = try stitcher.append(next)

        #expect(initial == .appended(viewportHeight))
        #expect(repeated == .duplicate)
        #expect(stitcher.frameCount == 1)
        #expect(stitcher.totalHeight == viewportHeight)
        let output = try #require(stitcher.image)
        let actualPixels = try normalized(output)
        let expectedPixels = try normalized(first)
        #expect(actualPixels == expectedPixels)
    }

    @Test func unrelatedBandWithoutCorrespondingOldContentIsRejected() throws {
        let document = try makeDocument(height: 1800, bands: [402..<462, 1100..<1160])
        let stitcher = ScrollStitcher()
        let initial = try stitcher.append(viewport(document, start: 0))
        #expect(initial == .appended(viewportHeight))
        let before = try normalized(try #require(stitcher.image))
        let unrelated = try viewport(document, start: 900)
        var rejected = false
        do {
            _ = try stitcher.append(unrelated)
        } catch CaptureError.noOverlap {
            rejected = true
        } catch {
            Issue.record("Unexpected rejection error: \(error)")
        }

        #expect(rejected)
        #expect(stitcher.frameCount == 1)
        #expect(stitcher.totalHeight == viewportHeight)
        let after = try normalized(try #require(stitcher.image))
        #expect(after == before)
    }

    @Test func fullyPeriodicContentWithMultipleValidOffsetsIsRejected() throws {
        let document = try makeDocument(height: 1800, bands: [0..<1800], period: 80)
        let stitcher = ScrollStitcher()
        let initial = try stitcher.append(viewport(document, start: 0))
        #expect(initial == .appended(viewportHeight))
        let before = try normalized(try #require(stitcher.image))
        // A 40px phase change is not stationary, but 40, 120, 200, ...
        // are equally supported translations of this exactly periodic page.
        let ambiguous = try viewport(document, start: 40)
        var rejected = false
        do {
            _ = try stitcher.append(ambiguous)
        } catch CaptureError.noOverlap {
            rejected = true
        } catch {
            Issue.record("Unexpected rejection error: \(error)")
        }

        #expect(rejected)
        #expect(stitcher.frameCount == 1)
        #expect(stitcher.totalHeight == viewportHeight)
        let after = try normalized(try #require(stitcher.image))
        #expect(after == before)
    }

    @Test func unrelatedBandsCannotUseAnEdgeOutsideWhiteOverlapAsEvidence() throws {
        let first = try makeDocument(height: viewportHeight, bands: [402..<462])
        let next = try makeDocument(height: viewportHeight, bands: [406..<466],
                                    codeSalt: 0xD6E8FEB86659FD93)
        let stitcher = ScrollStitcher()
        let initial = try stitcher.append(first)
        #expect(initial == .appended(viewportHeight))
        let before = try normalized(try #require(stitcher.image))
        var safelyDeclined = false
        do {
            let result = try stitcher.append(next)
            safelyDeclined = result == .duplicate
        } catch CaptureError.noOverlap {
            safelyDeclined = true
        } catch {
            Issue.record("Unexpected rejection error: \(error)")
        }

        // A false 196px shift compares old rows 462..<534 with new
        // rows 266..<338: entirely white. Old row 461 is outside that
        // overlap and cannot supply evidence for a document translation.
        #expect(safelyDeclined)
        #expect(stitcher.totalHeight == viewportHeight)
        #expect(stitcher.frameCount == 1)
        let after = try normalized(try #require(stitcher.image))
        #expect(after == before)
    }

    @Test func shorterExactPeriodicOverlapCannotOverrideLongerApproximateOverlap() throws {
        let document = try makeDocument(height: 1600, bands: [0..<1600], period: 312)
        let first = try viewport(document, start: 0)
        let translated = try viewport(document, start: 240)
        let next = try changingFourPixelPatch(translated, x: 158, y: 300)
        let stitcher = ScrollStitcher()
        let initial = try stitcher.append(first)
        #expect(initial == .appended(viewportHeight))
        let before = try normalized(try #require(stitcher.image))
        var safelyDeclined = false
        do {
            let result = try stitcher.append(next)
            safelyDeclined = result == .duplicate
        } catch CaptureError.noOverlap {
            safelyDeclined = true
        } catch {
            Issue.record("Unexpected rejection error: \(error)")
        }

        // The real 240px advance has 560px of almost identical overlap.
        // The periodic alias at 552px has only 248px, hiding the 4x4
        // change at new row 300. Exactness alone cannot choose that alias.
        #expect(safelyDeclined)
        #expect(stitcher.totalHeight == viewportHeight)
        #expect(stitcher.frameCount == 1)
        let after = try normalized(try #require(stitcher.image))
        #expect(after == before)
    }

    private func verifyForwardAdvance(bands: [Range<Int>], advance: Int,
                                      expectedHeight: Int) throws {
        let document = try makeDocument(height: 1600, bands: bands)
        let stitcher = ScrollStitcher()
        let initial = try stitcher.append(viewport(document, start: 0))
        let appended = try stitcher.append(viewport(document, start: advance))

        #expect(initial == .appended(viewportHeight))
        #expect(appended == .appended(advance))
        #expect(stitcher.frameCount == 2)
        #expect(stitcher.totalHeight == expectedHeight)
        let output = try #require(stitcher.image)
        let reference = try crop(document, start: 0, height: expectedHeight)
        #expect(output.width == width)
        #expect(output.height == expectedHeight)
        let actualPixels = try normalized(output)
        let expectedPixels = try normalized(reference)
        #expect(actualPixels == expectedPixels)
    }

    // The source bitmap has fixed top-relative rows. Two-pixel-wide cells
    // provide broad edge evidence; each row is deterministic and unique unless
    // an explicit period is requested by the ambiguity counterexample.
    private func makeDocument(height: Int, bands: [Range<Int>], period: Int? = nil,
                              codeSalt: UInt64 = 0) throws -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height where bands.contains(where: { $0.contains(y) }) {
            let row = period.map { y % $0 } ?? y
            for x in 24..<(width - 24) {
                var code = UInt64(row + 1) &* 0x9E3779B97F4A7C15
                code ^= UInt64(x / 2 + 1) &* 0xBF58476D1CE4E5B9
                code ^= codeSalt
                code ^= code >> 30
                code &*= 0x94D049BB133111EB
                code ^= code >> 27
                let index = (y * width + x) * 4
                bytes[index] = UInt8(20 + (code & 127))
                bytes[index + 1] = UInt8(20 + ((code >> 8) & 127))
                bytes[index + 2] = UInt8(20 + ((code >> 16) & 127))
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8,
                bitsPerPixel: 32, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw FixtureError.imageCreation
        }
        return image
    }

    private func viewport(_ document: CGImage, start: Int) throws -> CGImage {
        try crop(document, start: start, height: viewportHeight)
    }

    private func crop(_ document: CGImage, start: Int, height: Int) throws -> CGImage {
        guard let image = document.cropping(to: CGRect(x: 0, y: start, width: width, height: height)) else {
            throw FixtureError.crop
        }
        return image
    }

    private func changingFourPixelPatch(_ image: CGImage, x: Int, y: Int) throws -> CGImage {
        var bytes = try normalized(image)
        for row in y..<(y + 4) {
            for column in x..<(x + 4) {
                let index = (row * image.width + column) * 4
                bytes[index] ^= 0xFF
                bytes[index + 1] ^= 0xFF
                bytes[index + 2] ^= 0xFF
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let changed = CGImage(width: image.width, height: image.height,
                bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw FixtureError.imageCreation
        }
        return changed
    }

    private func normalized(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let rendered = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard rendered else { throw FixtureError.normalization }
        return bytes
    }

    private enum FixtureError: Error {
        case imageCreation, crop, normalization
    }
}
