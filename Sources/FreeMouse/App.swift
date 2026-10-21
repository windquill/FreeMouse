import AppKit
import SwiftUI
import Carbon
import AVFoundation
import ApplicationServices

@main
struct FreeMouseMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        do { _ = try FinderMenuPreferences.shared.migrateIfNeeded { ToolMenuConfiguration.load() } }
        catch { delegate.model.status = error.localizedDescription }
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var status = "准备就绪，选择一项工具开始"
    @Published var busy = false
    @Published private(set) var recordingPending = false
    @Published var scrolling = false
    @Published var screenAllowed = CGPreflightScreenCaptureAccess()
    @Published var accessibilityAllowed = AXIsProcessTrusted()
    @Published var recent: [URL] = []
    @Published var tab = 0
    @Published var menuSettingsScope = 0
    @Published var systemAudio = true
    @Published var microphone = false
    @Published var cameraEnabled = false
    @Published var fps = 30
    @Published var countdown = 3
    @Published var selectedFiles: [URL] = []
    lazy var contextTools = ContextTools(model: self)
    let recorder = Recorder()
    let captureService = CaptureService()
    let shortcuts = ShortcutSettings()
    let scroll = ScrollCaptureController()
    var editors: [EditorWindow] = []
    var window: NSWindow?
    var onRecordChange: (() -> Void)?
    var onMenuBarAppearanceChange: (() -> Void)?
    private var recordingObserver: Any?
    private var recordingFromMenuBar = false

    init() {
        scroll.onActivityChange = { [weak self] active in self?.scrolling = active }
        scroll.onOutput = { [weak self] image, action in self?.finishScroll(image, action: action) }
        recorder.onFinished = { [weak self] url in
            guard let self else { return }
            let showDashboard = !self.recordingFromMenuBar
            self.recordingFromMenuBar = false
            self.recordingPending = false
            self.status = "录屏已保存：\(url.lastPathComponent)"
            self.remember(url)
            if showDashboard { self.showWindow() }
            self.onRecordChange?()
        }
        recorder.onError = { [weak self] message in
            guard let self else { return }
            let showDashboard = !self.recordingFromMenuBar
            self.recordingFromMenuBar = false
            self.recordingPending = false
            self.fail(message, showDashboard: showDashboard)
            self.onRecordChange?()
        }
    }
    func showWindow() {
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
    func refreshPermissions() {
        screenAllowed = CGPreflightScreenCaptureAccess()
        accessibilityAllowed = AXIsProcessTrusted()
    }
    func requestScreen() {
        if !CGRequestScreenCaptureAccess() { openSettings("Privacy_ScreenCapture") }
        refreshPermissions()
    }
    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        refreshPermissions()
    }
    func openSettings(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") { NSWorkspace.shared.open(url) }
    }
    func fail(_ text: String, showDashboard: Bool = true) {
        status = text; busy = false
        if showDashboard { showWindow() }
        else { NSApp.activate(ignoringOtherApps: true) }
        let alert = NSAlert(); alert.messageText = "操作未完成"; alert.informativeText = text
        alert.alertStyle = .warning; alert.addButton(withTitle: "知道了"); alert.runModal()
    }
    func remember(_ url: URL) { recent.removeAll { $0 == url }; recent.insert(url, at: 0); recent = Array(recent.prefix(12)) }
    func edit(_ image: CGImage) {
        let editor = EditorWindow(image: image)
        editor.onSave = { [weak self] url in self?.remember(url) }
        editors.removeAll { $0.window?.isVisible == false }
        editors.append(editor); editor.show()
        status = "截图已就绪，可标注、识字、复制或保存"
    }
    private func finishScroll(_ image: CGImage, action: ScrollOutputAction) {
        if action == .copy {
            guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { edit(image); return }
            NSPasteboard.general.clearContents()
            if NSPasteboard.general.setData(data, forType: .png) { status = "截图已复制"; return }
        }
        edit(image)
        editors.last?.performScrollOutput(action)
    }
    func capture(_ kind: String) {
        guard !scroll.isActive else { scroll.bringForward(); return }
        guard !busy && !recorder.isBusy && !recorder.isRecording else { return }
        guard CGPreflightScreenCaptureAccess() else { requestScreen(); status = "在系统设置中允许屏幕录制后，重新打开应用再截图"; return }
        busy = true; window?.orderOut(nil)
        Task { @MainActor [self] in
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
                if kind == "window" {
                    if let image = try await captureService.chooseWindow() { edit(image) }
                    else { status = "已取消截图"; showWindow() }
                } else {
                    let region: CaptureRegion?
                    var wantsScroll = kind == "scroll"
                    var output: ScrollOutputAction = kind == "ocr" ? .recognize : .edit
                    if kind == "full" { region = captureService.fullScreenRegion() }
                    else if kind == "region" {
                        let choice = await captureService.chooseCapture()
                        region = choice?.region; wantsScroll = choice?.scrolling ?? false; output = choice?.output ?? .edit
                    } else { region = await captureService.chooseRegion() }
                    if let region {
                        if wantsScroll {
                            scroll.start(region: region) { [weak self] image in self?.edit(image) }
                            status = "长截图：直接滚动，拖动边角调整区域，结束后编辑保存"
                        } else { finishScroll(try await captureService.capture(region: region), action: output) }
                    } else { status = "已取消截图"; showWindow() }
                }
                busy = false
            } catch { fail(error.localizedDescription) }
        }
    }
    func startRecording(fullScreen: Bool, fromMenuBar: Bool = false) {
        guard !scroll.isActive else { scroll.bringForward(); return }
        guard !busy && !recorder.isRecording && !recorder.isBusy else { return }
        guard CGPreflightScreenCaptureAccess() else { requestScreen(); return }
        // Lock before the modal save panel, whose nested event loop can receive menu actions.
        busy = true
        recordingPending = true
        recordingFromMenuBar = fromMenuBar
        onRecordChange?()
        window?.orderOut(nil)
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel(); panel.title = "保存录屏"; panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = Self.timestamp("录屏") + ".mp4"
        guard panel.runModal() == .OK, let url = panel.url else {
            busy = false; recordingPending = false; recordingFromMenuBar = false
            status = "已取消录屏"
            if !fromMenuBar { showWindow() }
            onRecordChange?()
            return
        }
        // Recorder deliberately rejects existing targets, including overwrite confirmations.
        guard !FileManager.default.fileExists(atPath: url.path) else {
            recordingPending = false; recordingFromMenuBar = false
            fail("请选择新的文件名，录屏不会覆盖已有文件。", showDashboard: !fromMenuBar)
            onRecordChange?()
            return
        }
        Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
                let region: CaptureRegion?
                if fullScreen { region = captureService.fullScreenRegion() } else { region = await captureService.chooseRegion() }
                guard let region else {
                    busy = false; recordingPending = false; recordingFromMenuBar = false
                    status = "已取消录屏"
                    if !fromMenuBar { showWindow() }
                    onRecordChange?()
                    return
                }
                for remaining in stride(from: countdown, through: 1, by: -1) {
                    status = "\(remaining) 秒后开始录制…"
                    onRecordChange?()
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
                try await recorder.start(region: region, to: url, systemAudio: systemAudio, microphone: microphone, fps: fps, camera: cameraEnabled)
                busy = false; recordingPending = false
                status = cameraEnabled ? "正在录屏，按住摄像头小窗可拖动。菜单栏或 ⌃⌥⌘R 结束。" : "正在录屏。菜单栏红色停止按钮或 ⌃⌥⌘R 结束。"
                onRecordChange?()
            } catch {
                recordingPending = false; recordingFromMenuBar = false
                fail(error.localizedDescription, showDashboard: !fromMenuBar)
                onRecordChange?()
            }
        }
    }
    func stopRecording() {
        guard recorder.isRecording else { return }
        status = "正在完成录屏文件，请稍候…"
        Task { await recorder.stop(); onRecordChange?() }
    }
    static func timestamp(_ prefix: String) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return prefix + " " + f.string(from: Date())
    }
    func openImages(stitch: Bool = false) {
        let p = NSOpenPanel(); p.allowedContentTypes = [.image]; p.allowsMultipleSelection = stitch
        p.message = stitch ? "按文件名排序后从上到下拼接；可先重命名控制顺序。" : "打开图片进行标注、识字和贴图"
        guard p.runModal() == .OK else { return }
        importImages(p.urls, stitch: stitch)
    }
    func importImages(_ urls: [URL], stitch: Bool = false) {
        do {
            guard let first = urls.first else { return }
            if stitch {
                let ordered = urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                edit(try FileTools.stackImageFiles(ordered))
            } else { edit(try FileTools.loadImage(first)) }
        } catch { fail(error.localizedDescription) }
    }
    func chooseFiles() {
        let p = NSOpenPanel(); p.allowsMultipleSelection = true; p.canChooseDirectories = true
        guard p.runModal() == .OK else { return }; selectedFiles = p.urls
    }
    func copyPaths(namesOnly: Bool = false) {
        guard !selectedFiles.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(selectedFiles.map { namesOnly ? $0.lastPathComponent : $0.path }.joined(separator: "\n"), forType: .string)
        status = "已复制 \(selectedFiles.count) 项\(namesOnly ? "名称" : "路径")"
    }
    func createFile(folder: Bool = false, markdown: Bool = false) {
        let dir: URL
        if selectedFiles.count == 1, let first = selectedFiles.first,
           (try? first.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { dir = first }
        else {
            let p = NSOpenPanel(); p.canChooseFiles = false; p.canChooseDirectories = true; p.message = "选择新建位置"
            guard p.runModal() == .OK, let chosen = p.url else { return }; dir = chosen
        }
        let a = NSAlert(); a.messageText = folder ? "新建文件夹" : "新建文件"
        let field = NSTextField(string: folder ? "新建文件夹" : (markdown ? "笔记.md" : "新建文稿.txt"))
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 26); a.accessoryView = field
        a.addButton(withTitle: "创建"); a.addButton(withTitle: "取消")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        do {
            let url = folder ? try FileTools.createFolder(in: dir, name: field.stringValue) : try FileTools.createFile(in: dir, name: field.stringValue, contents: markdown ? "# 笔记\n\n" : "")
            remember(url); if UserDefaults.standard.bool(forKey: "creationSound") { NSSound.beep() }; NSWorkspace.shared.activateFileViewerSelecting([url]); status = "已创建 \(url.lastPathComponent)"
        } catch { fail(error.localizedDescription) }
    }
    func hashFiles() {
        let urls = selectedFiles.filter { !$0.hasDirectoryPath }; guard !urls.isEmpty else { return }
        busy = true; status = "正在计算 SHA-256…"
        Task {
            do {
                let result = try await Task.detached { try urls.map { $0.lastPathComponent + "\n" + (try FileTools.sha256($0)) }.joined(separator: "\n\n") }.value
                busy = false; showText("SHA-256", text: result)
            } catch { fail(error.localizedDescription) }
        }
    }
    func showText(_ title: String, text: String) {
        let a = NSAlert(); a.messageText = title
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 560, height: 260)); scroll.hasVerticalScroller = true
        let view = NSTextView(frame: scroll.bounds); view.string = text; view.isEditable = false
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular); scroll.documentView = view; a.accessoryView = scroll
        a.addButton(withTitle: "复制"); a.addButton(withTitle: "关闭")
        if a.runModal() == .alertFirstButtonReturn { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
    }
    func openTerminal() {
        guard let first = selectedFiles.first else { return }
        let dir = first.hasDirectoryPath ? first : first.deletingLastPathComponent()
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([dir], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }
    func renameFiles() {
        guard !selectedFiles.isEmpty else { return }
        let a = NSAlert(); a.messageText = "批量添加文件名前缀"
        a.informativeText = "先预览变更，再确认。扩展名保持不变，已有目标文件不会被覆盖。"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 26)); field.placeholderString = "例如：项目_"
        a.accessoryView = field; a.addButton(withTitle: "预览"); a.addButton(withTitle: "取消")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        do {
            let plan = try FileTools.renamePlan(selectedFiles, prefix: field.stringValue, suffix: "")
            guard !plan.isEmpty else { return }
            let confirm = NSAlert(); confirm.messageText = "确认重命名 \(plan.count) 项"
            confirm.informativeText = plan.prefix(20).map { "\($0.0.lastPathComponent) → \($0.1.lastPathComponent)" }.joined(separator: "\n") + (plan.count > 20 ? "\n……" : "")
            confirm.addButton(withTitle: "重命名"); confirm.addButton(withTitle: "取消")
            guard confirm.runModal() == .alertFirstButtonReturn else { return }
            try FileTools.executeRename(plan); selectedFiles = plan.map { $0.1 }; status = "已重命名 \(plan.count) 项"
        } catch { fail(error.localizedDescription) }
    }
    func convertImages(jpeg: Bool) {
        guard !selectedFiles.isEmpty else { return }
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.message = "选择转换后图片的保存文件夹"
        guard p.runModal() == .OK, let dir = p.url else { return }
        do {
            for url in selectedFiles {
                let image = try FileTools.loadImage(url)
                let output = try FileTools.exportImage(image, in: dir, name: url.deletingPathExtension().lastPathComponent, jpeg: jpeg)
                remember(output)
            }
            status = "图片转换完成"; NSWorkspace.shared.open(dir)
        } catch { fail(error.localizedDescription) }
    }
}

