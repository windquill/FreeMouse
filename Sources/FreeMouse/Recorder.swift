import Foundation
import Combine
import CoreGraphics
import ScreenCaptureKit
import AVFoundation

/// Serializes recording ownership and ignores delegates from earlier sessions.
struct RecordingLifecycle {
    enum Phase { case idle, preparing, recording, finishing }
    private(set) var phase: Phase = .idle
    private(set) var token: UUID?
    var isBusy: Bool { phase != .idle }
    var isRecording: Bool { phase == .recording }
    mutating func begin() throws -> UUID {
        guard !isBusy else { throw RecordingError.busy }
        let next = UUID()
        token = next
        phase = .preparing
        return next
    }
    mutating func started(_ token: UUID) -> Bool {
        guard self.token == token, phase == .preparing else { return false }
        phase = .recording
        return true
    }
    mutating func beginFinishing(_ token: UUID) -> Bool {
        guard self.token == token, phase == .preparing || phase == .recording else { return false }
        phase = .finishing
        return true
    }
    mutating func finish(_ token: UUID) -> Bool {
        guard self.token == token, phase == .finishing else { return false }
        self.token = nil
        phase = .idle
        return true
    }
    mutating func fail(_ token: UUID) -> Bool {
        guard self.token == token, phase != .idle else { return false }
        self.token = nil
        phase = .idle
        return true
    }
}

enum RecordingError: LocalizedError {
    case busy, invalidRegion, invalidDestination, existingFile, microphoneDenied
    case displayUnavailable, unsupportedFormat, startupTimeout, finishTimeout, emptyOutput
    case saveFailed(recoveryURL: URL, reason: String)
    var errorDescription: String? {
        switch self {
        case .busy: return "录制正在启动、进行或保存，请等待当前操作完成。"
        case .invalidRegion: return "录制区域无效或尺寸过大，请重新选择区域。"
        case .invalidDestination: return "请选择可写文件夹中的 MP4 文件。"
        case .existingFile: return "目标文件已经存在，请选择另一个文件名。"
        case .microphoneDenied: return "无法访问麦克风，请在系统设置中授权，或关闭麦克风录制。"
        case .displayUnavailable: return "所选显示器已断开，请重新选择录制区域。"
        case .unsupportedFormat: return "当前系统不支持 H.264 MP4 录制。"
        case .startupTimeout: return "录制未能及时启动，请检查屏幕录制权限后重试。"
        case .finishTimeout: return "录制文件未能及时完成，未报告保存成功。"
        case .emptyOutput: return "录制没有生成有效的视频文件。"
        case .saveFailed(let url, let reason): return "保存到目标路径失败：\(reason)\n已完成的视频保留在：\(url.path)"
        }
    }
}

@MainActor
final class Recorder: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isBusy = false
    @Published private(set) var elapsed: TimeInterval = 0
    var onFinished: ((URL) -> Void)?
    var onError: ((String) -> Void)?

    private var lifecycle = RecordingLifecycle()
    private var stream: SCStream?
    private var output: SCRecordingOutput?
    private var destination: URL?
    private var temporaryURL: URL?
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var stopContinuation: CheckedContinuation<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var clockTask: Task<Void, Never>?
    private var beganAt: TimeInterval = 0
    private var captureStarted = false
    private var outputStarted = false
    private var captureStopped = false
    private var outputFinished = false
    private var ending = false
    private let cameraOverlay = CameraOverlayController()
    private var cameraStop: Task<Void, Never>?
    private var cameraIssue: Error?
    private var finalizingFile = false

    func start(region: CaptureRegion, to url: URL, systemAudio: Bool, microphone: Bool, fps: Int, camera: Bool = false) async throws {
        let token = try lifecycle.begin()
        elapsed = 0
        publishState()
        do {
            guard url.isFileURL, url.pathExtension.lowercased() == "mp4",
                  FileManager.default.isWritableFile(atPath: url.deletingLastPathComponent().path) else {
                throw RecordingError.invalidDestination
            }
            guard !FileManager.default.fileExists(atPath: url.path) else { throw RecordingError.existingFile }
            guard fps == 30 || fps == 60, region.scale.isFinite, region.scale > 0,
                  region.rect.origin.x.isFinite, region.rect.origin.y.isFinite,
                  region.rect.width.isFinite, region.rect.height.isFinite,
                  region.rect.minX >= 0, region.rect.minY >= 0,
                  region.rect.width >= 2, region.rect.height >= 2,
                  region.rect.width * region.scale <= 8192,
                  region.rect.height * region.scale <= 8192 else { throw RecordingError.invalidRegion }
            if microphone {
                switch AVCaptureDevice.authorizationStatus(for: .audio) {
                case .authorized: break
                case .notDetermined:
                    guard await AVCaptureDevice.requestAccess(for: .audio) else { throw RecordingError.microphoneDenied }
                default: throw RecordingError.microphoneDenied
                }
            }
            try Task.checkCancellation()
            var cameraID: CGWindowID?
            if camera {
                cameraOverlay.onFailure = { [weak self] error in
                    guard let self, self.lifecycle.token == token, !self.ending else { return }
                    self.cameraIssue = error
                    if self.lifecycle.phase == .recording {
                        // Finish the existing MP4 rather than deleting a recording after camera loss.
                        self.requestStop(token: token)
                    } else if self.lifecycle.phase == .preparing, self.startContinuation != nil {
                        Task { await self.failSession(token: token, error: error) }
                    }
                }
                cameraID = try await cameraOverlay.start(region: region)
            }
            try ensurePreparing(token)
            let filter = try await recordingFilter(region: region, cameraID: cameraID, token: token)
            try ensurePreparing(token)
            // SC sourceRect uses display-local logical points; only output dimensions use Retina scale.
            let displayBounds = CGRect(origin: .zero, size: filter.contentRect.size)
            guard displayBounds.contains(region.rect) else { throw RecordingError.invalidRegion }
            let configuration = SCStreamConfiguration()
            configuration.sourceRect = region.rect
            configuration.width = max(2, Int(region.rect.width * region.scale) / 2 * 2)
            configuration.height = max(2, Int(region.rect.height * region.scale) / 2 * 2)
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
            configuration.queueDepth = 5
            configuration.showsCursor = true
            configuration.capturesAudio = systemAudio
            configuration.captureMicrophone = microphone
            configuration.excludesCurrentProcessAudio = true
            configuration.sampleRate = 48_000
            configuration.channelCount = 2
            configuration.captureDynamicRange = .SDR

            // Record to an owned sibling first. moveItem refuses an existing final destination,
            // including a file created by another process while this recording was running.
            let temporary = url.deletingLastPathComponent().appendingPathComponent(".freemouse-recording-\(UUID().uuidString).mp4")
            guard !FileManager.default.fileExists(atPath: temporary.path) else { throw RecordingError.existingFile }
            let recordingConfiguration = SCRecordingOutputConfiguration()
            recordingConfiguration.outputURL = temporary
            guard recordingConfiguration.availableVideoCodecTypes.contains(.h264),
                  recordingConfiguration.availableOutputFileTypes.contains(.mp4) else { throw RecordingError.unsupportedFormat }
            recordingConfiguration.videoCodecType = .h264
            recordingConfiguration.outputFileType = .mp4
            let recording = SCRecordingOutput(configuration: recordingConfiguration, delegate: self)
            let nativeStream = SCStream(filter: filter, configuration: configuration, delegate: self)
            destination = url
            temporaryURL = temporary
            output = recording
            stream = nativeStream
            try nativeStream.addRecordingOutput(recording)
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    startContinuation = continuation
                    setDeadline(seconds: 20, token: token, error: RecordingError.startupTimeout)
                    nativeStream.startCapture { [weak self] error in
                        Task { @MainActor in
                            guard let self, self.lifecycle.token == token, !self.ending else { return }
                            if let error { await self.failSession(token: token, error: error) }
                            else { self.captureStarted = true; self.resolveStart(token: token) }
                        }
                    }
                }
            } onCancel: {
                Task { @MainActor [weak self] in await self?.failSession(token: token, error: CancellationError()) }
            }
        } catch {
            // Delegate/timeout failures already released the session and resumed the continuation.
            if lifecycle.token == token { await failSession(token: token, error: error, report: false) }
            throw error
        }
    }

    func stop() async {
        guard let token = lifecycle.token, lifecycle.phase == .recording else { return }
        await withCheckedContinuation { continuation in
            stopContinuation = continuation
            requestStop(token: token)
        }
    }

    private func ensurePreparing(_ token: UUID) throws {
        try Task.checkCancellation()
        guard lifecycle.token == token, lifecycle.phase == .preparing, !ending else { throw CancellationError() }
        if let cameraIssue { throw cameraIssue }
    }

    private func recordingFilter(region: CaptureRegion, cameraID: CGWindowID?, token: UUID) async throws -> SCContentFilter {
        // A freshly shown window may take a short time to reach the WindowServer list.
        for attempt in 0..<12 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            try ensurePreparing(token)
            guard let display = content.displays.first(where: { $0.displayID == region.displayID }) else {
                throw RecordingError.displayUnavailable
            }
            let pid = ProcessInfo.processInfo.processIdentifier
            let ownApps = content.applications.filter { $0.processID == pid }
            if let cameraID {
                if !ownApps.isEmpty, let window = content.windows.first(where: {
                    $0.windowID == cameraID && $0.owningApplication?.processID == pid
                }) {
                    return SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [window])
                }
                if attempt < 11 { try await Task.sleep(nanoseconds: 100_000_000) }
            } else {
                return SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
            }
        }
        throw CameraOverlayError.windowUnavailable
    }

    private func closeCamera() {
        cameraOverlay.onFailure = nil
        if cameraStop == nil { cameraStop = cameraOverlay.stop() }
    }

    private func publishState() {
        isRecording = lifecycle.isRecording
        isBusy = lifecycle.isBusy
    }

    private func resolveStart(token: UUID) {
        guard captureStarted, outputStarted, !ending, lifecycle.started(token) else { return }
        deadline?.cancel()
        deadline = nil
        beganAt = ProcessInfo.processInfo.systemUptime
        publishState()
        let continuation = startContinuation
        startContinuation = nil
        continuation?.resume()
        clockTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled, let self, self.lifecycle.token == token,
                      self.lifecycle.phase == .recording else { return }
                self.elapsed = ProcessInfo.processInfo.systemUptime - self.beganAt
            }
        }
    }

    private func requestStop(token: UUID) {
        guard lifecycle.beginFinishing(token), let nativeStream = stream else { return }
        closeCamera()
        elapsed = max(elapsed, ProcessInfo.processInfo.systemUptime - beganAt)
        clockTask?.cancel()
        publishState()
        setDeadline(seconds: 30, token: token, error: RecordingError.finishTimeout)
        nativeStream.stopCapture { [weak self] error in
            Task { @MainActor in
                guard let self, self.lifecycle.token == token, !self.ending else { return }
                if let error { await self.failSession(token: token, error: error) }
                else { self.captureStopped = true; await self.resolveFinish(token: token) }
            }
        }
    }

    private func resolveFinish(token: UUID) async {
        guard captureStopped, outputFinished, lifecycle.token == token, !ending, !finalizingFile,
              let temporary = temporaryURL, let destination else { return }
        finalizingFile = true
        closeCamera()
        if let cameraStop { await cameraStop.value }
        guard lifecycle.token == token, !ending else { return }
        var hasFinalizedFile = false
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: temporary.path)
            guard let size = attributes[.size] as? NSNumber, size.int64Value > 0 else { throw RecordingError.emptyOutput }
            hasFinalizedFile = true
            try FileManager.default.moveItem(at: temporary, to: destination)
            guard lifecycle.finish(token) else { return }
            let continuation = stopContinuation
            stopContinuation = nil
            let cameraMessage = cameraIssue?.localizedDescription
            clearResources()
            publishState()
            continuation?.resume()
            onFinished?(destination)
            if let cameraMessage { onError?(cameraMessage + "\n录屏已停止，已完成的视频已保存：" + destination.path) }
        } catch {
            let reportedError: Error = hasFinalizedFile
                ? RecordingError.saveFailed(recoveryURL: temporary, reason: error.localizedDescription) : error
            await failSession(token: token, error: reportedError, preserveRecording: hasFinalizedFile)
        }
    }

    private func failSession(token: UUID, error: Error, report: Bool = true, preserveRecording: Bool = false) async {
        guard lifecycle.token == token, !ending else { return }
        ending = true
        closeCamera()
        _ = lifecycle.beginFinishing(token)
        publishState()
        deadline?.cancel()
        clockTask?.cancel()
        // Keep the session busy until the native stop callback or cleanup deadline.
        if let nativeStream = stream { await stopForCleanup(nativeStream) }
        if let cameraStop { await cameraStop.value }
        let start = startContinuation
        let stop = stopContinuation
        startContinuation = nil
        stopContinuation = nil
        if !preserveRecording, let temporary = temporaryURL { try? FileManager.default.removeItem(at: temporary) }
        _ = lifecycle.fail(token)
        clearResources()
        publishState()
        start?.resume(throwing: error)
        stop?.resume()
        // A failed start is returned by throws; later failures use the UI callback once.
        if report && start == nil { onError?(error.localizedDescription) }
    }

    private func stopForCleanup(_ nativeStream: SCStream) async {
        await withCheckedContinuation { continuation in
            var resumed = false
            let timeout = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard !Task.isCancelled, !resumed else { return }
                resumed = true
                continuation.resume()
            }
            nativeStream.stopCapture { _ in
                Task { @MainActor in
                    guard !resumed else { return }
                    resumed = true
                    timeout.cancel()
                    continuation.resume()
                }
            }
        }
    }

    private func setDeadline(seconds: UInt64, token: UUID, error: Error) {
        deadline?.cancel()
        deadline = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.failSession(token: token, error: error)
        }
    }

    private func clearResources() {
        deadline?.cancel(); deadline = nil
        clockTask?.cancel(); clockTask = nil
        stream = nil
        output = nil
        destination = nil
        temporaryURL = nil
        captureStarted = false
        outputStarted = false
        captureStopped = false
        outputFinished = false
        ending = false
        finalizingFile = false
        cameraStop = nil
        cameraIssue = nil
        cameraOverlay.onFailure = nil
    }
}

extension Recorder: SCRecordingOutputDelegate, SCStreamDelegate {
    nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor [weak self] in
            guard let self, self.output === recordingOutput, let token = self.lifecycle.token, !self.ending else { return }
            self.outputStarted = true
            self.resolveStart(token: token)
        }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, self.output === recordingOutput, let token = self.lifecycle.token else { return }
            await self.failSession(token: token, error: error)
        }
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor [weak self] in
            guard let self, self.output === recordingOutput, let token = self.lifecycle.token, !self.ending else { return }
            guard self.lifecycle.phase != .preparing else {
                await self.failSession(token: token, error: RecordingError.emptyOutput)
                return
            }
            self.outputFinished = true
            if self.lifecycle.phase == .recording { self.requestStop(token: token) }
            await self.resolveFinish(token: token)
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, self.stream === stream, let token = self.lifecycle.token else { return }
            await self.failSession(token: token, error: error)
        }
    }
}
