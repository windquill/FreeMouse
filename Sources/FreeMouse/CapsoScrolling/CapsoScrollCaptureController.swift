// Copyright (c) 2026 lzhgus. Derived from Capso.
// BSL 1.1: ThirdParty/Capso/LICENSE; pinned revision: ThirdParty/Capso/REVISION.
import CoreGraphics
import Foundation
import Vision
@preconcurrency import ScreenCaptureKit

extension CapsoScrolling {
// Packages/CaptureKit/Sources/CaptureKit/Scrolling/ScrollCaptureController.swift

public struct ScrollCaptureConfig: Sendable {
    public let captureRect: CGRect
    public let displayID: CGDirectDisplayID
    public let mode: ScrollMode
    public let maxHeight: Int

    public init(
        captureRect: CGRect,
        displayID: CGDirectDisplayID,
        mode: ScrollMode = .manual,
        maxHeight: Int = 30_000
    ) {
        self.captureRect = captureRect
        self.displayID = displayID
        self.mode = mode
        self.maxHeight = maxHeight
    }
}

public enum ScrollMode: Sendable {
    case auto
    case manual
}

public struct ScrollCaptureProgress: Sendable {
    public let currentHeight: Int
    public let maxHeight: Int
    public let frameCount: Int
}

public final class ScrollCaptureController: @unchecked Sendable {
    private let config: ScrollCaptureConfig
    private let stitcher = ScrollStitcher()
    private let cancellationLock = NSLock()
    private var cancelled = false
    private var aborted = false
    private var isAborted: Bool {
        get { cancellationLock.lock(); defer { cancellationLock.unlock() }; return aborted }
        set { cancellationLock.lock(); defer { cancellationLock.unlock() }; aborted = newValue }
    }
    private var isCancelled: Bool {
        get { cancellationLock.lock(); defer { cancellationLock.unlock() }; return cancelled }
        set { cancellationLock.lock(); defer { cancellationLock.unlock() }; cancelled = newValue }
    }
    private var frameCount = 0
    public var onIssue: (@Sendable (String?) -> Void)?
    public private(set) var completionIssue: String?

    private func reportIssue(_ message: String?) {
        completionIssue = message
        onIssue?(message)
    }

    /// A/B frame model. `shotA` is the last frame that was stitched.
    private var shotA: CGImage?
    private var fixedRegions: FixedRegions?

    /// Cached ScreenCaptureKit objects (created once, reused)
    private var cachedFilter: SCContentFilter?
    private var cachedStreamConfig: SCStreamConfiguration?

    public var currentMergedImage: CGImage? { stitcher.mergedImage }

    public init(config: ScrollCaptureConfig) {
        self.config = config
    }

    public func start(
        onProgress: @escaping @Sendable (ScrollCaptureProgress) -> Void,
        onComplete: @escaping @Sendable (CGImage?) -> Void
    ) {
        Task.detached(priority: .utility) { [self] in
            let result = await self.runCaptureLoop(onProgress: onProgress)
            onComplete(result)
        }
    }

    public func stop() {
        isCancelled = true
    }

    public func cancel() {
        isAborted = true
        isCancelled = true
    }

    // MARK: - Capture Loop

    private func runCaptureLoop(
        onProgress: @escaping @Sendable (ScrollCaptureProgress) -> Void
    ) async -> CGImage? {
        // Capture initial frame
        guard !isAborted, let firstFrame = await captureFrame(), !isAborted else {
            return nil
        }
        stitcher.setInitialFrame(firstFrame)
        shotA = firstFrame
        frameCount = 1

        onProgress(ScrollCaptureProgress(
            currentHeight: stitcher.totalHeight,
            maxHeight: config.maxHeight,
            frameCount: frameCount
        ))

        // Main capture loop — runs until user clicks Done (isCancelled)
        // or max height is reached. No auto-stop on pause/jitter.
        var finishingPass = false
        repeat {
            if stitcher.totalHeight >= config.maxHeight { break }

            try? await Task.sleep(for: .milliseconds(150))
            guard !isAborted else { return nil }
            finishingPass = isCancelled

            guard let shotB = await captureFrame() else {
                reportIssue("未能读取最新画面，请检查屏幕录制权限。")
                continue
            }

            guard !isAborted else { return nil }

            // Skip if identical (user not scrolling)
            if let dataA = shotA?.dataProvider?.data,
               let dataB = shotB.dataProvider?.data,
               CFDataGetLength(dataA) == CFDataGetLength(dataB),
               memcmp(CFDataGetBytePtr(dataA)!, CFDataGetBytePtr(dataB)!, CFDataGetLength(dataA)) == 0 {
                reportIssue(nil)
                continue
            }

            let regions = fixedRegions ?? FixedRegions.detect(frame1: shotA!, frame2: shotB)
            let offset = Self.verticalOffset(from: shotA!, to: shotB, ignoring: regions)
            if Self.isStationaryViewport(from: shotA!, to: shotB, offset: offset) {
                // Approximate agreement must not erase a previously unconfirmed gap.
                continue
            }
            guard let offset, offset >= 3 else {
                reportIssue("这一段尚未接上，请向上滚回预览位置，再缓慢下滚。")
                continue
            }
            // Only learn sticky regions from an actual scroll, not a blinking caret.
            if fixedRegions == nil {
                fixedRegions = regions
                stitcher.setFooterHeight(regions.footer)
            }

            if case .stitched = stitcher.stitch(newFrame: shotB, detectedOffset: offset) {
                reportIssue(nil)
                shotA = shotB
                frameCount += 1
                onProgress(ScrollCaptureProgress(
                    currentHeight: stitcher.totalHeight,
                    maxHeight: config.maxHeight,
                    frameCount: frameCount
                ))
            } else {
                reportIssue("这一段尚未接上，请向上滚回预览位置，再缓慢下滚。")
            }
        } while !finishingPass

        return stitcher.mergedImage
    }

    /// Registration can invent a large displacement for a blinking caret on
    /// repeated text. Require strict RGB agreement to recognize the same viewport.
    static func isStationaryViewport(from earlier: CGImage, to later: CGImage, offset: Int?) -> Bool {
        guard offset != nil,
              earlier.width == later.width, earlier.height == later.height,
              earlier.width > 0, earlier.height > 0 else { return false }
        let (count, overflow) = earlier.width.multipliedReportingOverflow(by: earlier.height)
        guard !overflow, count <= Int.max / 4 else { return false }
        func pixels(_ image: CGImage) -> [UInt8]? {
            var bytes = [UInt8](repeating: 0, count: count * 4)
            let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(data: buffer.baseAddress,
                    width: image.width, height: image.height, bitsPerComponent: 8,
                    bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                return true
            }
            return rendered ? bytes : nil
        }
        guard let a = pixels(earlier), let b = pixels(later) else { return false }
        var changed = 0
        let budget = min(64, count / 2000) // Small caret only; never scale allowance to whole text lines.
        for i in stride(from: 0, to: a.count, by: 4) {
            if (0..<3).contains(where: { abs(Int(a[i + $0]) - Int(b[i + $0])) > 8 }) {
                changed += 1
                if changed > budget { return false }
            }
        }
        return true
    }

    // MARK: - Frame Capture

    private func captureFrame() async -> CGImage? {
        do {
            if cachedFilter == nil {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false, onScreenWindowsOnly: true
                )
                guard let display = content.displays.first(where: {
                    $0.displayID == config.displayID
                }) else {
                    return nil
                }

                let excludedBundleIDs: Set<String> = [
                    Bundle.main.bundleIdentifier ?? "",
                    "com.apple.dock",
                    "com.apple.controlcenter",
                    "com.apple.notificationcenterui",
                    "com.apple.Spotlight",
                ]
                let excludedWindows = content.windows.filter { window in
                    if window.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier { return true }
                    guard let bundleID = window.owningApplication?.bundleIdentifier else {
                        return false
                    }
                    return !bundleID.isEmpty && excludedBundleIDs.contains(bundleID)
                }

                let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)
                let streamConfig = SCStreamConfiguration()
                streamConfig.captureResolution = .best
                streamConfig.showsCursor = false
                streamConfig.sourceRect = config.captureRect
                let scale = CGFloat(filter.pointPixelScale)
                streamConfig.width = Int(config.captureRect.width * scale)
                streamConfig.height = Int(config.captureRect.height * scale)

                cachedFilter = filter
                cachedStreamConfig = streamConfig
            }

            guard let filter = cachedFilter, let cfg = cachedStreamConfig else {
                return nil
            }

            return try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: cfg
            )
        } catch {
            return nil
        }
    }

    // MARK: - Vision Offset Detection

    /// Rows that stay put while the page scrolls.
    struct FixedRegions: Equatable {
        var header = 0
        var footer = 0

        static func detect(frame1: CGImage, frame2: CGImage) -> FixedRegions {
            FixedRegions(
                header: HeaderDetector.detectHeaderHeight(frame1: frame1, frame2: frame2),
                footer: HeaderDetector.detectFooterHeight(frame1: frame1, frame2: frame2)
            )
        }

        func scrollingArea(in frame: CGImage) -> CGRect? {
            let rect = CGRect(
                x: 0, y: header,
                width: frame.width, height: frame.height - header - footer
            )
            return rect.height > 0 ? rect : nil
        }
    }

    /// How many pixel rows `later` is scrolled down relative to `earlier`
    /// (negative when scrolled up), measured only inside the scrolling area.
    static func verticalOffset(from earlier: CGImage, to later: CGImage, ignoring fixed: FixedRegions) -> Int? {
        guard let area = fixed.scrollingArea(in: earlier),
              let a = earlier.cropping(to: area),
              let b = later.cropping(to: area) else { return nil }

        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: a)
        do {
            try VNImageRequestHandler(cgImage: b, options: [:]).perform([request])
        } catch {
            return nil
        }
        guard let observation = request.results?.first as? VNImageTranslationAlignmentObservation else {
            return nil
        }
        return Int(observation.alignmentTransform.ty.rounded())
    }
}
}
