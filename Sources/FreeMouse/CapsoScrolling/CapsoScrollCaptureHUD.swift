// Copyright (c) 2026 lzhgus. Derived from Capso.
// BSL 1.1: ThirdParty/Capso/LICENSE; pinned revision: ThirdParty/Capso/REVISION.
import AppKit
import SwiftUI

extension CapsoScrolling {
// App/Sources/Capture/ScrollCaptureHUD.swift

/// Persistent overlay shown during scrolling capture.
/// Shows: selection border, live preview on the left, Cancel/Start/Done at the bottom.
@MainActor
final class ScrollCaptureOverlay {
    private var borderWindow: NSPanel?
    private var handleWindows: [NSPanel] = []
    private var selectionRect = CGRect.zero
    private weak var screen: NSScreen?
    var onResizeBegin: (() -> Void)?
    var onResize: ((CGRect) -> Void)?
    private var controlsWindow: NSPanel?
    private var previewWindow: NSPanel?
    private let viewModel = ScrollCaptureViewModel()
    private var localKeyMonitor: Any?
    private var globalKeyMonitor: Any?
    private var keyEventTap: CFMachPort?
    private var keyEventTapRunLoopSource: CFRunLoopSource?

    var onStart: (() -> Void)?
    var onDone: (() -> Void)?
    var onCancel: (() -> Void)?

    func show(selectionRect: CGRect, screen: NSScreen) {
        let screenOrigin = screen.frame.origin
        let screenRect = NSRect(
            x: screenOrigin.x + selectionRect.origin.x,
            y: screenOrigin.y + selectionRect.origin.y,
            width: selectionRect.width,
            height: selectionRect.height
        )

        self.screen = screen
        self.selectionRect = screenRect
        showBorder(screenRect: screenRect)
        showHandles()
        showControls(screenRect: screenRect, screen: screen)
        showPreview(screenRect: screenRect, screen: screen)
        installKeyHandlers()
    }

    func setIssue(_ issue: String?) { viewModel.issue = issue }

    func bringForward() { controlsWindow?.orderFrontRegardless() }

    func setCapturing(_ capturing: Bool) {
        viewModel.isCapturing = capturing
    }

    func updatePreview(image: CGImage, height: Int, frameCount: Int) {
        viewModel.previewImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        viewModel.currentHeight = height
        viewModel.frameCount = frameCount
    }

    func close() {
        for panel in handleWindows { panel.orderOut(nil) }
        handleWindows.removeAll()
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
        if let globalKeyMonitor {
            NSEvent.removeMonitor(globalKeyMonitor)
            self.globalKeyMonitor = nil
        }
        if let source = keyEventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            keyEventTapRunLoopSource = nil
        }
        if let tap = keyEventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            keyEventTap = nil
        }
        borderWindow?.orderOut(nil)
        borderWindow = nil
        controlsWindow?.orderOut(nil)
        controlsWindow = nil
        previewWindow?.orderOut(nil)
        previewWindow = nil
    }

    /// CGWindowIDs of all overlay panels, for excluding from capture.
    var windowIDs: [CGWindowID] {
        var ids: [CGWindowID] = []
        if let w = borderWindow, let id = CGWindowID(exactly: w.windowNumber) { ids.append(id) }
        if let w = controlsWindow, let id = CGWindowID(exactly: w.windowNumber) { ids.append(id) }
        if let w = previewWindow, let id = CGWindowID(exactly: w.windowNumber) { ids.append(id) }
        ids += handleWindows.compactMap { CGWindowID(exactly: $0.windowNumber) }
        return ids
    }

    private func installKeyHandlers() {
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }

            switch event.keyCode {
            case 53: // ESC
                self.onCancel?()
                return nil // consume the event
            case 36, 76: // Return, keypad Enter
                self.startCaptureFromKeyboard()
                return nil
            default:
                return event
            }
        }

        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return } // ESC
            Task { @MainActor in
                self?.onCancel?()
            }
        }

        // Global Return belongs to the application being captured.
    }

    private func installKeyEventTap() {
        let eventMask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { _, type, event, refcon in
                guard type == .keyDown,
                      let refcon else {
                    return Unmanaged.passUnretained(event)
                }

                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                guard keyCode == 53 || keyCode == 36 || keyCode == 76 else {
                    return Unmanaged.passUnretained(event)
                }

                let overlay = Unmanaged<ScrollCaptureOverlay>.fromOpaque(refcon).takeUnretainedValue()
                Task { @MainActor in
                    if keyCode == 53 {
                        overlay.onCancel?()
                    } else {
                        overlay.startCaptureFromKeyboard()
                    }
                }
                return nil
            },
            userInfo: refcon
        ) else {
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        keyEventTap = tap
        keyEventTapRunLoopSource = source
    }

    private func startCaptureFromKeyboard() {
        guard !viewModel.isCapturing else { return }
        onStart?()
    }

    // MARK: - Border

    private func showBorder(screenRect: NSRect) {
        let inset: CGFloat = 3
        let borderRect = screenRect.insetBy(dx: -inset, dy: -inset)

        let panel = NSPanel(
            contentRect: borderRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false

        let borderView = ScrollCaptureBorderView(frame: NSRect(origin: .zero, size: borderRect.size))
        panel.contentView = borderView

        self.borderWindow = panel
        panel.orderFrontRegardless()
    }

    private func showHandles() {
        for handle in SelectionHandle.allCases {
            let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .floating; panel.isOpaque = false
            panel.backgroundColor = .clear; panel.hasShadow = false
            panel.hidesOnDeactivate = false
            let view = ScrollResizeHandle(frame: CGRect(x: 0, y: 0, width: 14, height: 14))
            panel.identifier = NSUserInterfaceItemIdentifier("scroll-resize-\(handle)")
            var initial = CGRect.zero
            var start = CGPoint.zero
            var changed = false
            view.onDown = { [weak self] pointer in
                guard let self else { return }
                initial = self.selectionRect; start = pointer; changed = false
            }
            view.onDrag = { [weak self] pointer in
                guard let self, let screen = self.screen else { return }
                let edge = handle.point(in: initial)
                guard pointer != start || changed else { return }
                let revised = SelectionGeometry.resized(initial, handle: handle,
                    point: CGPoint(x: edge.x + pointer.x - start.x, y: edge.y + pointer.y - start.y), bounds: screen.frame)
                guard revised != self.selectionRect else { return }
                if !changed { changed = true; self.onResizeBegin?() }
                self.selectionRect = revised
                self.reposition()
            }
            view.onUp = { [weak self] in
                guard let self, changed else { return }
                self.viewModel.previewImage = nil; self.viewModel.currentHeight = 0
                self.viewModel.frameCount = 0; self.viewModel.issue = "区域已调整，正在重新采集"
                if self.previewWindow == nil, let screen = self.screen {
                    self.showPreview(screenRect: self.selectionRect, screen: screen)
                }
                self.onResize?(self.selectionRect)
            }
            panel.contentView = view; handleWindows.append(panel)
        }
        reposition()
        for panel in handleWindows { panel.orderFrontRegardless() }
    }

    private func reposition() {
        borderWindow?.setFrame(selectionRect.insetBy(dx: -3, dy: -3), display: true)
        for (handle, panel) in zip(SelectionHandle.allCases, handleWindows) {
            let p = handle.point(in: selectionRect)
            panel.setFrame(CGRect(x: p.x - 7, y: p.y - 7, width: 14, height: 14), display: true)
        }
        guard let screen else { return }
        controlsWindow?.setFrame(ScrollCaptureOverlayPlacement.controlsFrame(selectionRect: selectionRect, visibleFrame: screen.visibleFrame), display: true)
        if let rect = ScrollCaptureOverlayPlacement.previewFrame(selectionRect: selectionRect, visibleFrame: screen.visibleFrame) {
            previewWindow?.setFrame(rect, display: true)
            previewWindow?.orderFrontRegardless()
        } else { previewWindow?.orderOut(nil) }
    }

    // MARK: - Controls

    private func showControls(screenRect: NSRect, screen: NSScreen) {
        let controlsRect = ScrollCaptureOverlayPlacement.controlsFrame(
            selectionRect: screenRect,
            visibleFrame: screen.visibleFrame
        )

        let panel = NSPanel(
            contentRect: controlsRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false

        let hostingView = NSHostingView(rootView: ScrollCaptureControlsView(
            viewModel: viewModel,
            onStart: { [weak self] in self?.onStart?() },
            onCancel: { [weak self] in self?.onCancel?() },
            onDone: { [weak self] in self?.onDone?() }
        ))
        panel.contentView = hostingView

        self.controlsWindow = panel
        panel.orderFrontRegardless()
    }

    // MARK: - Preview

    private func showPreview(screenRect: NSRect, screen: NSScreen) {
        guard let previewRect = ScrollCaptureOverlayPlacement.previewFrame(
            selectionRect: screenRect,
            visibleFrame: screen.visibleFrame
        ) else { return }

        let panel = NSPanel(
            contentRect: previewRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false

        let hostingView = NSHostingView(rootView: ScrollCapturePreviewView(viewModel: viewModel))
        panel.contentView = hostingView

        self.previewWindow = panel
        panel.orderFrontRegardless()
    }
}

final class ScrollResizeHandle: NSView {
    var onDown: ((CGPoint) -> Void)?
    var onDrag: ((CGPoint) -> Void)?
    var onUp: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { if let point = window?.convertPoint(toScreen: event.locationInWindow) { onDown?(point) } }
    override func mouseDragged(with event: NSEvent) { if let point = window?.convertPoint(toScreen: event.locationInWindow) { onDrag?(point) } }
    override func mouseUp(with event: NSEvent) { onUp?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeUpDown) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.01).setFill(); bounds.fill()
        NSColor.white.setFill(); bounds.insetBy(dx: 3, dy: 3).fill()
        NSColor.systemBlue.setStroke()
        NSBezierPath(rect: bounds.insetBy(dx: 3, dy: 3)).stroke()
    }
}

// MARK: - Border View

final class ScrollCaptureBorderView: NSView {
    private var dashPhase: CGFloat = 0
    private nonisolated(unsafe) var animTimer: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        animTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.dashPhase += 2
                self?.needsDisplay = true
            }
        }
    }

    required init?(coder: NSCoder) { nil }

    deinit { animTimer?.invalidate() }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let rect = bounds.insetBy(dx: 3, dy: 3)
        ctx.setStrokeColor(NSColor.systemBlue.withAlphaComponent(0.8).cgColor)
        ctx.setLineWidth(2.5)
        ctx.setLineDash(phase: dashPhase, lengths: [6, 4])
        ctx.stroke(rect)
    }
}

// MARK: - ViewModel

@MainActor
@Observable
final class ScrollCaptureViewModel {
    var issue: String?
    var previewImage: NSImage?
    var currentHeight: Int = 0
    var frameCount: Int = 0
    var isCapturing: Bool = false

    var statusText: String {
        if let issue { return issue }
        if !isCapturing {
            return String(localized: "正在采集，可拖动边角调整区域")
        }
        if frameCount == 0 {
            return String(localized: "缓慢滚动以采集")
        }
        return "\(currentHeight)px · \(frameCount) 帧"
    }
}

// MARK: - Controls View

struct ScrollCaptureControlsView: View {
    let viewModel: ScrollCaptureViewModel
    let onStart: () -> Void
    let onCancel: () -> Void
    let onDone: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            controlButton(
                icon: "xmark",
                label: String(localized: "取消"),
                color: .white.opacity(0.15),
                action: onCancel
            )

            controlButton(
                icon: "checkmark", label: String(localized: "结束截图"),
                color: Color.accentColor, action: onDone
            )
        }
        .padding(8)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .environment(\.colorScheme, .dark)
    }

    private func controlButton(icon: String, label: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .fixedSize()
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(color)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Preview View

struct ScrollCapturePreviewView: View {
    let viewModel: ScrollCaptureViewModel

    var body: some View {
        VStack(spacing: 0) {
            if let image = viewModel.previewImage {
                // Scale-to-fit: show the entire captured image shrunk to fit the panel
                GeometryReader { geo in
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: geo.size.width)
                        .frame(maxHeight: geo.size.height, alignment: .top)
                }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 20))
                        .foregroundStyle(.tertiary)
                    Text(viewModel.statusText)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            HStack {
                Text(viewModel.statusText)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.bar)
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .environment(\.colorScheme, .dark)
    }
}
}
