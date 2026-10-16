import AppKit

struct CaptureSelection {
    let region: CaptureRegion
    let scrolling: Bool
    var output: ScrollOutputAction = .edit
}

struct SelectionToolbarPlacement {
    static func frame(selection: CGRect, visibleBounds: CGRect, size: CGSize) -> CGRect {
        let width = min(size.width, visibleBounds.width)
        let height = min(size.height, visibleBounds.height)
        let x = min(max(selection.maxX - width, visibleBounds.minX), visibleBounds.maxX - width)
        let below = selection.minY - height - 10
        let above = selection.maxY + 10
        let preferredY = below >= visibleBounds.minY ? below : above
        let y = min(max(preferredY, visibleBounds.minY), visibleBounds.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

@MainActor
final class RegionSelector {
    private var windows: [NSWindow] = []
    private var continuation: CheckedContinuation<CaptureSelection?, Never>?
    private var session: UUID?
    private var previousApplication: NSRunningApplication?

    /// Direct selection remains available for recording and the long-shot shortcut.
    func select() async -> CaptureRegion? { await select(showsActions: false)?.region }

    func selectCapture() async -> CaptureSelection? { await select(showsActions: true) }

    private func select(showsActions: Bool) async -> CaptureSelection? {
        guard continuation == nil, !Task.isCancelled else { return nil }
        let token = UUID()
        session = token
        previousApplication = NSWorkspace.shared.frontmostApplication
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                let pointer = NSEvent.mouseLocation
                var initialWindow: NSWindow?
                for screen in NSScreen.screens {
                    guard let displayID = screen.captureDisplayID else { continue }
                    let window = SelectionWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                    window.level = .screenSaver
                    window.isReleasedWhenClosed = false
                    window.isOpaque = false
                    window.backgroundColor = .clear
                    window.hasShadow = false
                    window.ignoresMouseEvents = false
                    window.acceptsMouseMovedEvents = true
                    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                    let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size), showsActions: showsActions,
                        visibleBounds: screen.visibleFrame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY))
                    view.onActivate = { [weak self, weak view] in
                        // A new drag belongs to exactly one display. Other displays
                        // must not retain a stale region or an actionable toolbar.
                        for other in self?.windows ?? [] {
                            guard let otherView = other.contentView as? SelectionView, otherView !== view else { continue }
                            otherView.resetSelection()
                        }
                    }
                    view.onComplete = { [weak self] rect, scrolling, output in
                        let result = rect.map {
                            CaptureSelection(region: CaptureRegion.from(selection: $0.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY),
                                screenFrame: screen.frame, displayID: displayID, scale: screen.backingScaleFactor), scrolling: scrolling, output: output)
                        }
                        self?.finish(result, token: token)
                    }
                    window.contentView = view
                    windows.append(window)
                    window.orderFrontRegardless()
                    if screen.frame.contains(pointer) { initialWindow = window }
                }
                NSApp.activate()
                if let window = initialWindow ?? windows.first {
                    window.makeKeyAndOrderFront(nil)
                    window.makeFirstResponder(window.contentView)
                } else { finish(nil, token: token) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(nil, token: token) }
        }
    }

    private func finish(_ result: CaptureSelection?, token: UUID) {
        guard session == token else { return }
        session = nil
        for window in windows { window.orderOut(nil); window.close() }
        windows.removeAll()
        let pending = continuation
        continuation = nil
        if let previousApplication, previousApplication.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApplication.activate(options: [])
        }
        previousApplication = nil
        pending?.resume(returning: result)
    }
}

private final class SelectionWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class SelectionView: NSView {
    var onComplete: ((CGRect?, Bool, ScrollOutputAction) -> Void)?
    var onActivate: (() -> Void)?
    private enum Drag {
        case create(CGPoint)
        case move(CGRect, CGPoint)
        case resize(CGRect, SelectionHandle, CGPoint)
    }
    private var drag: Drag?
    private var origin: NSPoint?
    private var selection: CGRect?
    private let showsActions: Bool
    private let visibleBounds: CGRect
    private var toolbar: NSVisualEffectView?
    override var acceptsFirstResponder: Bool { true }

    init(frame: CGRect, showsActions: Bool, visibleBounds: CGRect) {
        self.showsActions = showsActions
        self.visibleBounds = visibleBounds.intersection(CGRect(origin: .zero, size: frame.size))
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
        if let selection {
            addCursorRect(selection.insetBy(dx: 8, dy: 8), cursor: .openHand)
            for h in SelectionHandle.allCases {
                let p = h.point(in: selection)
                let cursor: NSCursor = (h == .left || h == .right) ? .resizeLeftRight : .resizeUpDown
                addCursorRect(CGRect(x: p.x - 7, y: p.y - 7, width: 14, height: 14), cursor: cursor)
            }
        }
        if let toolbar, !toolbar.isHidden { addCursorRect(toolbar.frame, cursor: .arrow) }
    }

    func resetSelection() {
        origin = nil
        drag = nil
        selection = nil
        toolbar?.isHidden = true
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        onActivate?()
        let point = clampedPoint(convert(event.locationInWindow, from: nil))
        if let selection, let handle = SelectionGeometry.handle(at: point, rect: selection) {
            drag = .resize(selection, handle, point)
        } else if let selection, selection.contains(point) {
            drag = .move(selection, point)
        } else {
            resetSelection()
            drag = .create(point)
        }
        toolbar?.isHidden = true
        origin = point
    }
    override func mouseDragged(with event: NSEvent) {
        guard let drag else { return }
        let rawPoint = convert(event.locationInWindow, from: nil)
        let point = clampedPoint(rawPoint)
        switch drag {
        case .create(let start):
            selection = CGRect(x: min(point.x, start.x), y: min(point.y, start.y),
                               width: abs(point.x - start.x), height: abs(point.y - start.y))
        case .move(let rect, let start):
            selection = SelectionGeometry.moved(rect, delta: CGSize(width: point.x - start.x, height: point.y - start.y), bounds: bounds)
        case .resize(let rect, let handle, let start):
            let edge = handle.point(in: rect)
            let adjusted = CGPoint(x: edge.x + rawPoint.x - start.x, y: edge.y + rawPoint.y - start.y)
            selection = SelectionGeometry.resized(rect, handle: handle, point: adjusted, bounds: bounds)
        }
        needsDisplay = true
    }
    // The overlay owns all pointer input until a capture action dismisses it.
    override func scrollWheel(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func rightMouseUp(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
    override func otherMouseUp(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        mouseDragged(with: event)
        origin = nil
        drag = nil
        window?.invalidateCursorRects(for: self)
        guard let selection, selection.width >= 4, selection.height >= 4 else {
            resetSelection()
            return
        }
        showToolbar(for: selection)
        needsDisplay = true
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onComplete?(nil, false, .edit); return }
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return }
        if event.keyCode == 15 { resetSelection(); return }
        guard origin == nil, let selection, selection.width >= 4, selection.height >= 4 else { return }
        if !showsActions {
            if event.keyCode == 36 || event.keyCode == 76 { onComplete?(selection, false, .edit) }
            return
        }
        if event.keyCode == 36 || event.keyCode == 76 { onComplete?(selection, false, .copy) }
        else if event.keyCode == 49 { onComplete?(selection, false, .save) }
        else if event.keyCode == 31 { onComplete?(selection, false, .recognize) }
        else if event.keyCode == 1 { onComplete?(selection, true, .edit) }
    }

    private func clampedPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX), y: min(max(point.y, bounds.minY), bounds.maxY))
    }

    private func showToolbar(for selection: CGRect) {
        let bar: NSVisualEffectView
        if let toolbar { bar = toolbar }
        else {
            bar = NSVisualEffectView(frame: .zero)
            bar.material = .hudWindow
            bar.blendingMode = .withinWindow
            bar.state = .active
            bar.wantsLayer = true
            bar.layer?.cornerRadius = 12
            bar.layer?.borderWidth = 1
            bar.layer?.borderColor = NSColor.white.withAlphaComponent(0.2).cgColor
            let items: [(String, CGFloat, Selector)] = showsActions ? [
                ("编辑", 62, #selector(captureSelection)),
                ("长截图 S", 92, #selector(scrollSelection)),
                ("复制 ↵", 78, #selector(copySelection)),
                ("保存 ␣", 78, #selector(saveSelection)),
                ("识字 O", 78, #selector(recognizeSelection)),
                ("重选", 72, #selector(reselect)),
                ("取消 Esc", 76, #selector(cancelSelection))
            ] : [("完成 ↵", 90, #selector(captureSelection)),
                 ("重选", 72, #selector(reselect)), ("取消 Esc", 90, #selector(cancelSelection))]
            var x: CGFloat = 12
            for (title, width, action) in items {
                let button = NSButton(title: title, target: self, action: action)
                button.frame = CGRect(x: x, y: 11, width: width, height: 32)
                button.bezelStyle = .rounded
                button.font = .systemFont(ofSize: 13, weight: .medium)
                button.setAccessibilityLabel(title)
                bar.addSubview(button)
                x += width + 8
            }
            addSubview(bar)
            toolbar = bar
        }
        bar.frame = SelectionToolbarPlacement.frame(selection: selection, visibleBounds: visibleBounds, size: CGSize(width: showsActions ? 616 : 300, height: 54))
        bar.isHidden = false
        window?.invalidateCursorRects(for: self)
    }

    @objc private func captureSelection() { if let selection { onComplete?(selection, false, .edit) } }
    @objc private func scrollSelection() { if let selection { onComplete?(selection, true, .edit) } }
    @objc private func copySelection() { if let selection { onComplete?(selection, false, .copy) } }
    @objc private func saveSelection() { if let selection { onComplete?(selection, false, .save) } }
    @objc private func recognizeSelection() { if let selection { onComplete?(selection, false, .recognize) } }
    @objc private func reselect() { resetSelection(); window?.makeFirstResponder(self) }
    @objc private func cancelSelection() { onComplete?(nil, false, .edit) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()
        if let selection {
            // A fully transparent NSWindow region can pass clicks to the app below.
            NSColor.black.withAlphaComponent(0.01).setFill()
            selection.fill(using: .copy)
            NSColor.white.setStroke()
            let border = NSBezierPath(rect: selection.insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = 1
            border.stroke()
            for h in SelectionHandle.allCases {
                let p = h.point(in: selection)
                NSColor.white.setFill()
                CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6).fill()
            }
        }
        let ready = origin == nil && selection != nil
        let message = ready ? "拖动框内移动 · 拖动边角缩放 · 工具条完成 · Esc 取消" : "拖动选择区域 · 按 Esc 取消 · 每次选择一个显示器"
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 17, weight: .medium), .foregroundColor: NSColor.white]
        message.draw(at: NSPoint(x: visibleBounds.minX + 28, y: visibleBounds.maxY - 44), withAttributes: attributes)
    }
}
