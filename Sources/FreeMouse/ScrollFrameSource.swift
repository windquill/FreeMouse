import AppKit
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import OSLog
import ScreenCaptureKit

/// Window identity only: titles and other applications' metadata never leave capture setup.
struct ScrollWindowIdentity {
    let windowID: CGWindowID
    let ownerPID: pid_t?
    let ownerBundleID: String?
}

enum ScrollWindowExclusion {
    static func knownWindowIDs(from numbers: [Int]) -> Set<CGWindowID> {
        Set(numbers.compactMap { number in
            // Internal AppKit windows can return a positive sentinel larger
            // than UInt32 (NSStatusBarWindow returned 2^32 on macOS 27).
            // Never truncate it or use a trapping narrowing conversion.
            guard let id = CGWindowID(exactly: number), id > 0 else { return nil }
            return id
        })
    }

    static func ids(in windows: [ScrollWindowIdentity], ownPID: pid_t,
                    ownBundleID: String?, knownOwnWindowIDs: Set<CGWindowID>) -> Set<CGWindowID> {
        Set(windows.filter { window in
            if knownOwnWindowIDs.contains(window.windowID) || window.ownerPID == ownPID { return true }
            guard let ownBundleID, !ownBundleID.isEmpty else { return false }
            return window.ownerBundleID == ownBundleID
        }.map(\.windowID))
    }
}

struct ScrollVideoFrame {
    let image: CGImage
    let sequence: UInt64
    let timestamp: TimeInterval
}

/// Preserve every bridge frame within explicit frame and pixel budgets.
final class ScrollFrameBuffer {
    static let defaultMaximumPixels = 24_000_000
    private let lock = NSLock()
    private let maximumFrames: Int
    private let maximumPixels: Int
    private var token: UUID?
    private var pending: [ScrollVideoFrame] = []
    private var pendingPixels = 0
    private var sequence: UInt64 = 0
    private var errorMessage: String?
    private var backpressured = false
    private var publicationSuspended = false
    private var deferredSequence: UInt64 = 0
    private var isPaused = false
    // The serial native producer can have one conversion in flight. Allocate
    // its ordinal before conversion so a pause or seal can report its loss.
    private var preparedSequence: UInt64?
    private var preparedFrameIsValid = false

    init(maxFrames: Int = 8, maxPixels: Int = ScrollFrameBuffer.defaultMaximumPixels) {
        precondition(maxFrames > 0 && maxPixels > 0)
        maximumFrames = maxFrames
        maximumPixels = maxPixels
    }

    var failure: String? { locked { errorMessage } }
    var isBackpressured: Bool { locked { backpressured } }
    var lastDeferredSequence: UInt64 { locked { deferredSequence } }
    var lastSampleSequence: UInt64 { locked { sequence } }
    var hasPendingFrames: Bool {
        locked { !pending.isEmpty || (preparedSequence != nil && preparedFrameIsValid) }
    }

    func begin() -> UUID {
        locked {
            let next = UUID()
            token = next
            pending.removeAll(keepingCapacity: true)
            pendingPixels = 0
            errorMessage = nil
            backpressured = false
            publicationSuspended = false
            deferredSequence = 0
            isPaused = false
            preparedSequence = nil
            preparedFrameIsValid = false
            return next
        }
    }

    func isActive(token: UUID) -> Bool { locked { self.token == token } }

    /// Check before allocating immutable pixels. Every complete native sample
    /// gets an ordinal here; publish reuses it after conversion.
    func prepareFrame(width: Int, height: Int, token: UUID) -> Bool {
        locked {
            guard self.token == token else { return false }
            sequence &+= 1
            guard !isPaused else {
                recordUnmatchedLocked(sequence)
                return false
            }
            guard let pixelCount = framePixelCount(width: width, height: height) else {
                failLocked(frameCapacityMessage(width: width, height: height), token: token)
                return false
            }
            guard !publicationSuspended, pending.count < maximumFrames,
                  pixelCount <= maximumPixels - pendingPixels else {
                deferFrameLocked(sequence)
                return false
            }
            // Between this check and publish, only the consumer can change the
            // queue size. Pause/stop invalidate publication separately.
            preparedSequence = sequence
            preparedFrameIsValid = true
            return true
        }
    }

    func setPaused(_ paused: Bool, token: UUID) {
        locked {
            guard self.token == token else { return }
            isPaused = paused
            guard paused else { return }
            if let last = pending.last { recordUnmatchedLocked(last.sequence) }
            if let preparedSequence { recordUnmatchedLocked(preparedSequence) }
            // Keep the ordinal until this conversion returns, so a rapid resume
            // cannot accept the discarded image as a fresh direct publication.
            preparedFrameIsValid = false
            pending.removeAll(keepingCapacity: true)
            pendingPixels = 0
            backpressured = false
            publicationSuspended = false
            // A pause without queued/in-flight frames does not invent a gap.
        }
    }

    func publish(_ image: CGImage, timestamp: TimeInterval, token: UUID) {
        locked {
            guard self.token == token else { return }
            let frameSequence: UInt64
            if let preparedSequence {
                frameSequence = preparedSequence
                self.preparedSequence = nil
                let valid = preparedFrameIsValid
                preparedFrameIsValid = false
                guard valid, !isPaused else {
                    recordUnmatchedLocked(frameSequence)
                    return
                }
            } else {
                // Keep direct publication compatible with callers that do not
                // use native admission, including its rejected-sample ordinals.
                sequence &+= 1
                frameSequence = sequence
                guard !isPaused else {
                    recordUnmatchedLocked(frameSequence)
                    return
                }
            }
            guard let pixelCount = framePixelCount(width: image.width, height: image.height) else {
                failLocked(frameCapacityMessage(width: image.width, height: image.height), token: token)
                return
            }
            if publicationSuspended || pending.count >= maximumFrames ||
                pixelCount > maximumPixels - pendingPixels {
                // Preserve every accepted bridge; transient pressure must not
                // tear down the stream or silently replace the oldest image.
                deferFrameLocked(frameSequence)
                return
            }
            pending.append(ScrollVideoFrame(image: image, sequence: frameSequence, timestamp: timestamp))
            pendingPixels += pixelCount
            refreshPressureLocked()
        }
    }

    func invalidate(token: UUID) {
        locked {
            guard self.token == token else { return }
            self.token = nil
            pending.removeAll(keepingCapacity: true)
            pendingPixels = 0
            backpressured = false
            publicationSuspended = false
            deferredSequence = 0
            isPaused = false
            preparedSequence = nil
            preparedFrameIsValid = false
        }
    }

    func fail(_ message: String, token: UUID) {
        locked {
            guard self.token == token else { return }
            failLocked(message, token: token)
        }
    }

    func latestFrame(after sequence: UInt64) -> ScrollVideoFrame? {
        locked {
            guard let newest = pending.last, newest.sequence > sequence else { return nil }
            return newest
        }
    }

    func nextFrame(after sequence: UInt64) -> ScrollVideoFrame? {
        locked {
            while let first = pending.first, first.sequence <= sequence {
                let removed = pending.removeFirst()
                pendingPixels -= removed.image.width * removed.image.height
            }
            refreshPressureLocked()
            guard !pending.isEmpty else { return nil }
            let next = pending.removeFirst()
            pendingPixels -= next.image.width * next.image.height
            refreshPressureLocked()
            return next
        }
    }

    func discardPending(token: UUID) {
        locked {
            guard self.token == token else { return }
            pending.removeAll(keepingCapacity: true)
            pendingPixels = 0
            backpressured = false
            publicationSuspended = false
            deferredSequence = 0
        }
    }

    func sealPreservingPending(token: UUID) {
        locked {
            guard self.token == token else { return }
            // Late output and stop callbacks are rejected, while nextFrame can
            // continue draining the immutable images accepted before sealing.
            if let preparedSequence { recordUnmatchedLocked(preparedSequence) }
            preparedSequence = nil
            preparedFrameIsValid = false
            self.token = nil
        }
    }

    private func failLocked(_ message: String, token: UUID) {
        self.token = nil
        pending.removeAll(keepingCapacity: true)
        pendingPixels = 0
        backpressured = false
        publicationSuspended = false
        isPaused = false
        preparedSequence = nil
        preparedFrameIsValid = false
        errorMessage = message
    }

    private func framePixelCount(width: Int, height: Int) -> Int? {
        guard width > 0, height > 0 else { return nil }
        let size = width.multipliedReportingOverflow(by: height)
        guard !size.overflow, size.partialValue <= maximumPixels else { return nil }
        return size.partialValue
    }

    private func frameCapacityMessage(width: Int, height: Int) -> String {
        "单帧截图 \(width) × \(height) px 超过帧缓存安全容量，请缩小选区后重试。已有截图可保存。"
    }

    private func recordUnmatchedLocked(_ ordinal: UInt64) {
        deferredSequence = max(deferredSequence, ordinal)
    }

    private func deferFrameLocked(_ ordinal: UInt64) {
        publicationSuspended = true
        backpressured = true
        recordUnmatchedLocked(ordinal)
    }

    private func refreshPressureLocked() {
        if pending.count <= maximumFrames / 4 && pendingPixels <= maximumPixels / 4 {
            backpressured = false
            publicationSuspended = false
        } else if pending.count >= max(1, maximumFrames / 2) ||
                    pendingPixels >= max(1, maximumPixels / 2) {
            backpressured = true
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private enum ScrollFrameSourceError: LocalizedError {
    case busy
    var errorDescription: String? { "滚动采集正在启动、进行或停止，请等待当前操作完成。" }
}

/// Receives bounded native frames on a serial queue without hopping to the UI actor.
private final class ScrollFrameSink: NSObject, SCStreamOutput, SCStreamDelegate {
    let queue = DispatchQueue(label: "FreeMouse.scroll-video", qos: .userInitiated)
    private let buffer: ScrollFrameBuffer
    private let token: UUID
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    // Lazy initialization also keeps Core Image setup off the main actor.
    private lazy var context = CIContext(options: [.cacheIntermediates: false])

    init(buffer: ScrollFrameBuffer, token: UUID) {
        self.buffer = buffer
        self.token = token
        super.init()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, buffer.isActive(token: token),
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer,
                  createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int,
              status == SCFrameStatus.complete.rawValue,
              let pixels = sampleBuffer.imageBuffer,
              buffer.prepareFrame(width: CVPixelBufferGetWidth(pixels),
                                  height: CVPixelBufferGetHeight(pixels), token: token) else { return }
        autoreleasepool {
            let input = CIImage(cvPixelBuffer: pixels)
            // Render eagerly: the published immutable image must outlive the reusable IOSurface.
            guard let image = context.createCGImage(input, from: input.extent,
                format: .BGRA8, colorSpace: colorSpace, deferred: false) else {
                buffer.fail(CaptureError.unavailableImage.localizedDescription, token: token)
                return
            }
            let timestamp = CMTimeGetSeconds(sampleBuffer.presentationTimeStamp)
            buffer.publish(image,
                timestamp: timestamp.isFinite ? timestamp : ProcessInfo.processInfo.systemUptime,
                token: token)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        buffer.fail(error.localizedDescription, token: token)
    }
}

@MainActor
private final class ScrollFrameSession {
    let token: UUID
    let sink: ScrollFrameSink
    var stream: SCStream?
    var outputInstalled = false
    var startup: Task<Void, Error>?
    var cleanup: Task<Void, Never>?

    init(token: UUID, buffer: ScrollFrameBuffer) {
        self.token = token
        sink = ScrollFrameSink(buffer: buffer, token: token)
    }
}

@MainActor
final class ScrollFrameSource: NSObject {
    private static let logger = Logger(subsystem: "local.freemouse.toolbox", category: "ScrollCapture")
    private let buffer = ScrollFrameBuffer()
    private var session: ScrollFrameSession?
    private var stopping: Task<Void, Never>?
    private var finalCapture: (filter: SCContentFilter, configuration: SCStreamConfiguration)?

    var failure: String? { buffer.failure }
    var isBackpressured: Bool { buffer.isBackpressured }
    var lastDeferredSequence: UInt64 { buffer.lastDeferredSequence }
    var hasPendingFrames: Bool { buffer.hasPendingFrames }

    func latestFrame(after sequence: UInt64) -> ScrollVideoFrame? {
        buffer.latestFrame(after: sequence)
    }

    func nextFrame(after sequence: UInt64) -> ScrollVideoFrame? {
        buffer.nextFrame(after: sequence)
    }

    func discardPending() {
        guard let session else { return }
        buffer.discardPending(token: session.token)
    }

    func setPaused(_ paused: Bool) {
        guard let session else { return }
        buffer.setPaused(paused, token: session.token)
    }

    /// Native streams may deliver the last changed viewport after our quiet
    /// timer. After stopping and draining, take one fresh screenshot using
    /// exactly the same region, resolution, and excluded overlay windows.
    func captureFinalFrame(after sequence: UInt64) async throws -> ScrollVideoFrame {
        guard session == nil, stopping == nil, let finalCapture else {
            throw CaptureError.unavailableImage
        }
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: finalCapture.filter, configuration: finalCapture.configuration)
        try Task.checkCancellation()
        let ordinal = max(sequence, buffer.lastSampleSequence)
        guard ordinal < UInt64.max else { throw CaptureError.limitReached }
        return ScrollVideoFrame(image: image, sequence: ordinal + 1,
            timestamp: CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())))
    }

    func start(region: CaptureRegion) async throws {
        guard session == nil, stopping == nil else { throw ScrollFrameSourceError.busy }
        finalCapture = nil
        let current = ScrollFrameSession(token: buffer.begin(), buffer: buffer)
        session = current
        let startup = Task { @MainActor in
            do {
                try await self.prepare(current, region: region)
            } catch {
                self.buffer.fail(error.localizedDescription, token: current.token)
                await self.teardown(current)
                throw error
            }
        }
        current.startup = startup
        do {
            try await withTaskCancellationHandler {
                try await startup.value
            } onCancel: {
                startup.cancel()
            }
            try Task.checkCancellation()
            guard session === current, buffer.isActive(token: current.token) else {
                throw CancellationError()
            }
        } catch {
            buffer.fail(error.localizedDescription, token: current.token)
            await teardown(current)
            if session === current { session = nil }
            throw error
        }
    }

    func stop(preservingPending: Bool = false) async {
        if let stopping { await stopping.value; return }
        guard let current = session else { return }
        // Close publication before awaiting native stop. Successful completion
        // retains its bridge frames; cancellation releases pending images.
        if preservingPending { buffer.sealPreservingPending(token: current.token) }
        else { buffer.invalidate(token: current.token) }
        session = nil
        current.startup?.cancel()
        let cleanup = Task { @MainActor in
            // Native start must settle before native stop; otherwise a late start can leak.
            if let startup = current.startup { _ = try? await startup.value }
            await self.teardown(current)
        }
        stopping = cleanup
        await cleanup.value
        stopping = nil
    }

    private func prepare(_ current: ScrollFrameSession, region: CaptureRegion) async throws {
        let rect = region.rect
        guard rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.width.isFinite, rect.height.isFinite,
              rect.minX >= 0, rect.minY >= 0, rect.width >= 1, rect.height >= 1,
              region.scale.isFinite, region.scale > 0 else { throw CaptureError.invalidRegion }
        let pixelRect = region.pixelRect
        guard pixelRect.width.isFinite, pixelRect.height.isFinite,
              pixelRect.width >= 1, pixelRect.height >= 1,
              pixelRect.width <= 16_384, pixelRect.height <= 16_384,
              pixelRect.width * pixelRect.height <= Double(ScrollFrameBuffer.defaultMaximumPixels) else {
            throw CaptureError.invalidRegion
        }
        try ensureCurrent(current)
        // Keep hidden windows in the inventory: panels may be ordered or moved while
        // capture starts. The same immutable window IDs remain excluded throughout it.
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        try ensureCurrent(current)
        guard let display = content.displays.first(where: { $0.displayID == region.displayID }) else {
            throw CaptureError.noDisplay
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let knownOwnWindowIDs = ScrollWindowExclusion.knownWindowIDs(from: NSApp.windows.map(\.windowNumber))
        let identities = content.windows.map {
            ScrollWindowIdentity(windowID: $0.windowID, ownerPID: $0.owningApplication?.processID,
                                 ownerBundleID: $0.owningApplication?.bundleIdentifier)
        }
        let excludedIDs = ScrollWindowExclusion.ids(in: identities, ownPID: ownPID,
            ownBundleID: Bundle.main.bundleIdentifier, knownOwnWindowIDs: knownOwnWindowIDs)
        let ownWindows = content.windows.filter { excludedIDs.contains($0.windowID) }
        // Explicit IDs also exclude ownerless panels and another running copy of this
        // bundle. In an application-exclusion filter, exceptingWindows would REINCLUDE
        // windows belonging to that application, so it is unsuitable for this list.
        let filter = SCContentFilter(display: display, excludingWindows: ownWindows)
        let ownAppCount = content.applications.filter { $0.processID == ownPID }.count
        let knownCount = knownOwnWindowIDs.count
        let excludedCount = ownWindows.count
        Self.logger.info("Scroll setup: current app entries=\(ownAppCount, privacy: .public), own window IDs=\(knownCount, privacy: .public), excluded windows=\(excludedCount, privacy: .public)")
        filter.includeMenuBar = true
        guard CGRect(origin: .zero, size: filter.contentRect.size).contains(rect) else {
            throw CaptureError.invalidRegion
        }
        let config = SCStreamConfiguration()
        // Only output dimensions are pixels; sourceRect remains display-local top-left points.
        config.sourceRect = rect
        config.width = Int(pixelRect.width)
        config.height = Int(pixelRect.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 15)
        config.queueDepth = 3
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.captureDynamicRange = .SDR
        config.captureResolution = .best
        config.showsCursor = false
        config.showMouseClicks = false
        config.capturesAudio = false
        config.captureMicrophone = false
        finalCapture = (filter, config)
        let stream = SCStream(filter: filter, configuration: config, delegate: current.sink)
        current.stream = stream
        try stream.addStreamOutput(current.sink, type: .screen, sampleHandlerQueue: current.sink.queue)
        current.outputInstalled = true
        try await stream.startCapture()
        try ensureCurrent(current)
    }

    private func ensureCurrent(_ current: ScrollFrameSession) throws {
        try Task.checkCancellation()
        guard session === current, buffer.isActive(token: current.token) else {
            throw CancellationError()
        }
    }

    private func teardown(_ current: ScrollFrameSession) async {
        if let cleanup = current.cleanup { await cleanup.value; return }
        guard let stream = current.stream else { return }
        let cleanup = Task { @MainActor in
            try? await stream.stopCapture()
            if current.outputInstalled {
                try? stream.removeStreamOutput(current.sink, type: .screen)
                current.outputInstalled = false
            }
            current.stream = nil
        }
        current.cleanup = cleanup
        await cleanup.value
    }
}
