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

        showBorder(screenRect: screenRect)
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
            return String(localized: "点击开始，再向下滚动")
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

            if viewModel.isCapturing {
                controlButton(
                    icon: "checkmark",
                    label: String(localized: "完成"),
                    color: Color.accentColor,
                    action: onDone
                )
            } else {
                controlButton(
                    icon: "play.fill",
                    label: String(localized: "开始采集"),
                    color: Color.green,
                    action: onStart
                )
            }
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
