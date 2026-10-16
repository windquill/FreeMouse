import AppKit

final class ScrollStitcher {
    enum AppendResult: Equatable { case appended(Int), duplicate }
#if SCROLL_CAPTURE_DIAGNOSTICS
    var continuationDiagnosticProbeEnabled = false
#endif
    private let maxPixels: Int
    private var previous: Raster?
    private var pixels: [UInt8] = []
    private var height = 0
    private(set) var frameCount = 0
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
#if SCROLL_CAPTURE_DIAGNOSTICS
    private(set) var matchingDiagnostics: [[String: Any]] = []
#endif

    // No product-level output size cap. Keep RGBA byte counts representable;
    // callers that explicitly request a smaller budget still get that budget.
    init(maxPixels: Int = Int.max / 4) { self.maxPixels = max(1, min(maxPixels, Int.max / 4)) }

    var totalHeight: Int { height }
    var width: Int { previous?.width ?? 0 }

    var image: CGImage? {
        guard let previous, height > 0,
              let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: previous.width, height: height, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: previous.width * 4, space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Read only the visible bottom strip. The temporary provider borrows the
    /// buffer during synchronous drawing; the returned thumbnail owns its data.
    func preview(maxWidth: Int = 180, maxHeight: Int = 420) -> CGImage? {
        guard width > 0, height > 0, maxWidth > 0, maxHeight > 0 else { return nil }
        let previewWidth = min(width, maxWidth)
        let scale = Double(previewWidth) / Double(width)
        let previewHeight = min(maxHeight, max(1, Int(ceil(Double(height) * scale))))
        let sourceHeight = min(height, max(1, Int(ceil(Double(previewHeight) / scale))))
        let firstByte = (height - sourceHeight) * width * 4
        guard let context = CGContext(data: nil, width: previewWidth, height: previewHeight,
            bitsPerComponent: 8, bytesPerRow: previewWidth * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        return pixels.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress,
                  let provider = CGDataProvider(dataInfo: nil, data: base.advanced(by: firstByte),
                    size: bytes.count - firstByte, releaseData: { _, _, _ in }),
                  let bottom = CGImage(width: width, height: sourceHeight, bitsPerComponent: 8,
                    bitsPerPixel: 32, bytesPerRow: width * 4, space: colorSpace,
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                    provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
            context.interpolationQuality = .low
            context.draw(bottom, in: CGRect(x: 0, y: 0, width: previewWidth, height: previewHeight))
            return context.makeImage()
        }
    }

    func append(_ frame: CGImage) throws -> AppendResult {
#if SCROLL_CAPTURE_DIAGNOSTICS
        matchingDiagnostics.removeAll(keepingCapacity: true)
#endif
        guard frame.width >= 8, frame.height >= 24, frame.width <= 16_384,
              frame.height <= 16_384, frame.width * frame.height <= maxPixels else { throw CaptureError.limitReached }
        if let previous, previous.width != frame.width || previous.height != frame.height { throw CaptureError.sizeChanged }
        let next = try Raster(frame, colorSpace: colorSpace)
        guard let old = previous else {
            previous = next
            pixels = next.bytes
            height = next.height
            frameCount = 1
            return .appended(next.height)
        }
        // Same-position equality catches a stationary frame before the overlap
        // search, so repetitive/blank pages cannot grow without evidence.
        if old.bytes == next.bytes { return .duplicate }
        // A single exact, clamped RGB offset cannot establish document motion.
        // Check every opaque pixel, so a tiny scrolling body cannot disappear
        // inside a whole-frame average. Translucent pixels must stay unchanged.
        if hasOnlyUniformColorChange(old, next) {
            if edgeEvidence(old, next, shift: 0, top: 0, bottom: 0) { return .duplicate }
            throw CaptureError.noOverlap
        }
        var header = 0
        while header < old.height / 3, rowDifference(old, next, oldY: header, newY: header) < 0.7 { header += 1 }
        var footer = 0
        while footer < old.height / 3,
              rowDifference(old, next, oldY: old.height - footer - 1, newY: old.height - footer - 1) < 0.7 { footer += 1 }
        let minOverlap = max(20, old.height / 6)
        // Shared blank rows can look like fixed chrome. They do not reduce
        // the physical overlap between two viewports, so do not subtract them
        // again when deciding which translations may be searched.
        let maxShift = old.height - minOverlap
#if SCROLL_CAPTURE_DIAGNOSTICS
        matchingDiagnostics.append(["stage": "geometry", "height": old.height,
            "header": header, "footer": footer, "minimumPhysicalOverlap": minOverlap,
            "maximumShift": maxShift])
#endif
        guard maxShift >= 1 else { throw CaptureError.noOverlap }
        let stationaryColumns = stationaryColumns(old, next, top: header, bottom: footer)
        guard let offset = matchingOffset(old, next, top: header, bottom: footer, maxShift: maxShift,
                                         direction: 1, stationaryColumns: stationaryColumns) else {
            // Stable viewport structure must not hide a supported document
            // advance. Use approximate stillness only after forward matching.
            if difference(old, next, shift: 0, top: 0, bottom: 0, samples: 160) < 0.35,
               edgeEvidence(old, next, shift: 0, top: 0, bottom: 0) { return .duplicate }
            // Keep the last accepted viewport as the reference while the user
            // scrolls back. Returning to it cannot duplicate captured content.
            if matchingOffset(old, next, top: header, bottom: footer, maxShift: maxShift,
                              direction: -1, stationaryColumns: stationaryColumns) != nil {
                return .duplicate
            }
            throw CaptureError.noOverlap
        }
        let addedHeight = height.addingReportingOverflow(offset)
        guard !addedHeight.overflow else { throw CaptureError.limitReached }
        let newHeight = addedHeight.partialValue
        let pixelCount = old.width.multipliedReportingOverflow(by: newHeight)
        guard !pixelCount.overflow,
              pixelCount.partialValue <= maxPixels else { throw CaptureError.limitReached }
        // The old overlap is still provisional: a viewport-fixed panel may
        // have obscured it. Replace it with the newly visible content instead
        // of permanently committing the old bottom strip at every small step.
        // Skip the stationary header so it appears only once; the current
        // footer remains only at the final end of the assembled image.
        let overlapRows = old.height - header - offset
        pixels.removeLast(overlapRows * old.width * 4)
        pixels.append(contentsOf: next.bytes[(header * old.width * 4)...])
        height = newHeight
        previous = next
        frameCount += 1
        return .appended(offset)
    }

    private func matchingOffset(_ old: Raster, _ next: Raster, top: Int, bottom: Int,
                                maxShift: Int, direction: Int,
                                stationaryColumns: (identical: [Bool], structured: [Bool])) -> Int? {
        var candidates: [(offset: Int, score: Double)] = []
        let contentBottom = max(bottom, old.height - old.height * 4 / 5)
        func hasContentOverlap(_ offset: Int) -> Bool {
            old.height - contentBottom - max(1, top) - offset >= max(128, old.height / 6)
        }
        let sampled = SampledRasterPair(old, next, samples: 24,
                                        stationaryColumns: stationaryColumns.structured)
        // Scan every pixel offset: stepping by a coarse stride can entirely miss
        // the only true match on sharp text or a Retina display.
        for offset in 1...maxShift {
            let score = sampled.difference(shift: offset * direction, top: top, bottom: bottom,
                                           samples: 24, rejectingAbove: 12)
            // A fixed row grid can repeatedly hit subpixel stripe boundaries.
            // Dense rows can discover a candidate without increasing the error
            // limit. Background-only zero ties still use real edge anchors.
            let denseScore = sampled.difference(shift: offset * direction, top: top,
                bottom: bottom, samples: 24, rejectingAbove: 12, denseRows: true)
            let contentScore = hasContentOverlap(offset) ? sampled.difference(
                shift: offset * direction, top: top, bottom: contentBottom,
                samples: 24, rejectingAbove: 12, denseRows: true) : 255
            if score < 12 || denseScore < 12 || contentScore < 12 {
                candidates.append((offset, min(denseScore, contentScore)))
            }
        }
        candidates.sort { $0.score < $1.score }
#if SCROLL_CAPTURE_DIAGNOSTICS
        let coarseCandidates = candidates
#endif
        // A narrow column of content can sit between every coarse sample.
        // When background-only samples create many zero-score ties, rank
        // those candidates with a small, precomputed set of real edge points.
        // This keeps the exact match without re-scanning a full raster for
        // each possible offset, and still retains alternatives for ambiguity.
        if candidates.count > 12 {
            var anchors = alignmentAnchors(next, top: top, bottom: bottom,
                                           stationaryColumns: stationaryColumns.identical)
            let needsDenserPool = candidates.contains { candidate in
                let shift = candidate.offset * direction
                let start = max(1, top) + max(0, -shift)
                let end = old.height - bottom - max(0, shift)
                var count = 0
                for anchor in anchors where anchor.y >= start && anchor.y < end {
                    count += 1
                    if count >= 4 { return false }
                }
                return true
            }
            if needsDenserPool {
                anchors = denseAlignmentAnchors(next, top: top, bottom: bottom,
                                               stationaryColumns: stationaryColumns.identical)
            }
            if anchors.count >= 4 {
                candidates = candidates.map { candidate in
                    let full = anchorDifference(old, next, shift: candidate.offset * direction,
                        top: top, bottom: bottom, anchors: anchors)
                    let body = hasContentOverlap(candidate.offset) ? anchorDifference(old, next,
                        shift: candidate.offset * direction, top: top, bottom: contentBottom,
                        anchors: anchors) : 255
                    return (offset: candidate.offset, score: min(full, body))
                }.sorted { $0.score < $1.score }
            }
        }
        let refined = candidates.prefix(12).map { candidate in
            let shift = candidate.offset * direction
            let full = difference(old, next, shift: shift, top: top, bottom: bottom, samples: 96,
                stationaryColumns: stationaryColumns.structured, denseRows: true)
            // Use the same common body for both residual and shape evidence.
            // Otherwise a fixed fade can reject a correct shape, or make one
            // of several periodic translations look spuriously unique.
            let body = hasContentOverlap(candidate.offset) ? difference(old, next, shift: shift,
                top: top, bottom: contentBottom, samples: 96,
                stationaryColumns: stationaryColumns.structured, denseRows: true) : 255
            let bodyVerified = body < 5 && edgeEvidence(old, next, shift: shift, top: top,
                bottom: contentBottom, stationaryColumns: stationaryColumns.identical)
            let fullVerified = !bodyVerified && full < 5 && edgeEvidence(old, next, shift: shift, top: top,
                bottom: bottom, stationaryColumns: stationaryColumns.identical)
            return (offset: candidate.offset, score: bodyVerified ? body : full,
                    verified: bodyVerified || fullVerified,
                    evidenceBottom: bodyVerified ? contentBottom : bottom)
        }.sorted { $0.score < $1.score }
        // White margins dilute a whole-image average, while real antialiased
        // text can have low average texture. Require actual foreground edges
        // to agree instead of measuring how densely the page is textured.
        let supported = refined.filter { $0.verified }
#if SCROLL_CAPTURE_DIAGNOSTICS
        var diagnostic: [String: Any] = ["stage": "alignment", "direction": direction,
            "top": top, "bottom": bottom, "maximumShift": maxShift,
            "coarseCount": coarseCandidates.count,
            "coarseTop": coarseCandidates.prefix(20).map { ["offset": $0.offset, "score": $0.score] as [String: Any] },
            "rankedTop": candidates.prefix(20).map { ["offset": $0.offset, "score": $0.score] as [String: Any] },
            "refined": refined.map { candidate in
                ["offset": candidate.offset, "score": candidate.score,
                 "edgeVerified": candidate.verified,
                 "evidenceBottom": candidate.evidenceBottom] as [String: Any]
            }]
        diagnostic["probes"] = [40, 41, 100, 136, 160, 240, 400, 472, 552].filter { $0 <= maxShift }.map { offset in
            ["offset": offset,
             "coarseRank": coarseCandidates.firstIndex(where: { $0.offset == offset }) ?? -1,
             "rankedRank": candidates.firstIndex(where: { $0.offset == offset }) ?? -1,
             "refinedScore": difference(old, next, shift: offset * direction, top: top, bottom: bottom,
                samples: 96, stationaryColumns: stationaryColumns.structured, denseRows: true),
             "edgeVerified": edgeEvidence(old, next, shift: offset * direction, top: top,
                bottom: bottom, stationaryColumns: stationaryColumns.identical)] as [String: Any]
        }
        if continuationDiagnosticProbeEnabled, maxShift >= 100 {
            var probe = continuationGeometryProbe(old, next, shift: 100 * direction,
                                                  top: top, bottom: bottom,
                                                  stationaryColumns: stationaryColumns.identical)
            probe["offset"] = 100
            probe["coarseRank"] = coarseCandidates.firstIndex(where: { $0.offset == 100 }) ?? -1
            probe["rankedRank"] = candidates.firstIndex(where: { $0.offset == 100 }) ?? -1
            probe["refinedRank"] = refined.firstIndex(where: { $0.offset == 100 }) ?? -1
            probe["coarseScore"] = coarseCandidates.first(where: { $0.offset == 100 })?.score ?? -1
            probe["refinedScore"] = refined.first(where: { $0.offset == 100 })?.score ?? -1
            diagnostic["continuation100"] = probe
        }
#endif
        guard let best = supported.first else {
#if SCROLL_CAPTURE_DIAGNOSTICS
            diagnostic["decision"] = "no-supported-candidate"
            matchingDiagnostics.append(diagnostic)
#endif
            return nil
        }
        // Multiple equally good alignments indicate repeated content. Refuse to
        // guess rather than silently dropping or duplicating rows.
        if let alternative = supported.dropFirst().first(where: { abs($0.offset - best.offset) > 2 }),
           alternative.score < max(1, best.score * 1.4) {
            // Repeated cards can have a perfect long overlap and a shorter
            // approximate match whose small numeric differences are diluted
            // by whitespace. Resolve that case using every pixel, not a lower
            // error threshold. A longer plausible competitor or a second
            // exact translation still makes the movement ambiguous.
            let competitors = supported.dropFirst().filter {
                abs($0.offset - best.offset) > 2 && $0.score < max(1, best.score * 1.4)
            }
            if best.score == 0,
               competitors.allSatisfy({ $0.offset + $0.evidenceBottom > best.offset + best.evidenceBottom }),
               overlapIsIdentical(old, next, shift: best.offset * direction, top: top,
                   bottom: best.evidenceBottom, stationaryColumns: stationaryColumns.structured),
               competitors.allSatisfy({ candidate in
                   !overlapIsIdentical(old, next, shift: candidate.offset * direction,
                       top: top, bottom: candidate.evidenceBottom, stationaryColumns: stationaryColumns.structured)
               }) {
#if SCROLL_CAPTURE_DIAGNOSTICS
                diagnostic["decision"] = "longer-unique-exact-overlap"
                diagnostic["best"] = ["offset": best.offset, "score": best.score]
                matchingDiagnostics.append(diagnostic)
#endif
                return best.offset
            }
#if SCROLL_CAPTURE_DIAGNOSTICS
            diagnostic["decision"] = "ambiguous"
            diagnostic["best"] = ["offset": best.offset, "score": best.score]
            diagnostic["alternative"] = ["offset": alternative.offset, "score": alternative.score]
            diagnostic["bestPixelResidual"] = diagnosticPixelResidual(old, next,
                shift: best.offset * direction, top: top, bottom: bottom,
                stationaryColumns: stationaryColumns.identical)
            diagnostic["alternativePixelResidual"] = diagnosticPixelResidual(old, next,
                shift: alternative.offset * direction, top: top, bottom: bottom,
                stationaryColumns: stationaryColumns.identical)
            matchingDiagnostics.append(diagnostic)
#endif
            return nil
        }
#if SCROLL_CAPTURE_DIAGNOSTICS
        diagnostic["decision"] = "accepted"
        diagnostic["best"] = ["offset": best.offset, "score": best.score]
        matchingDiagnostics.append(diagnostic)
#endif
        return best.offset
    }

#if SCROLL_CAPTURE_DIAGNOSTICS
    /// Diagnostic-only counts preserve the production edge predicate and its
    /// boundary rule. They never add candidates or alter matching decisions.
    private func continuationGeometryProbe(_ old: Raster, _ next: Raster, shift: Int,
                                            top: Int, bottom: Int,
                                            stationaryColumns: [Bool]) -> [String: Any] {
        let fullStart = max(1, 0) + max(0, -shift)
        let fullEnd = old.height - max(0, shift)
        let croppedStart = max(1, top) + max(0, -shift)
        let croppedEnd = old.height - bottom - max(0, shift)
        let fallbackEnd = min(croppedEnd, old.height * 4 / 5 - shift, next.height * 4 / 5)
        let columnStep = max(1, old.width / 160)
        var probe: [String: Any] = [
            "shift": shift, "header": top, "footer": bottom,
            "anchorsCount": alignmentAnchors(next, top: top, bottom: bottom,
                                              stationaryColumns: stationaryColumns).count,
            "full": continuationEdgeCounts(old, next, shift: shift, start: fullStart, end: fullEnd,
                                             rowStep: 1, columnStep: 1,
                                             stationaryColumns: stationaryColumns),
            "cropped": continuationEdgeCounts(old, next, shift: shift, start: croppedStart, end: croppedEnd,
                                                rowStep: 1, columnStep: 1,
                                                stationaryColumns: stationaryColumns),
            "grid": continuationEdgeCounts(old, next, shift: shift, start: croppedStart, end: croppedEnd,
                                             rowStep: max(1, (croppedEnd - croppedStart) / 200),
                                             columnStep: columnStep,
                                             stationaryColumns: stationaryColumns)
        ]
        if fallbackEnd - croppedStart >= 20 {
            probe["fallbackGrid"] = continuationEdgeCounts(old, next, shift: shift,
                start: croppedStart, end: fallbackEnd,
                rowStep: max(1, (fallbackEnd - croppedStart) / 200), columnStep: columnStep,
                stationaryColumns: stationaryColumns)
        }
        return probe
    }

    private func continuationEdgeCounts(_ old: Raster, _ next: Raster, shift: Int,
                                        start: Int, end: Int, rowStep: Int, columnStep: Int,
                                        stationaryColumns: [Bool]) -> [String: Any] {
        let left = min(old.width / 10, 32)
        let right = old.width - left
        var support = 0
        var totalDifference = 0
        var mismatchedEdges = 0
        var firstEdgeRow = -1
        var lastEdgeRow = -1
        if end > start {
            for y in stride(from: start, to: end, by: rowStep) {
                guard y > start else { continue }
                for x in stride(from: max(1, left), to: right, by: columnStep) {
                    if stationaryColumns[x] { continue }
                    let a = ((y + shift) * old.width + x) * 4
                    let b = (y * next.width + x) * 4
                    var oldEdge = 0
                    var newEdge = 0
                    var delta = 0
                    for channel in 0..<3 {
                        oldEdge += abs(Int(old.bytes[a + channel]) - Int(old.bytes[a - 4 + channel]))
                        oldEdge += abs(Int(old.bytes[a + channel]) - Int(old.bytes[a - old.width * 4 + channel]))
                        newEdge += abs(Int(next.bytes[b + channel]) - Int(next.bytes[b - 4 + channel]))
                        newEdge += abs(Int(next.bytes[b + channel]) - Int(next.bytes[b - next.width * 4 + channel]))
                        delta += abs(Int(old.bytes[a + channel]) - Int(next.bytes[b + channel]))
                    }
                    guard min(oldEdge, newEdge) >= 24 else { continue }
                    if shift != 0, !hasMovingStructure(old, next, at: b) { continue }
                    support += 1
                    totalDifference += delta
                    if delta > 36 { mismatchedEdges += 1 }
                    if firstEdgeRow < 0 { firstEdgeRow = y }
                    lastEdgeRow = y
                }
            }
        }
        return ["start": start, "end": end, "rowStep": rowStep, "columnStep": columnStep,
                "support": support, "firstEdgeRow": firstEdgeRow, "lastEdgeRow": lastEdgeRow,
                "meanRGBChannelError": support > 0 ? Double(totalDifference) / Double(support * 3) : -1,
                "mismatchedEdges": mismatchedEdges,
                "mismatchedFraction": support > 0 ? Double(mismatchedEdges) / Double(support) : -1]
    }
#endif

    private func overlapIsIdentical(_ old: Raster, _ next: Raster, shift: Int,
        top: Int, bottom: Int, stationaryColumns: [Bool]) -> Bool {
        let start = top + max(0, -shift)
        let end = old.height - bottom - max(0, shift)
        guard end > start else { return false }
        let columns = (0..<old.width).filter { !stationaryColumns[$0] }
        guard !columns.isEmpty else { return false }
        for y in start..<end {
            for x in columns {
                let a = ((y + shift) * old.width + x) * 4
                let b = (y * next.width + x) * 4
                for channel in 0..<4 where old.bytes[a + channel] != next.bytes[b + channel] {
                    return false
                }
            }
        }
        return true
    }

#if SCROLL_CAPTURE_DIAGNOSTICS
    private func diagnosticPixelResidual(_ old: Raster, _ next: Raster, shift: Int,
        top: Int, bottom: Int, stationaryColumns: [Bool]) -> [String: Any] {
        let start = top + max(0, -shift)
        let end = old.height - bottom - max(0, shift)
        guard end > start else { return ["valid": false] }
        var count = 0, mismatches = 0
        var total: Int64 = 0
        for y in start..<end {
            for x in 0..<old.width where !stationaryColumns[x] {
                let a = ((y + shift) * old.width + x) * 4
                let b = (y * next.width + x) * 4
                var delta = 0
                for channel in 0..<3 {
                    delta += abs(Int(old.bytes[a + channel]) - Int(next.bytes[b + channel]))
                }
                count += 1
                if delta != 0 { mismatches += 1 }
                total += Int64(delta)
            }
        }
        return ["valid": count > 0, "comparedPixels": count, "mismatchedPixels": mismatches,
            "meanRGBDifference": count > 0 ? Double(total) / Double(count * 3) : 255]
    }
#endif

    private func alignmentAnchors(_ raster: Raster, top: Int, bottom: Int,
                                  stationaryColumns: [Bool]) -> [(x: Int, y: Int)] {
        let start = max(1, top)
        let end = min(raster.height - bottom, raster.height * 4 / 5)
        guard end > start else { return [] }
        let left = max(1, min(raster.width / 10, 32))
        let right = raster.width - min(raster.width / 10, 32)
        let middle = (left + right) / 2
        var anchors: [(x: Int, y: Int)] = []
        let initialStep = max(1, (end - start + 127) / 128)
        // A tiny real text run can fall between the coarse rows. Re-scan
        // actual edge pixels before abandoning candidate ranking, retaining
        // the same four-anchor requirement and excluding fixed structure.
        for rowStep in (initialStep == 1 ? [1] : [initialStep, 1]) {
            anchors.removeAll(keepingCapacity: true)
            for y in stride(from: start, to: end, by: rowStep) {
                var leftBest = (x: 0, energy: 23)
                var rightBest = (x: 0, energy: 23)
                for x in left..<right {
                    // Anchors compare this pixel and its left neighbor. Neither
                    // may belong to the fixed viewport structure being excluded.
                    if stationaryColumns[x] || stationaryColumns[x - 1] { continue }
                    let index = (y * raster.width + x) * 4
                    var energy = 0
                    for channel in 0..<3 {
                        energy += abs(Int(raster.bytes[index + channel]) - Int(raster.bytes[index - 4 + channel]))
                        energy += abs(Int(raster.bytes[index + channel]) - Int(raster.bytes[index - raster.width * 4 + channel]))
                    }
                    if x < middle {
                        if energy > leftBest.energy { leftBest = (x, energy) }
                    } else if energy > rightBest.energy { rightBest = (x, energy) }
                }
                if leftBest.x > 0 { anchors.append((leftBest.x, y)) }
                if rightBest.x > 0 { anchors.append((rightBest.x, y)) }
            }
            if anchors.count >= 4 { break }
        }
        return anchors
    }

    /// A candidate can clip away some globally available anchors. Keep a
    /// denser pool once per pair so its actual overlap can still supply four
    /// distinct edge pixels; the final 24-edge verifier remains unchanged.
    private func denseAlignmentAnchors(_ raster: Raster, top: Int, bottom: Int,
                                       stationaryColumns: [Bool]) -> [(x: Int, y: Int)] {
        let start = max(1, top)
        let end = min(raster.height - bottom, raster.height * 4 / 5)
        guard end > start else { return [] }
        let left = max(1, min(raster.width / 10, 32))
        let right = raster.width - min(raster.width / 10, 32)
        let middle = (left + right) / 2
        var anchors: [(x: Int, y: Int)] = []

        func retain(x: Int, energy: Int, in best: inout [(x: Int, energy: Int)]) {
            if best.count == 4, energy <= best[3].energy { return }
            let index = best.firstIndex(where: { energy > $0.energy }) ?? best.count
            best.insert((x: x, energy: energy), at: index)
            if best.count > 4 { best.removeLast() }
        }

        for y in start..<end {
            var leftBest: [(x: Int, energy: Int)] = []
            var rightBest: [(x: Int, energy: Int)] = []
            for x in left..<right {
                if stationaryColumns[x] || stationaryColumns[x - 1] { continue }
                let index = (y * raster.width + x) * 4
                var energy = 0
                for channel in 0..<3 {
                    energy += abs(Int(raster.bytes[index + channel]) - Int(raster.bytes[index - 4 + channel]))
                    energy += abs(Int(raster.bytes[index + channel]) - Int(raster.bytes[index - raster.width * 4 + channel]))
                }
                guard energy >= 24 else { continue }
                if x < middle {
                    retain(x: x, energy: energy, in: &leftBest)
                } else {
                    retain(x: x, energy: energy, in: &rightBest)
                }
            }
            anchors.append(contentsOf: leftBest.map { (x: $0.x, y: y) })
            anchors.append(contentsOf: rightBest.map { (x: $0.x, y: y) })
        }
        return anchors
    }

    private func anchorDifference(_ old: Raster, _ next: Raster, shift: Int, top: Int, bottom: Int,
        anchors: [(x: Int, y: Int)]) -> Double {
        let start = max(1, top) + max(0, -shift)
        let end = old.height - bottom - max(0, shift)
        var total = 0
        var count = 0
        for anchor in anchors where anchor.y >= start && anchor.y < end {
            let a = ((anchor.y + shift) * old.width + anchor.x) * 4
            let b = (anchor.y * next.width + anchor.x) * 4
            for displacement in [0, -4, -old.width * 4] {
                for channel in 0..<3 {
                    total += abs(Int(old.bytes[a + displacement + channel]) - Int(next.bytes[b + displacement + channel]))
                }
            }
            count += 1
        }
        return count >= 4 ? Double(total) / Double(count * 9) : 255
    }

    /// Verify the pixels which carry structure, so a wrong text alignment
    /// cannot pass merely because most of its sampled pixels are white.
    private func edgeEvidence(_ old: Raster, _ next: Raster, shift: Int, top: Int, bottom: Int,
                              stationaryColumns: [Bool]? = nil) -> Bool {
        let start = max(1, top) + max(0, -shift)
        let end = old.height - bottom - max(0, shift)
        guard end > start else { return false }
        if alignedEdges(old, next, shift: shift, start: start, end: end,
                        stationaryColumns: stationaryColumns) { return true }
        // Viewport-fixed controls near the lower edge may obscure otherwise
        // exact document content. They must not provide alignment evidence;
        // require the common content area above both lower boundaries instead.
        let contentEnd = min(end, old.height * 4 / 5 - shift, next.height * 4 / 5)
        if contentEnd < end, contentEnd - start >= 20,
           alignedEdges(old, next, shift: shift, start: start, end: contentEnd,
                        stationaryColumns: stationaryColumns) { return true }
        // Native text can be rasterized again during scrolling. A fixed
        // vertical three-tap comparison removes only its high-frequency
        // coverage variation; it never changes the stored/output pixels.
        // Keep the full overlap and verify raw structure too, so filtering
        // cannot turn unrelated high-frequency content into a match.
        guard shift != 0 else { return false }
        if antialiasedEdges(old, next, shift: shift, start: start, end: end,
                            stationaryColumns: stationaryColumns) { return true }
        // Text can change its rasterization phase independently in different
        // paragraphs. Validate the same candidate's signed, distributed shape
        // rather than demanding near-identical ink values at every edge.
        if gradientConsensus(old, next, shift: shift, start: start, end: end,
                             stationaryColumns: stationaryColumns) { return true }
        return contentEnd < end && contentEnd - start >= 20 && gradientConsensus(old, next, shift: shift,
            start: start, end: contentEnd, stationaryColumns: stationaryColumns)
    }

    private struct GradientAgreement {
        var first = 0.0, second = 0.0, product = 0.0
        mutating func add(_ a: Int, _ b: Int) {
            first += Double(a * a); second += Double(b * b); product += Double(a * b)
        }
        var correlation: Double {
            guard first > 0, second > 0 else { return -1 }
            return product / (first * second).squareRoot()
        }
    }

    /// A cheap reject-only pass. Acceptance always uses the dense tile check
    /// below. Sparse samples do not decide: sparse documents fall through to
    /// the complete scan. The loose angular gate avoids rescanning obvious
    /// wrong translations next to a correct text alignment.
    private func plausibleGradient(_ old: Raster, _ next: Raster, shift: Int,
                                   start: Int, end: Int, stationaryColumns: [Bool]?) -> Bool {
        let left = max(1, min(old.width / 10, 32))
        let right = min(old.width - 1, old.width - min(old.width / 10, 32))
        let rowBytes = old.width * 4
        var agreement = GradientAgreement(), points = 0
        for y in stride(from: start + 1, to: end - 1, by: max(1, (end - start) / 64)) {
            for x in stride(from: left, to: right, by: max(1, (right - left) / 64)) {
                if stationaryColumns?[x] == true { continue }
                let a = ((y + shift) * old.width + x) * 4, b = (y * next.width + x) * 4
                var point = GradientAgreement(), first = 0, second = 0
                for c in 0..<3 {
                    let ax = Int(old.bytes[a + 4 + c]) - Int(old.bytes[a - 4 + c])
                    let ay = Int(old.bytes[a + rowBytes + c]) - Int(old.bytes[a - rowBytes + c])
                    let bx = Int(next.bytes[b + 4 + c]) - Int(next.bytes[b - 4 + c])
                    let by = Int(next.bytes[b + rowBytes + c]) - Int(next.bytes[b - rowBytes + c])
                    point.add(ax, bx); point.add(ay, by)
                    first += abs(ax) + abs(ay); second += abs(bx) + abs(by)
                }
                if max(first, second) >= 24 {
                    points += 1
                    agreement.first += point.first; agreement.second += point.second
                    agreement.product += point.product
                }
            }
        }
        return points < 192 || agreement.correlation >= 0.90
    }

    /// Every textured tile contributes to the denominator, including missing
    /// and reversed edges. A small matching patch cannot excuse an unrelated
    /// body. Central differences tolerate coverage changes; one-pixel signed
    /// differences retain the high-frequency detail central differences lose.
    private func gradientConsensus(_ old: Raster, _ next: Raster, shift: Int,
                                   start: Int, end: Int, stationaryColumns: [Bool]?) -> Bool {
        guard shift != 0, end - start >= 128 else { return false }
        guard plausibleGradient(old, next, shift: shift, start: start, end: end,
                                stationaryColumns: stationaryColumns) else { return false }
        let left = max(1, min(old.width / 10, 32))
        let right = min(old.width - 1, old.width - min(old.width / 10, 32))
        let rowBytes = old.width * 4
        var energy = 0.0, matchedEnergy = 0.0
        var matchedTiles = 0, support = 0, verticalBands = 0
        var comparedPoints = 0, hiddenTextureChanges = 0
        for y0 in stride(from: start + 1, to: end - 1, by: 64) {
            let y1 = min(end - 1, y0 + 64)
            for x0 in stride(from: left, to: right, by: 64) {
                let x1 = min(right, x0 + 64)
                var raw = GradientAgreement(), centered = GradientAgreement(), stationary = GradientAgreement()
                var edgeCount = 0
                for y in y0..<y1 {
                    for x in x0..<x1 {
                        if stationaryColumns?[x] == true { continue }
                        let a = ((y + shift) * old.width + x) * 4
                        let b = (y * next.width + x) * 4
                        var rawPoint = GradientAgreement(), centerPoint = GradientAgreement()
                        var zeroPoint = GradientAgreement()
                        var strengthA = 0, strengthB = 0, centeredA = 0, centeredB = 0
                        var rawXResidual = 0, rawYResidual = 0, centerXResidual = 0, centerYResidual = 0
                        for c in 0..<3 {
                            let ax = Int(old.bytes[a + c]) - Int(old.bytes[a - 4 + c])
                            let ay = Int(old.bytes[a + c]) - Int(old.bytes[a - rowBytes + c])
                            let bx = Int(next.bytes[b + c]) - Int(next.bytes[b - 4 + c])
                            let by = Int(next.bytes[b + c]) - Int(next.bytes[b - rowBytes + c])
                            let acx = Int(old.bytes[a + 4 + c]) - Int(old.bytes[a - 4 + c])
                            let acy = Int(old.bytes[a + rowBytes + c]) - Int(old.bytes[a - rowBytes + c])
                            let bcx = Int(next.bytes[b + 4 + c]) - Int(next.bytes[b - 4 + c])
                            let bcy = Int(next.bytes[b + rowBytes + c]) - Int(next.bytes[b - rowBytes + c])
                            rawPoint.add(ax, bx); rawPoint.add(ay, by)
                            centerPoint.add(acx, bcx); centerPoint.add(acy, bcy)
                            zeroPoint.add(Int(old.bytes[b + 4 + c]) - Int(old.bytes[b - 4 + c]), bcx)
                            zeroPoint.add(Int(old.bytes[b + rowBytes + c]) - Int(old.bytes[b - rowBytes + c]), bcy)
                            rawXResidual += abs(ax - bx); rawYResidual += abs(ay - by)
                            centerXResidual += abs(acx - bcx); centerYResidual += abs(acy - bcy)
                            strengthA += abs(ax) + abs(ay); strengthB += abs(bx) + abs(by)
                            centeredA += abs(acx) + abs(acy); centeredB += abs(bcx) + abs(bcy)
                        }
                        guard max(strengthA, strengthB, centeredA, centeredB) >= 24 else { continue }
                        edgeCount += 1
                        comparedPoints += 1
                        // Central differences cancel a one-pixel alternating
                        // texture. Do not forgive large raw changes which
                        // disappear within the centered descriptor's rounding
                        // allowance (two levels per RGB channel).
                        if (rawXResidual > 72 && centerXResidual <= 6)
                            || (rawYResidual > 72 && centerYResidual <= 6) { hiddenTextureChanges += 1 }
                        raw.first += rawPoint.first; raw.second += rawPoint.second; raw.product += rawPoint.product
                        centered.first += centerPoint.first; centered.second += centerPoint.second
                        centered.product += centerPoint.product
                        stationary.first += zeroPoint.first; stationary.second += zeroPoint.second
                        stationary.product += zeroPoint.product
                    }
                }
                let tileEnergy = raw.first + raw.second + centered.first + centered.second
                energy += tileEnergy
                guard edgeCount > 0, raw.first > 0,
                      raw.second >= raw.first * 0.5, raw.second <= raw.first * 2,
                      raw.correlation >= 0.95, centered.correlation >= 0.98,
                      stationary.correlation <= centered.correlation - 0.05 else { continue }
                matchedEnergy += tileEnergy
                matchedTiles += 1; support += edgeCount
                verticalBands |= 1 << min(2, (y0 - start) * 3 / (end - start))
            }
        }
        return matchedTiles >= 6 && support >= 24 && verticalBands == 7
            && energy > 0 && matchedEnergy >= energy * 0.97
            && hiddenTextureChanges * 100 <= comparedPoints * 3
    }

    private func antialiasedEdges(_ old: Raster, _ next: Raster, shift: Int,
                                  start: Int, end: Int, stationaryColumns: [Bool]?) -> Bool {
        let rowStep = max(1, (end - start) / 200)
        let columnStep = max(1, old.width / 160)
        let left = max(1, min(old.width / 10, 32)), right = old.width - min(old.width / 10, 32)
        let stride = old.width * 4
        var support = 0, compared = 0, mismatches = 0
        var totalDifference = 0
        for y in Swift.stride(from: start, to: end, by: rowStep) {
            // The filter and the preceding-row descriptor must both stay
            // inside the shared comparison area, including at its boundaries.
            guard y > start + 1, y + 1 < end else { continue }
            for x in Swift.stride(from: left, to: right, by: columnStep) {
                if stationaryColumns?[x] == true { continue }
                let a = ((y + shift) * old.width + x) * 4
                let b = (y * next.width + x) * 4
                if !hasMovingStructure(old, next, at: b) { continue }
                var rawOldEdge = 0, rawNextEdge = 0, oldEdge = 0, nextEdge = 0
                var oldXStrength = 0, nextXStrength = 0, oldYStrength = 0, nextYStrength = 0
                var xDot = 0, yDot = 0, xDifference = 0, yDifference = 0
                var difference = 0, zeroDifference = 0
                for c in 0..<3 {
                    let ox = Int(old.bytes[a + c]) - Int(old.bytes[a - 4 + c])
                    let nx = Int(next.bytes[b + c]) - Int(next.bytes[b - 4 + c])
                    let oy = Int(old.bytes[a + c]) - Int(old.bytes[a - stride + c])
                    let ny = Int(next.bytes[b + c]) - Int(next.bytes[b - stride + c])
                    oldXStrength += abs(ox); nextXStrength += abs(nx)
                    oldYStrength += abs(oy); nextYStrength += abs(ny)
                    xDot += ox * nx; yDot += oy * ny
                    xDifference += abs(ox - nx); yDifference += abs(oy - ny)
                    rawOldEdge += abs(ox) + abs(oy); rawNextEdge += abs(nx) + abs(ny)
                    let av = verticalThreeTap(old, index: a, channel: c)
                    let bv = verticalThreeTap(next, index: b, channel: c)
                    oldEdge += abs(av - verticalThreeTap(old, index: a - 4, channel: c))
                        + abs(av - verticalThreeTap(old, index: a - stride, channel: c))
                    nextEdge += abs(bv - verticalThreeTap(next, index: b - 4, channel: c))
                        + abs(bv - verticalThreeTap(next, index: b - stride, channel: c))
                    difference += abs(av - bv)
                    zeroDifference += abs(verticalThreeTap(old, index: b, channel: c) - bv)
                }
                // Use the union for errors: missing/new edges may not vanish
                // from the denominator just because only one frame has them.
                guard max(rawOldEdge, rawNextEdge) >= 24 || max(oldEdge, nextEdge) >= 24 * 4 else { continue }
                compared += 1; totalDifference += difference
                if min(rawOldEdge, rawNextEdge) >= 24,
                   min(oldEdge, nextEdge) >= 24 * 4, zeroDifference > 0 { support += 1 }
                let reversed = (min(oldXStrength, nextXStrength) >= 24 && xDot <= 0)
                    || (min(oldYStrength, nextYStrength) >= 24 && yDot <= 0)
                // A first difference spans two pixels. Its raw discrepancy
                // can be no greater than twice the existing 36-level pixel
                // tolerance; this catches texture erased by the low-pass.
                if difference > 36 * 4 || reversed || xDifference > 2 * 36 || yDifference > 2 * 36 {
                    mismatches += 1
                }
            }
        }
        return support >= 24 && totalDifference < compared * 3 * 3 * 4
            && mismatches * 100 <= compared * 3
    }

    /// Four times the [1, 2, 1]/4 result, without rounding or image allocation.
    @inline(__always) private func verticalThreeTap(_ raster: Raster, index: Int, channel: Int) -> Int {
        let stride = raster.width * 4
        return Int(raster.bytes[index - stride + channel]) + 2 * Int(raster.bytes[index + channel])
            + Int(raster.bytes[index + stride + channel])
    }

    /// A structured column identical throughout the comparison body is fixed
    /// evidence, not evidence for a document translation. Header animation must
    /// not release the same column's stationary sidebar text. Test all body rows so sparse text is
    /// not mistaken for a stationary sidebar because a sampling grid misses it.
    /// Keep constant background columns: they cannot oppose a vertical shift,
    /// and excluding them would change the established average-error scale.
    /// The broader identical mask still keeps those columns from voting as
    /// movement edges, including a stationary vertical separator.
    private func stationaryColumns(_ old: Raster, _ next: Raster, top: Int, bottom: Int) -> (identical: [Bool], structured: [Bool]) {
        var identical = [Bool](repeating: true, count: old.width)
        var structure = [Bool](repeating: false, count: old.width)
        let start = min(old.height, max(0, top))
        let end = max(start, min(old.height, old.height - bottom))
        // Read the contiguous body rows once instead of revisiting a full
        // column's distant cache lines for every x. A failed column remains
        // failed, exactly as with the former early break in the column loop.
        for y in start..<end {
            for x in 0..<old.width where identical[x] {
                let index = (y * old.width + x) * 4
                if old.bytes[index] != next.bytes[index] ||
                    old.bytes[index + 1] != next.bytes[index + 1] ||
                    old.bytes[index + 2] != next.bytes[index + 2] {
                    identical[x] = false
                    structure[x] = false
                    continue
                }
                if y > start {
                    let above = index - old.width * 4
                    let energy = abs(Int(old.bytes[index]) - Int(old.bytes[above]))
                        + abs(Int(old.bytes[index + 1]) - Int(old.bytes[above + 1]))
                        + abs(Int(old.bytes[index + 2]) - Int(old.bytes[above + 2]))
                    if energy >= 24 { structure[x] = true }
                }
            }
        }
        return (identical, structure)
    }

    /// The discovery pass repeatedly compares the same sparse RGB columns at
    /// every possible vertical offset. Pack those exact samples once per pair
    /// so the hot loop uses contiguous, vectorized integer arithmetic. Padding
    /// lanes are zero in both frames and never enter the sample count. Reduce
    /// at most eight blocks at once: 8 * 16 * 255 = 32640 fits in Int16, so both
    /// vector accumulation and its horizontal sum stay exact without overflow.
    /// No rows, offsets, columns, thresholds, or candidate decisions are removed.
    private struct SampledRasterPair {
        let old: [SIMD16<Int16>]
        let next: [SIMD16<Int16>]
        let height: Int
        let blocksPerRow: Int
        let channelsPerRow: Int

        init(_ oldRaster: Raster, _ nextRaster: Raster, samples: Int,
             stationaryColumns: [Bool]) {
            height = oldRaster.height
            let columnStep = max(1, oldRaster.width / min(64, samples))
            let left = min(oldRaster.width / 10, 32)
            let right = oldRaster.width - left
            let columns = stride(from: left, to: right, by: columnStep).filter {
                !stationaryColumns[$0]
            }
            channelsPerRow = columns.count * 3
            blocksPerRow = (channelsPerRow + 15) / 16
            var oldValues = [SIMD16<Int16>](repeating: .zero, count: height * blocksPerRow)
            var nextValues = [SIMD16<Int16>](repeating: .zero, count: height * blocksPerRow)
            for y in 0..<height {
                var lane = 0
                for x in columns {
                    let pixel = (y * oldRaster.width + x) * 4
                    for channel in 0..<3 {
                        let block = y * blocksPerRow + lane / 16
                        oldValues[block][lane % 16] = Int16(oldRaster.bytes[pixel + channel])
                        nextValues[block][lane % 16] = Int16(nextRaster.bytes[pixel + channel])
                        lane += 1
                    }
                }
            }
            old = oldValues
            next = nextValues
        }

        func difference(shift: Int, top: Int, bottom: Int, samples: Int,
                        rejectingAbove: Int, denseRows: Bool = false) -> Double {
            let start = top + max(0, -shift)
            let end = height - bottom - max(0, shift)
            guard end > start, channelsPerRow > 0 else { return 255 }
            let rowStep = denseRows ? 1 : max(1, (end - start) / samples)
            let count = ((end - start + rowStep - 1) / rowStep) * channelsPerRow
            let limit = rejectingAbove * count
            return old.withUnsafeBufferPointer { oldBuffer in
                next.withUnsafeBufferPointer { nextBuffer in
                    var total = 0
                    var partial = SIMD16<Int16>.zero
                    var partialBlocks = 0
                    for y in stride(from: start, to: end, by: rowStep) {
                        let oldRow = (y + shift) * blocksPerRow
                        let nextRow = y * blocksPerRow
                        for block in 0..<blocksPerRow {
                            let delta = oldBuffer[oldRow + block] &- nextBuffer[nextRow + block]
                            let absolute = delta.replacing(with: .zero &- delta, where: delta .< .zero)
                            partial &+= absolute
                            partialBlocks += 1
                            if partialBlocks == 8 {
                                total += Int(partial.wrappedSum())
                                partial = .zero
                                partialBlocks = 0
                                if total > limit { return 255 }
                            }
                        }
                    }
                    total += Int(partial.wrappedSum())
                    if total > limit { return 255 }
                    return Double(total) / Double(count)
                }
            }
        }
    }

    private func alignedEdges(_ old: Raster, _ next: Raster, shift: Int, start: Int, end: Int,
                              stationaryColumns: [Bool]?) -> Bool {
        let rowStep = max(1, (end - start) / 200)
        let columnStep = max(1, old.width / 160)
        let left = min(old.width / 10, 32)
        let right = old.width - left
        var support = 0
        var totalDifference = 0
        var mismatchedEdges = 0
        var edges: [(old: Int, next: Int)] = []
        for y in stride(from: start, to: end, by: rowStep) {
            // The preceding row is part of the edge descriptor. Do not use
            // a boundary outside the common area as evidence of translation.
            guard y > start else { continue }
            for x in stride(from: max(1, left), to: right, by: columnStep) {
                if stationaryColumns?[x] == true { continue }
                let a = ((y + shift) * old.width + x) * 4
                let b = (y * next.width + x) * 4
                var oldEdge = 0
                var newEdge = 0
                var delta = 0
                for channel in 0..<3 {
                    oldEdge += abs(Int(old.bytes[a + channel]) - Int(old.bytes[a - 4 + channel]))
                    oldEdge += abs(Int(old.bytes[a + channel]) - Int(old.bytes[a - old.width * 4 + channel]))
                    newEdge += abs(Int(next.bytes[b + channel]) - Int(next.bytes[b - 4 + channel]))
                    newEdge += abs(Int(next.bytes[b + channel]) - Int(next.bytes[b - next.width * 4 + channel]))
                    delta += abs(Int(old.bytes[a + channel]) - Int(next.bytes[b + channel]))
                }
                guard min(oldEdge, newEdge) >= 24 else { continue }
                // Repeating viewport-fixed text must not vote for a scroll,
                // even if an unrelated header animation changed its column.
                if shift != 0, !hasMovingStructure(old, next, at: b) { continue }
                support += 1
                edges.append((a, b))
                totalDifference += delta
                if delta > 36 { mismatchedEdges += 1 }
            }
        }
        guard support >= 24 else { return false }
        if totalDifference < support * 3 * 3 && mismatchedEdges * 100 <= support * 3 { return true }
        // Fractional scrolling changes antialiased edge pixels even when the
        // document has a unique overlap. Fit one shared subpixel translation,
        // then apply exactly the same residual/error requirements as above.
        // Fitting either frame also handles returning from a fractional phase
        // to a sharp integer phase without treating each edge independently.
        for resampleOld in [true, false] {
            for direction in [-1, 1] {
                if interpolatedEdges(old, next, edges: edges,
                                     resampleOld: resampleOld, direction: direction) { return true }
            }
        }
        return false
    }

    private func interpolatedEdges(_ old: Raster, _ next: Raster,
                                   edges: [(old: Int, next: Int)],
                                   resampleOld: Bool, direction: Int) -> Bool {
        let source = resampleOld ? old : next
        let target = resampleOld ? next : old
        let displacement = direction * source.width * 4
        var numerator = 0.0, denominator = 0.0
        var usable: [(source: Int, target: Int)] = []
        for edge in edges {
            let a = resampleOld ? edge.old : edge.next
            let b = resampleOld ? edge.next : edge.old
            guard a + displacement >= 0, a + displacement + 2 < source.bytes.count else { continue }
            usable.append((a, b))
            for channel in 0..<3 {
                let delta = Double(Int(source.bytes[a + displacement + channel]) - Int(source.bytes[a + channel]))
                let wanted = Double(Int(target.bytes[b + channel]) - Int(source.bytes[a + channel]))
                numerator += delta * wanted
                denominator += delta * delta
            }
        }
        guard usable.count >= 24, denominator > 0 else { return false }
        let fraction = min(0.5, max(0, numerator / denominator))
        guard fraction > 0 else { return false }
        var totalDifference = 0.0, mismatchedEdges = 0
        for edge in usable {
            var delta = 0.0
            for channel in 0..<3 {
                let first = Double(source.bytes[edge.source + channel])
                let neighbor = Double(source.bytes[edge.source + displacement + channel])
                delta += abs(first + fraction * (neighbor - first) - Double(target.bytes[edge.target + channel]))
            }
            totalDifference += delta
            if delta > 36 { mismatchedEdges += 1 }
        }
        return totalDifference < Double(usable.count * 3 * 3) && mismatchedEdges * 100 <= usable.count * 3
    }

    /// A locally unchanged pixel cannot prove a scroll just because an
    /// unrelated animation released the same column from the fixed mask.
    /// Fractional motion may preserve a gradient, so do not reject gradients.
    private func hasMovingStructure(_ old: Raster, _ next: Raster, at index: Int) -> Bool {
        var zeroPixelDifference = 0
        for channel in 0..<3 {
            let oldValue = Int(old.bytes[index + channel])
            let nextValue = Int(next.bytes[index + channel])
            zeroPixelDifference += abs(oldValue - nextValue)
        }
        return zeroPixelDifference > 0
    }

    private func hasOnlyUniformColorChange(_ old: Raster, _ next: Raster) -> Bool {
        var lower = [-255, -255, -255]
        var upper = [255, 255, 255]
        var opaquePixels = 0
        for index in stride(from: 0, to: old.bytes.count, by: 4) {
            guard old.bytes[index + 3] == next.bytes[index + 3] else { return false }
            if old.bytes[index + 3] != 255 {
                for channel in 0..<3 where old.bytes[index + channel] != next.bytes[index + channel] {
                    return false
                }
                continue
            }
            opaquePixels += 1
            for channel in 0..<3 {
                let a = Int(old.bytes[index + channel])
                let b = Int(next.bytes[index + channel])
                if b == 0 {
                    upper[channel] = min(upper[channel], -a)
                } else if b == 255 {
                    lower[channel] = max(lower[channel], 255 - a)
                } else {
                    let delta = b - a
                    lower[channel] = max(lower[channel], delta)
                    upper[channel] = min(upper[channel], delta)
                }
                if lower[channel] > upper[channel] { return false }
            }
        }
        return opaquePixels > 0
    }

    private func difference(_ old: Raster, _ new: Raster, shift: Int, top: Int, bottom: Int,
                            samples: Int, rejectingAbove: Int? = nil, stationaryColumns: [Bool]? = nil,
                            denseRows: Bool = false) -> Double {
        let start = top + max(0, -shift)
        let end = old.height - bottom - max(0, shift)
        guard end > start else { return 255 }
        let rowStep = denseRows ? 1 : max(1, (end - start) / samples)
        let columnStep = max(1, old.width / min(64, samples))
        let left = min(old.width / 10, 32)
        let right = old.width - left
        let columns = stride(from: left, to: right, by: columnStep).filter {
            stationaryColumns?[$0] != true
        }
        guard !columns.isEmpty else { return 255 }
        let count = ((end - start + rowStep - 1) / rowStep) * columns.count * 3
        let limit = rejectingAbove.map { $0 * count } ?? Int.max
        var total = 0
        for y in stride(from: start, to: end, by: rowStep) {
            for x in columns {
                let a = ((y + shift) * old.width + x) * 4
                let b = (y * new.width + x) * 4
                for channel in 0..<3 {
                    total += abs(Int(old.bytes[a + channel]) - Int(new.bytes[b + channel]))
                }
                // This is a lower bound on the complete score, not an
                // approximate match: rejected offsets cannot pass the cutoff.
                if total > limit { return 255 }
            }
        }
        return count > 0 ? Double(total) / Double(count) : 255
    }

    private func rowDifference(_ old: Raster, _ new: Raster, oldY: Int, newY: Int) -> Double {
        var total = 0
        var count = 0
        for x in stride(from: 0, to: old.width, by: max(1, old.width / 64)) {
            let a = (oldY * old.width + x) * 4
            let b = (newY * new.width + x) * 4
            for channel in 0..<3 {
                total += abs(Int(old.bytes[a + channel]) - Int(new.bytes[b + channel]))
                count += 1
            }
        }
        return Double(total) / Double(max(1, count))
    }

    private struct Raster {
        let width: Int
        let height: Int
        let bytes: [UInt8]
        init(_ image: CGImage, colorSpace: CGColorSpace) throws {
            let width = image.width
            let height = image.height
            var buffer = [UInt8](repeating: 0, count: width * height * 4)
            let succeeded = buffer.withUnsafeMutableBytes { bytes -> Bool in
                guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.interpolationQuality = .none
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard succeeded else { throw CaptureError.unavailableImage }
            self.width = width
            self.height = height
            self.bytes = buffer
        }
    }
}
