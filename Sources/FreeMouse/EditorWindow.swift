import AppKit
import Vision
import UniformTypeIdentifiers

enum EditorTool { case rectangle, arrow, pen, text, redact }
struct EditorAnnotation {
    var kind: EditorTool
    var points: [CGPoint]
    var color: NSColor
    var width: CGFloat
    var text: String
}
enum EditorRasterizer {
    static func imagePoint(_ point: CGPoint, scale: CGFloat, size: CGSize) -> CGPoint {
        let divisor = max(scale, 0.0001)
        return CGPoint(x: min(max(point.x / divisor, 0), size.width),
                       y: min(max(point.y / divisor, 0), size.height))
    }
    static func isSafeSize(width: Int, height: Int) -> Bool {
        guard width > 0, height > 0 else { return false }
        let result = width.multipliedReportingOverflow(by: height)
        // Validate addressable RGBA storage, without imposing a fixed image cap.
        return !result.overflow && result.partialValue <= Int.max / 4
    }
    static func render(image: CGImage, annotations: [EditorAnnotation]) -> CGImage? {
        guard isSafeSize(width: image.width, height: image.height) else { return nil }
        guard !annotations.isEmpty else { return image }
        guard let context = CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.draw(image, in: rect)
        context.translateBy(x: 0, y: CGFloat(image.height))
        context.scaleBy(x: 1, y: -1)
        for annotation in annotations { draw(annotation, in: context) }
        return context.makeImage()
    }

    /// Both editor and exported bitmap use image pixels with a top-left origin.
    static func draw(_ a: EditorAnnotation, in c: CGContext) {
        guard let first = a.points.first else { return }
        c.saveGState()
        defer { c.restoreGState() }
        c.setStrokeColor(a.color.cgColor)
        c.setFillColor(a.color.cgColor)
        c.setLineWidth(a.width)
        c.setLineCap(.round)
        c.setLineJoin(.round)
        let last = a.points.last ?? first
        let rect = CGRect(x: min(first.x, last.x), y: min(first.y, last.y),
                          width: abs(first.x - last.x), height: abs(first.y - last.y))
        switch a.kind {
        case .rectangle:
            c.stroke(rect)
        case .redact:
            // Redaction is flattened opaque black; never blur or retain hidden pixels in layers.
            c.setBlendMode(.copy)
            c.setFillColor(CGColor(gray: 0, alpha: 1))
            c.fill(rect.integral)
        case .pen:
            if a.points.count == 1 { c.fillEllipse(in: CGRect(x: first.x-a.width/2, y: first.y-a.width/2, width: a.width, height: a.width)); return }
            c.beginPath(); c.move(to: first)
            for p in a.points.dropFirst() { c.addLine(to: p) }
            c.strokePath()
        case .arrow:
            c.beginPath(); c.move(to: first); c.addLine(to: last); c.strokePath()
            let angle = atan2(last.y - first.y, last.x - first.x)
            let length = max(a.width * 4, 12)
            c.beginPath(); c.move(to: last)
            c.addLine(to: CGPoint(x: last.x - length*cos(angle - .pi/6), y: last.y - length*sin(angle - .pi/6)))
            c.move(to: last)
            c.addLine(to: CGPoint(x: last.x - length*cos(angle + .pi/6), y: last.y - length*sin(angle + .pi/6)))
            c.strokePath()
        case .text:
            let graphics = NSGraphicsContext(cgContext: c, flipped: true)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            (a.text as NSString).draw(at: first, withAttributes: [
                .font: NSFont.systemFont(ofSize: max(18, a.width * 6), weight: .semibold),
                .foregroundColor: a.color])
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}

@MainActor
private final class EditorCanvas: NSView {
    let image: CGImage
    var scale: CGFloat = 1
    var tool: EditorTool = .rectangle
    var color = NSColor.systemRed
    var stroke: CGFloat = 4
    var annotations: [EditorAnnotation] = []
    var draft: EditorAnnotation?
    var changed: (() -> Void)?
    var requestText: ((CGPoint) -> Void)?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    init(image: CGImage) { self.image = image; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill(); dirtyRect.fill()
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.scaleBy(x: scale, y: scale)
        context.saveGState()
        context.translateBy(x: 0, y: CGFloat(image.height))
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.restoreGState()
        for a in annotations { EditorRasterizer.draw(a, in: context) }
        if let a = draft { EditorRasterizer.draw(a, in: context) }
        context.restoreGState()
    }
    private func imagePoint(_ event: NSEvent) -> CGPoint {
        EditorRasterizer.imagePoint(convert(event.locationInWindow, from: nil), scale: scale,
            size: CGSize(width: image.width, height: image.height))
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = imagePoint(event)
        if tool == .text { requestText?(p); return }
        draft = EditorAnnotation(kind: tool, points: [p, p], color: color, width: stroke, text: "")
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard draft != nil else { return }
        let p = imagePoint(event)
        if tool == .pen {
            if let previous = draft?.points.last, hypot(previous.x-p.x, previous.y-p.y) >= 1 {
                if draft!.points.count < 50_000 { draft!.points.append(p) }
            }
        } else { draft?.points[1] = p }
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        guard let a = draft else { return }
        draft = nil
        if a.kind == .pen || a.points.first != a.points.last { append(a) }
        needsDisplay = true
    }
    func append(_ annotation: EditorAnnotation) {
        guard annotations.count < 2000 else { NSSound.beep(); return }
        annotations.append(annotation)
        needsDisplay = true; changed?()
    }
    func undoAnnotation() {
        if draft != nil { draft = nil } else if !annotations.isEmpty { annotations.removeLast() }
        needsDisplay = true; changed?()
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { draft = nil; needsDisplay = true }
        else { super.keyDown(with: event) }
    }
}

@MainActor
private final class EditorPinPanel: NSPanel {
    // Keep pins visible even if their source editor is closed and later released.
    // This retention is broken by the user's standard window-close action.
    private var visibleRetention: EditorPinPanel?
    func displayPinned() { visibleRetention = self; orderFrontRegardless() }
    override func close() { super.close(); visibleRetention = nil }
}

@MainActor
final class EditorWindow: NSWindowController {
    var onSave: ((URL) -> Void)?
    private let canvas: EditorCanvas
    private let scroll = NSScrollView()
    private let status = NSTextField(labelWithString: "")
    private let zoomLabel = NSTextField(labelWithString: "100%")
    private var undoButton: NSButton!
    private var ocrButton: NSButton!
    private var pinWindows: [NSPanel] = []
    private weak var activeSavePanel: NSSavePanel?
    private var fitScale: CGFloat = 1
    private var fitting = true

    init(image: CGImage) {
        canvas = EditorCanvas(image: image)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = "截图编辑 · OmniDesk"
        w.minSize = NSSize(width: 980, height: 560)
        w.isReleasedWhenClosed = false
        super.init(window: w)
        buildInterface()
        canvas.changed = { [weak self] in self?.updateStatus() }
        canvas.requestText = { [weak self] point in self?.insertText(at: point) }
        w.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [weak self] in self?.fitImage() }
    }

    func pinCurrentImage() { pinImage() }

    func performScrollOutput(_ action: ScrollOutputAction) {
        switch action {
        case .save: saveImage()
        case .recognize: recognizeText()
        case .copy: copyImage()
        case .edit: break
        }
    }

    private func button(_ title: String, symbol: String? = nil, action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        if let symbol { b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title); b.imagePosition = .imageLeading }
        return b
    }

    private func buildInterface() {
        guard let content = window?.contentView else { return }
        let toolPicker = NSSegmentedControl(labels: ["矩形", "箭头", "画笔", "文字", "遮挡"], trackingMode: .selectOne, target: self, action: #selector(selectTool(_:)))
        toolPicker.selectedSegment = 0
        toolPicker.toolTip = "在图片上拖动绘制。文字工具点击插入；遮挡导出为不透明黑色。"
        let colors = NSColorWell(frame: NSRect(x: 0, y: 0, width: 44, height: 28))
        colors.color = .systemRed; colors.target = self; colors.action = #selector(selectColor(_:))
        colors.toolTip = "标注颜色（遮挡始终使用黑色）"
        let widths = NSPopUpButton(frame: .zero, pullsDown: false)
        widths.addItems(withTitles: ["细 · 2px", "中 · 4px", "粗 · 8px", "加粗 · 14px"])
        widths.selectItem(at: 1); widths.target = self; widths.action = #selector(selectWidth(_:))
        undoButton = button("撤销", symbol: "arrow.uturn.backward", action: #selector(undo))
        undoButton.keyEquivalent = "z"; undoButton.keyEquivalentModifierMask = .command
        let toolbar = NSStackView(views: [toolPicker, colors, widths, undoButton])
        toolbar.spacing = 10; toolbar.orientation = .horizontal
        let save = button("另存为…", symbol: "square.and.arrow.down", action: #selector(saveImage))
        save.keyEquivalent = "s"; save.keyEquivalentModifierMask = .command
        let copy = button("复制图片", symbol: "doc.on.doc", action: #selector(copyImage))
        copy.keyEquivalent = "c"; copy.keyEquivalentModifierMask = .command
        let pin = button("贴图", symbol: "pin", action: #selector(pinImage))
        ocrButton = button("识别文字", symbol: "text.viewfinder", action: #selector(recognizeText))
        let actions = NSStackView(views: [save, copy, pin, ocrButton])
        actions.spacing = 10
        let top = NSStackView(views: [toolbar, actions])
        top.orientation = .vertical; top.alignment = .leading; top.spacing = 8
        scroll.documentView = canvas
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true; scroll.borderType = .noBorder
        scroll.backgroundColor = .underPageBackgroundColor
        let fit = button("适合窗口", action: #selector(fitAction))
        let minus = button("−", action: #selector(zoomOut))
        let plus = button("＋", action: #selector(zoomIn))
        let actual = button("100%", action: #selector(actualSize))
        zoomLabel.alignment = .center
        zoomLabel.widthAnchor.constraint(equalToConstant: 58).isActive = true
        let footer = NSStackView(views: [status, NSView(), minus, zoomLabel, plus, actual, fit])
        footer.spacing = 8
        for view in [top, scroll, footer] { view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view) }
        NSLayoutConstraint.activate([
            top.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            top.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -16),
            top.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            scroll.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -10),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)
        ])
        scroll.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(viewportResized), name: NSView.frameDidChangeNotification, object: scroll.contentView)
        updateStatus()
    }

    @objc private func selectTool(_ sender: NSSegmentedControl) {
        canvas.tool = [EditorTool.rectangle, .arrow, .pen, .text, .redact][sender.selectedSegment]
    }
    @objc private func selectColor(_ sender: NSColorWell) { canvas.color = sender.color }
    @objc private func selectWidth(_ sender: NSPopUpButton) { canvas.stroke = [2, 4, 8, 14][sender.indexOfSelectedItem] }
    @objc private func undo() { canvas.undoAnnotation() }
    private func updateStatus(_ message: String? = nil) {
        status.stringValue = message ?? "\(canvas.image.width) × \(canvas.image.height) 像素 · \(canvas.annotations.count) 个标注"
        undoButton?.isEnabled = !canvas.annotations.isEmpty
    }
    @objc private func viewportResized() { if fitting { fitImage() } }
    @objc private func fitAction() { fitting = true; fitImage() }
    private func fitImage() {
        let size = scroll.contentSize
        guard size.width > 0, size.height > 0 else { return }
        fitScale = min(1, min(size.width / CGFloat(canvas.image.width), size.height / CGFloat(canvas.image.height)))
        applyZoom(fitScale)
    }
    private func applyZoom(_ value: CGFloat) {
        canvas.scale = max(0.002, min(4, value))
        canvas.setFrameSize(NSSize(width: CGFloat(canvas.image.width)*canvas.scale, height: CGFloat(canvas.image.height)*canvas.scale))
        canvas.needsDisplay = true
        zoomLabel.stringValue = String(format: "%.0f%%", canvas.scale * 100)
    }
    @objc private func zoomOut() { fitting = false; applyZoom(canvas.scale / 1.25) }
    @objc private func zoomIn() { fitting = false; applyZoom(canvas.scale * 1.25) }
    @objc private func actualSize() { fitting = false; applyZoom(1) }

    private func insertText(at point: CGPoint) {
        let alert = NSAlert()
        alert.messageText = "添加文字"; alert.informativeText = "文字将显示在点击的位置。"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 28))
        field.placeholderString = "输入标注文字"
        alert.accessoryView = field; alert.addButton(withTitle: "添加"); alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, !field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let self else { return }
            self.canvas.append(EditorAnnotation(kind: .text, points: [point], color: self.canvas.color,
                width: self.canvas.stroke, text: String(field.stringValue.prefix(4000))))
        }
    }

    private func renderedImage() -> CGImage? {
        guard let output = EditorRasterizer.render(image: canvas.image, annotations: canvas.annotations) else {
            showError("无法生成截图图像", detail: "图像尺寸无法表示，或系统未能创建绘图画布。")
            return nil
        }
        return output
    }
    @objc private func saveImage() {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.title = "保存截图"; panel.nameFieldStringValue = "截图-\(Self.timestamp()).png"
        panel.allowedContentTypes = [.png]
        panel.isExtensionHidden = false
        panel.canCreateDirectories = true
        let format = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 190, height: 28), pullsDown: false)
        format.addItems(withTitles: ["PNG · 无损", "JPEG · 高质量"])
        format.target = self; format.action = #selector(saveFormatChanged(_:))
        activeSavePanel = panel
        panel.accessoryView = format
        panel.beginSheetModal(for: window) { [weak self] result in
            guard result == .OK, let self, let chosenURL = panel.url, let image = self.renderedImage() else { return }
            self.activeSavePanel = nil
            let url = chosenURL
            let useJPEG = format.indexOfSelectedItem == 1
            autoreleasepool {
                let bitmap = NSBitmapImageRep(cgImage: image)
                let properties: [NSBitmapImageRep.PropertyKey: Any] = useJPEG ? [.compressionFactor: 0.92] : [:]
                guard let data = bitmap.representation(using: useJPEG ? .jpeg : .png, properties: properties) else {
                    self.showError("无法编码截图", detail: "请尝试 PNG 格式。"); return
                }
                do {
                    try data.write(to: url, options: .atomic)
                    self.updateStatus("已保存：\(url.lastPathComponent)"); self.onSave?(url)
                } catch { self.showError("保存失败", detail: error.localizedDescription) }
            }
        }
    }
    @objc private func saveFormatChanged(_ sender: NSPopUpButton) {
        guard let panel = activeSavePanel else { return }
        let jpeg = sender.indexOfSelectedItem == 1
        panel.allowedContentTypes = jpeg ? [.jpeg] : [.png]
        let base = (panel.nameFieldStringValue as NSString).deletingPathExtension
        panel.nameFieldStringValue = base + (jpeg ? ".jpg" : ".png")
    }
    @objc private func copyImage() {
        guard let image = renderedImage() else { return }
        autoreleasepool {
            guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                showError("复制失败", detail: "无法生成 PNG 图片。"); return
            }
            NSPasteboard.general.clearContents()
            if NSPasteboard.general.setData(data, forType: .png) { updateStatus("已复制 PNG 图片") }
            else { showError("复制失败", detail: "剪贴板当前不可用。") }
        }
    }
    @objc private func pinImage() {
        guard let image = renderedImage() else { return }
        pinWindows.removeAll { !$0.isVisible }
        guard pinWindows.count < 12 else { showError("贴图数量已达上限", detail: "请关闭部分贴图后重试。"); return }
        let scale = min(1, min(700/CGFloat(image.width), 700/CGFloat(image.height)))
        let size = NSSize(width: CGFloat(image.width)*scale, height: CGFloat(image.height)*scale)
        let panel = EditorPinPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "贴图 · 拖动标题栏移动"
        panel.level = .floating; panel.isFloatingPanel = true; panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = NSImageView(frame: NSRect(origin: .zero, size: size))
        // Pin at display resolution so a stack of long screenshots does not retain full export buffers.
        let thumbnailScale = min(1, 1400 / CGFloat(max(image.width, image.height)))
        let thumbWidth = max(1, Int(CGFloat(image.width) * thumbnailScale))
        let thumbHeight = max(1, Int(CGFloat(image.height) * thumbnailScale))
        let context = CGContext(data: nil, width: thumbWidth, height: thumbHeight, bitsPerComponent: 8,
            bytesPerRow: thumbWidth*4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.interpolationQuality = .high
        context?.draw(image, in: CGRect(x: 0, y: 0, width: thumbWidth, height: thumbHeight))
        guard let thumbnail = context?.makeImage() else { showError("无法创建贴图", detail: "内存不足，请关闭部分窗口后重试。"); return }
        view.image = NSImage(cgImage: thumbnail, size: size)
        view.imageScaling = .scaleProportionallyUpOrDown; view.autoresizingMask = [.width, .height]
        panel.contentView = view; panel.center(); panel.displayPinned()
        pinWindows.append(panel); updateStatus("已贴图，可拖动标题栏或关闭")
    }
    @objc private func recognizeText() {
        guard let image = renderedImage() else { return }
        ocrButton.isEnabled = false; updateStatus("正在本机识别中英文…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            request.usesLanguageCorrection = true
            let result: Result<String, Error>
            do {
                try VNImageRequestHandler(cgImage: image).perform([request])
                let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
                result = .success(text)
            } catch { result = .failure(error) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.ocrButton.isEnabled = true
                switch result {
                case .success(let text): self.updateStatus("文字识别完成"); self.showRecognizedText(text)
                case .failure(let error): self.updateStatus(); self.showError("文字识别失败", detail: error.localizedDescription)
                }
            }
        }
    }
    private func showRecognizedText(_ text: String) {
        guard let window else { return }
        let alert = NSAlert(); alert.messageText = "识别结果"
        alert.informativeText = text.isEmpty ? "未识别到文字。试试更清晰的截图。" : "识别在本机完成。可以选择文字或复制全部。"
        alert.addButton(withTitle: "复制全部"); alert.addButton(withTitle: "关闭")
        let scroller = NSScrollView(frame: NSRect(x: 0, y: 0, width: 560, height: 340))
        scroller.hasVerticalScroller = true; scroller.borderType = .bezelBorder
        let textView = NSTextView(frame: scroller.bounds)
        textView.string = text; textView.isEditable = false; textView.isSelectable = true
        textView.font = .systemFont(ofSize: 15); textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.autoresizingMask = .width; textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        scroller.documentView = textView; alert.accessoryView = scroller
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
            }
        }
    }
    private func showError(_ message: String, detail: String) {
        guard let window else { return }
        let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = message; alert.informativeText = detail
        alert.addButton(withTitle: "好"); alert.beginSheetModal(for: window)
    }
    private static func timestamp() -> String {
        let formatter = DateFormatter(); formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
