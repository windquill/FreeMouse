import AppKit
import AVFoundation

enum CameraOverlayError: LocalizedError {
    case permissionDenied, noCamera, configurationFailed, startupTimeout, windowUnavailable
    case interrupted(String)
    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "无法访问摄像头。请在系统设置 → 隐私与安全性 → 摄像头中允许自在工具箱，或关闭摄像头小窗。"
        case .noCamera: return "未找到可用的摄像头，请连接摄像头或关闭摄像头小窗。"
        case .configurationFailed: return "摄像头无法启动，请检查是否被其他应用占用。"
        case .startupTimeout: return "未收到摄像头画面，请检查摄像头连接后重试。"
        case .windowUnavailable: return "无法将摄像头小窗加入录屏，本次录制没有开始。"
        case .interrupted(let reason): return "摄像头已中断：\(reason)"
        }
    }
}

/// The session and its sample delegate are confined to one serial queue.
/// No image is written or copied: SCRecordingOutput records the visible preview window.
private final class CameraCaptureDriver: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "local.freemouse.camera", qos: .userInitiated)
    private let video = AVCaptureVideoDataOutput()
    private var ready: CheckedContinuation<Void, Error>?
    private var observers: [NSObjectProtocol] = []
    private var stopped = false
    private var deliveredFailure = false
    private let onFailure: (Error) -> Void

    init(onFailure: @escaping (Error) -> Void) { self.onFailure = onFailure }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                guard !stopped else { continuation.resume(throwing: CancellationError()); return }
                ready = continuation
                do {
                    guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified)
                            ?? AVCaptureDevice.default(for: .video) else { throw CameraOverlayError.noCamera }
                    let input = try AVCaptureDeviceInput(device: device)
                    session.beginConfiguration()
                    do {
                        if session.canSetSessionPreset(.medium) { session.sessionPreset = .medium }
                        guard session.canAddInput(input), session.canAddOutput(video) else { throw CameraOverlayError.configurationFailed }
                        session.addInput(input)
                        video.alwaysDiscardsLateVideoFrames = true
                        video.setSampleBufferDelegate(self, queue: queue)
                        session.addOutput(video)
                        session.commitConfiguration()
                    } catch {
                        session.commitConfiguration()
                        throw error
                    }
                    observe(AVCaptureSession.runtimeErrorNotification) { notification in
                        let error = notification.userInfo?[AVCaptureSessionErrorKey] as? Error
                        return error ?? CameraOverlayError.configurationFailed
                    }
                    observe(AVCaptureSession.didStopRunningNotification) { _ in CameraOverlayError.interrupted("采集会话已停止") }
                    session.startRunning()
                    guard session.isRunning else { throw CameraOverlayError.configurationFailed }
                    queue.asyncAfter(deadline: .now() + 8) { [weak self] in
                        guard let self, self.ready != nil, !self.stopped else { return }
                        self.failed(CameraOverlayError.startupTimeout)
                    }
                } catch { failed(error) }
            }
        }
    }

    private func observe(_ name: Notification.Name, error: @escaping (Notification) -> Error) {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: session, queue: nil) { [weak self] notification in
            guard let self else { return }
            let failure = error(notification)
            self.queue.async { self.failed(failure) }
        })
    }

    private func failed(_ error: Error) {
        guard !stopped, !deliveredFailure else { return }
        deliveredFailure = true
        if let continuation = ready {
            ready = nil
            continuation.resume(throwing: error)
        } else { onFailure(error) }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !stopped, !deliveredFailure, CMSampleBufferIsValid(sampleBuffer),
              CMSampleBufferGetImageBuffer(sampleBuffer) != nil, let continuation = ready else { return }
        ready = nil
        continuation.resume()
    }

    func stop() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                stopped = true
                let pending = ready; ready = nil
                pending?.resume(throwing: CancellationError())
                for observer in observers { NotificationCenter.default.removeObserver(observer) }
                observers.removeAll()
                video.setSampleBufferDelegate(nil, queue: nil)
                if session.isRunning { session.stopRunning() }
                session.beginConfiguration()
                for input in session.inputs { session.removeInput(input) }
                for output in session.outputs { session.removeOutput(output) }
                session.commitConfiguration()
                continuation.resume()
            }
        }
    }
}

@MainActor
private final class CameraPreviewView: NSView {
    let preview = AVCaptureVideoPreviewLayer()
    let recordingBounds: CGRect
    private var dragOffset: CGPoint?

    init(frame: CGRect, recordingBounds: CGRect) {
        self.recordingBounds = recordingBounds
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        preview.videoGravity = .resizeAspectFill
        preview.frame = bounds
        layer?.addSublayer(preview)
        toolTip = "按住拖动摄像头画面；此小窗会一起录入视频"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() { super.layout(); preview.frame = bounds }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let mouse = NSEvent.mouseLocation
        dragOffset = CGPoint(x: mouse.x - window.frame.minX, y: mouse.y - window.frame.minY)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let window, let dragOffset else { return }
        let mouse = NSEvent.mouseLocation
        let proposed = CGRect(x: mouse.x - dragOffset.x, y: mouse.y - dragOffset.y,
                              width: window.frame.width, height: window.frame.height)
        window.setFrame(CameraOverlayLayout.clamped(proposed, to: recordingBounds), display: true)
    }
    override func mouseUp(with event: NSEvent) { dragOffset = nil }
}

@MainActor
final class CameraOverlayController {
    var onFailure: ((Error) -> Void)?
    private var panel: NSPanel?
    private var preview: CameraPreviewView?
    private var driver: CameraCaptureDriver?
    private var generation: UUID?
    private var stopping: Task<Void, Never>?

    func start(region: CaptureRegion) async throws -> CGWindowID {
        if let stopping { await stopping.value }
        stopping = nil
        try Task.checkCancellation()
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else { throw CameraOverlayError.permissionDenied }
        default: throw CameraOverlayError.permissionDenied
        }
        try Task.checkCancellation()
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == region.displayID
        }) else { throw RecordingError.displayUnavailable }
        let bounds = CameraOverlayLayout.captureBounds(region: region, screenFrame: screen.frame)
        let frame = CameraOverlayLayout.initialFrame(in: bounds)
        guard frame.width >= 2, frame.height >= 2, screen.frame.contains(bounds) else { throw RecordingError.invalidRegion }
        let token = UUID()
        generation = token
        let capture = CameraCaptureDriver { [weak self] error in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.onFailure?(error)
            }
        }
        driver = capture
        let view = CameraPreviewView(frame: CGRect(origin: .zero, size: frame.size), recordingBounds: bounds)
        view.preview.session = capture.session
        let window = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.sharingType = .readOnly
        window.contentView = view
        window.title = "摄像头小窗 · 按住拖动"
        panel = window
        preview = view
        do {
            try await withTaskCancellationHandler {
                try await capture.start()
            } onCancel: {
                Task { await capture.stop() }
            }
            try Task.checkCancellation()
            guard generation == token else { throw CancellationError() }
            if let connection = view.preview.connection, connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = true
            }
            view.layoutSubtreeIfNeeded()
            window.orderFrontRegardless()
            guard let id = CameraOverlayLayout.windowID(from: window.windowNumber) else { throw CameraOverlayError.windowUnavailable }
            return id
        } catch {
            await stop().value
            throw error
        }
    }

    /// Hide synchronously and submit native teardown immediately, before MP4 finalization.
    @discardableResult func stop() -> Task<Void, Never> {
        if let stopping { return stopping }
        generation = nil
        panel?.orderOut(nil)
        preview?.preview.session = nil
        panel?.close()
        panel = nil
        preview = nil
        let capture = driver
        driver = nil
        let completion = Task<Void, Never> { if let capture { await capture.stop() } }
        stopping = completion
        return completion
    }
}
