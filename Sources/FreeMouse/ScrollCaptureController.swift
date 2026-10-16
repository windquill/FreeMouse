import AppKit

/// FreeMouse lifecycle adapter around the vendored Capso capture implementation.
@MainActor
final class ScrollCaptureController: NSObject {
    var onActivityChange: ((Bool) -> Void)?
    var onOutput: ((CGImage, ScrollOutputAction) -> Void)?
    var isActive: Bool { overlay != nil }
    private(set) var capturedHeight = 0
    private var overlay: CapsoScrolling.ScrollCaptureOverlay?
    private var backend: CapsoScrolling.ScrollCaptureController?
    private var region: CaptureRegion?
    private var generation = UUID()
    private var finishing = false
    private var completion: ((CGImage) -> Void)?

    func start(region: CaptureRegion, onComplete: @escaping (CGImage) -> Void) {
        guard !isActive else { bringForward(); return }
        guard let screen = NSScreen.screens.first(where: { $0.captureDisplayID == region.displayID }) else { return }
        generation = UUID(); capturedHeight = 0; finishing = false
        self.region = region; completion = onComplete
        let overlay = CapsoScrolling.ScrollCaptureOverlay()
        self.overlay = overlay
        overlay.onStart = { [weak self] in self?.beginCapture() }
        overlay.onDone = { [weak self] in self?.finishCapture() }
        overlay.onCancel = { [weak self] in self?.cancel() }
        let selection = CGRect(x: region.rect.minX, y: screen.frame.height - region.rect.maxY,
                               width: region.rect.width, height: region.rect.height)
        overlay.show(selectionRect: selection, screen: screen)
        onActivityChange?(true)
    }

    func beginCapture() {
        guard isActive, backend == nil, let region else { return }
        let token = generation
        let engine = CapsoScrolling.ScrollCaptureController(config: .init(
            captureRect: region.rect, displayID: region.displayID, maxHeight: Int.max))
        engine.onIssue = { [weak self] issue in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.overlay?.setIssue(issue)
            }
        }
        backend = engine
        overlay?.setCapturing(true)
        engine.start(onProgress: { [weak self, engine] progress in
            // Read the stitcher only on its capture worker; deliver an immutable image to UI.
            let image = engine.currentMergedImage
            Task { @MainActor [weak self] in
                guard let self, self.generation == token, !self.finishing else { return }
                self.capturedHeight = progress.currentHeight
                if let image { self.overlay?.updatePreview(image: image, height: progress.currentHeight, frameCount: progress.frameCount) }
            }
        }, onComplete: { [weak self] image in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                let deliver = self.completion
                let requested = self.finishing
                self.cleanup()
                let resultGeneration = self.generation
                if let image, requested {
                    guard self.generation == resultGeneration else { return }
                    deliver?(image)
                }
                else if image == nil {
                    let alert = NSAlert()
                    alert.messageText = "无法开始长截图"
                    alert.informativeText = "请检查屏幕录制权限，并重新选择截图区域。"
                    alert.runModal()
                }
            }
        })
    }

    func finishCapture() {
        guard backend != nil, !finishing else { return }
        finishing = true
        backend?.stop()
    }

    func bringForward() { overlay?.bringForward() }
    func cancel() { backend?.cancel(); cleanup() }

    private func cleanup() {
        generation = UUID()
        backend = nil; region = nil; completion = nil; finishing = false
        overlay?.close(); overlay = nil
        onActivityChange?(false)
    }
}
