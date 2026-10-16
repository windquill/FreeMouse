import Foundation

enum ScrollOutputAction { case edit, copy, save, recognize }

/// Decisions are independent of AppKit and monotonic times are supplied by the controller.
struct ScrollCaptureFlow {
    enum Phase { case preparing, running, paused, finishing, ended }
    enum Mode { case manual, automatic }
    private(set) var phase: Phase = .preparing
    private(set) var mode: Mode = .manual
    private(set) var hasImage = false
    private(set) var hasUnmatchedFrame = false
    private var lastProgress: TimeInterval = 0
    private var failures = 0
    private var movedWhilePaused = false
    var shouldScroll: Bool { phase == .running && mode == .automatic && hasImage }
    mutating func started(at time: TimeInterval) {
        guard phase == .preparing else { return }; phase = .running; lastProgress = time
    }
    mutating func accepted(at time: TimeInterval) {
        guard phase != .ended else { return }
        hasImage = true; lastProgress = time; failures = 0
        if phase != .paused { movedWhilePaused = false }
        hasUnmatchedFrame = movedWhilePaused
    }
    mutating func setAutomatic(_ enabled: Bool, at time: TimeInterval) {
        guard phase == .running || phase == .paused else { return }
        mode = enabled ? .automatic : .manual
        phase = .running; lastProgress = time; failures = 0
    }
    mutating func rejected(at time: TimeInterval) -> Bool {
        guard phase != .ended else { return false }
        hasUnmatchedFrame = true
        guard phase == .running else { return false }; failures += 1
        if mode == .automatic && failures >= 5 { setAutomatic(false, at: time); return true }
        return false
    }
    mutating func unchanged(at time: TimeInterval) -> Bool {
        guard shouldScroll, time - lastProgress >= 1.4 else { return false }
        setAutomatic(false, at: time); return true
    }
    mutating func matchedWithoutAdvance() {
        guard phase != .ended else { return }
        if phase != .paused { movedWhilePaused = false }
        hasUnmatchedFrame = movedWhilePaused
        failures = 0
        // Recognizing already captured content recovers the match, but must
        // not extend the document-progress timer or resume a user pause.
    }
    mutating func processingBacklog(at time: TimeInterval) {
        guard phase == .running, mode == .automatic else { return }
        // Waiting for the assembler is not evidence that the document ended.
        // Do not change the mode, user pause, or the failed-match counter.
        lastProgress = time
    }
    mutating func userScrolled() {
        guard phase == .paused else { return }
        movedWhilePaused = true
        hasUnmatchedFrame = true
    }
    mutating func requestFinish(_ action: ScrollOutputAction) -> Bool {
        guard phase != .ended && phase != .finishing else { return false }
        phase = .finishing; return true
    }
    mutating func togglePause(at time: TimeInterval, hasInFlightFrame: Bool = false) {
        switch phase {
        case .running:
            phase = .paused
            if hasInFlightFrame { userScrolled() }
        case .paused: phase = .running; lastProgress = time; failures = 0
        default: break
        }
    }
    mutating func end() { phase = .ended; mode = .manual }
}

struct ScrollOverlayLayout {
    let toolbar: CGRect
    let preview: CGRect
    static func make(selection: CGRect, visibleScreen: CGRect) -> Self {
        let screen = visibleScreen.insetBy(dx: 8, dy: 8)
        let width = min(700, screen.width), height = min(114, screen.height)
        var toolbar = CGRect(x: selection.midX - width / 2, y: selection.minY - height - 10, width: width, height: height)
        if toolbar.minY < screen.minY { toolbar.origin.y = selection.maxY + 10 }
        toolbar = clamped(toolbar, to: screen)
        let pw = min(174, screen.width), ph = min(450, screen.height)
        var preview = CGRect(x: selection.maxX + 12, y: selection.maxY - ph, width: pw, height: ph)
        if preview.maxX > screen.maxX { preview.origin.x = selection.minX - pw - 12 }
        preview = clamped(preview, to: screen)
        return .init(toolbar: toolbar, preview: preview)
    }
    private static func clamped(_ rect: CGRect, to screen: CGRect) -> CGRect {
        CGRect(x: min(max(screen.minX, rect.minX), screen.maxX - rect.width),
               y: min(max(screen.minY, rect.minY), screen.maxY - rect.height), width: rect.width, height: rect.height)
    }
    static func exposedPoint(in selection: CGRect, avoiding: [CGRect]) -> CGPoint? {
        // Check the center first, then alternatives if the movable toolbar overlaps it.
        for y in [0.5, 0.25, 0.75, 0.1, 0.9] {
            for x in [0.5, 0.25, 0.75, 0.1, 0.9] {
                let point = CGPoint(x: selection.minX + selection.width * x, y: selection.minY + selection.height * y)
                if selection.contains(point) && !avoiding.contains(where: { $0.contains(point) }) { return point }
            }
        }
        return nil
    }
}

/// Bound posted point deltas by the pixel overlap required by the matcher.
enum ScrollMotionBudget {
    static func step(viewportHeight: CGFloat, scale: CGFloat, pending: CGFloat, rate: Double, elapsed: Double) -> Int32 {
        guard viewportHeight.isFinite, scale.isFinite, scale > 0, viewportHeight > 0 else { return 0 }
        let minimumOverlap = max(20 / scale, viewportHeight / 6)
        let allowance = min(viewportHeight * 0.2, max(0, viewportHeight - minimumOverlap))
        let remaining = max(0, allowance - pending)
        let proposed = max(1, rate * min(0.05, max(0, elapsed)))
        return Int32(min(1000, floor(min(remaining, proposed))))
    }
}
