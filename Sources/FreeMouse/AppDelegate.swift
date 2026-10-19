import AppKit
import SwiftUI
import Carbon

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = AppModel()
    private var statusItem: NSStatusItem!
    private var window: NSWindow!
    private var hotKeys: [UUID: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?
    private var statusTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let menu = NSMenu()
        let appItem = NSMenuItem(); let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle: "关于自在工具箱", action: #selector(about), keyEquivalent: "")
        appMenu.addItem(.separator())
        let services = NSMenuItem(title: "服务", action: nil, keyEquivalent: ""); services.submenu = NSMenu(); appMenu.addItem(services); NSApp.servicesMenu = services.submenu
        appMenu.addItem(withTitle: "隐藏自在工具箱", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "退出自在工具箱", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(appItem)
        let edit = NSMenuItem(title: "编辑", action: nil, keyEquivalent: ""); let editMenu = NSMenu(title: "编辑")
        for (title, sel, key) in [("撤销", "undo:", "z"), ("剪切", "cut:", "x"), ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] { editMenu.addItem(withTitle: title, action: Selector(sel), keyEquivalent: key) }
        edit.submenu = editMenu; menu.addItem(edit); NSApp.mainMenu = menu
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1010, height: 720), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.delegate = self
        window.title = "自在工具箱"; window.titlebarAppearsTransparent = true; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Dashboard(model: model, recorder: model.recorder))
        window.center(); model.window = window
        model.restoreInterruptedCut()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        model.onRecordChange = { [weak self] in self?.updateStatus() }
        model.contextTools.onMenuBarVisibility = { [weak self] _ in self?.statusItem.isVisible = true }
        statusItem.isVisible = true
        model.contextTools.configureTriggers()
        updateStatus(); installHotKeys()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.updateStatus() } }
    }
    func applicationDidResignActive(_ notification: Notification) { model.shortcuts.cancelRecording() }
    func windowDidResignKey(_ notification: Notification) { cancelShortcutRecording(notification) }
    func windowWillClose(_ notification: Notification) { cancelShortcutRecording(notification) }
    func windowDidMiniaturize(_ notification: Notification) { cancelShortcutRecording(notification) }
    private func cancelShortcutRecording(_ notification: Notification) {
        guard let changed = notification.object as? NSWindow, changed === window else { return }
        model.shortcuts.cancelRecording()
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        if NSApp.activationPolicy() != .accessory { NSApp.setActivationPolicy(.accessory) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model.busy {
            let alert = NSAlert(); alert.messageText = "请等待当前操作完成"
            alert.informativeText = "正在处理文件或图片，完成后再退出，避免中断保存或移动。"
            alert.addButton(withTitle: "继续等待"); alert.runModal(); return .terminateCancel
        }
        if model.recorder.isRecording || model.recorder.isBusy {
            let alert = NSAlert(); alert.messageText = "先完成当前录屏"; alert.informativeText = "停止录屏并等待保存完成后，再退出工具箱。"; alert.addButton(withTitle: "停止并保存"); alert.addButton(withTitle: "继续录制")
            if alert.runModal() == .alertFirstButtonReturn { model.stopRecording() }
            return .terminateCancel
        }
        _ = model.extendedFileAction("cancelCut")
        if model.hasPendingCutRecovery {
            let alert = NSAlert(); alert.messageText = "仍有剪切恢复记录"
            alert.informativeText = "部分原文件无法恢复隐藏状态，恢复记录已保留，下次启动会重试。"
            alert.addButton(withTitle: "暂不退出"); alert.addButton(withTitle: "保留记录并退出")
            if alert.runModal() == .alertFirstButtonReturn { return .terminateCancel }
        }
        model.contextTools.stop()
        model.scroll.cancel()
        return .terminateNow
    }
    func applicationWillTerminate(_ notification: Notification) {
        model.shortcuts.registry.suspend()
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
    private func updateStatus() {
        let recording = model.recorder.isRecording
        let processingRecording = model.recordingPending || model.recorder.isBusy
        statusItem.button?.image = NSImage(systemSymbolName: recording ? "stop.circle.fill" : "cursorarrow.rays", accessibilityDescription: recording ? "停止录屏" : "自在工具箱")
        statusItem.button?.contentTintColor = recording ? .systemRed : nil
        statusItem.button?.title = recording ? String(format: " %02d:%02d", Int(model.recorder.elapsed)/60, Int(model.recorder.elapsed)%60) : ""
        let menu = NSMenu()
        menu.autoenablesItems = false
        let entries: [(String, Selector)] = [("打开自在工具箱", #selector(show)), (shortcutTitle("区域截图", .region), #selector(region)), (shortcutTitle("全屏截图", .full), #selector(full)), (shortcutTitle("窗口截图", .window), #selector(captureWindow)), (shortcutTitle("滚动长截图", .scroll), #selector(long)), ("打开图片编辑…", #selector(openImage))]
        for (title, action) in entries { let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item) }
        menu.addItem(.separator())
        if recording {
            let stop = NSMenuItem(title: shortcutTitle("停止并保存录屏", .record), action: #selector(recordAction), keyEquivalent: "")
            stop.target = self; menu.addItem(stop)
        } else if processingRecording {
            let progress = NSMenuItem(title: model.recordingPending ? "正在准备录屏…" : "正在完成录屏…", action: nil, keyEquivalent: "")
            progress.isEnabled = false; menu.addItem(progress)
        } else {
            for (title, action) in [(shortcutTitle("开始区域录屏…", .record), #selector(recordAction)), ("开始全屏录屏…", #selector(recordFullScreenAction))] {
                let start = NSMenuItem(title: title, action: action, keyEquivalent: "")
                start.target = self; start.isEnabled = !model.busy && !model.scrolling; menu.addItem(start)
            }
        }
        menu.addItem(.separator())
        let camera = NSMenuItem(title: "录屏时显示摄像头小窗", action: #selector(toggleRecordingCamera), keyEquivalent: "")
        camera.target = self
        camera.state = model.cameraEnabled ? .on : .off
        camera.isEnabled = !recording && !processingRecording && !model.busy && !model.scrolling
        menu.addItem(camera)
        let preferences = NSMenuItem(title: "通用与右键设置…", action: #selector(menuSettings), keyEquivalent: ""); preferences.target = self; menu.addItem(preferences)
        let quit = NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); menu.addItem(quit)
        statusItem.menu = menu
    }
    private func shortcutTitle(_ title: String, _ action: ShortcutAction) -> String {
        guard let key = model.shortcuts.bindings[action] else { return title }
        return title + "  " + key.display
    }
    @objc private func menuSettings() { model.contextTools.settings() }
    @objc private func show() { model.showWindow() }
    @objc private func region() { model.capture("region") }
    @objc private func full() { model.capture("full") }
    @objc private func captureWindow() { model.capture("window") }
    @objc private func long() { model.capture("scroll") }
    @objc private func openImage() { model.openImages() }
    @objc private func recordAction() { if model.recorder.isRecording { model.stopRecording() } else { model.startRecording(fullScreen: false, fromMenuBar: true) } }
    @objc private func recordFullScreenAction() { model.startRecording(fullScreen: true, fromMenuBar: true) }
    @objc private func toggleRecordingCamera() {
        guard !model.recordingPending, !model.recorder.isBusy, !model.recorder.isRecording,
              !model.busy, !model.scrolling else { return }
        model.cameraEnabled.toggle()
        updateStatus()
    }
    @objc private func about() { model.tab = 3; model.showWindow() }
    private func installHotKeys() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard id.signature == 0x46524D53 else { return OSStatus(eventNotHandledErr) }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            let keyID = id.id
            Task { @MainActor in
                guard delegate.model.shortcuts.recording == nil,
                      let action = ShortcutAction.allCases.first(where: { $0.hotKeyID == keyID }) else { return }
                switch action {
                case .region: delegate.model.capture("region")
                case .scroll: delegate.model.capture("scroll")
                case .full: delegate.model.capture("full")
                case .window: delegate.model.capture("window")
                case .record: delegate.recordAction()
                }
            }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        let settings = model.shortcuts
        settings.registry.register = { [weak self] action, key in
            guard let self else { return nil }
            var reference: EventHotKeyRef?
            let result = RegisterEventHotKey(key.keyCode, key.modifiers,
                EventHotKeyID(signature: 0x46524D53, id: action.hotKeyID), GetApplicationEventTarget(), 0, &reference)
            guard result == noErr, let reference else { return nil }
            let token = UUID(); self.hotKeys[token] = reference
            return token
        }
        settings.registry.unregister = { [weak self] token in
            if let ref = self?.hotKeys.removeValue(forKey: token) { UnregisterEventHotKey(ref) }
        }
        settings.onChange = { [weak self] in
            self?.model.objectWillChange.send()
            self?.updateStatus()
        }
        let unavailable = settings.registry.activateAvailable(settings.bindings)
        if !unavailable.isEmpty { model.status = "快捷键被占用：" + unavailable.map(\.title).joined(separator: "、") + "；其余快捷键仍可使用。" }
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        model.importImages(filenames.map { URL(fileURLWithPath: $0) }); sender.reply(toOpenOrPrint: .success)
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        let imageURLs = urls.filter(\.isFileURL)
        if !imageURLs.isEmpty { model.importImages(imageURLs) }
        for url in urls {
            if url.scheme == "freemouse", url.host == "settings" {
                model.contextTools.settings()
                continue
            }
            guard url.scheme == "freemouse", url.host == "files", let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { continue }
            let paths = (c.queryItems ?? []).filter { $0.name == "path" }.compactMap(\.value).filter { $0.hasPrefix("/") }
            model.selectedFiles = paths.map { URL(fileURLWithPath: $0) }
            let action = c.queryItems?.first { $0.name == "action" }?.value
            guard let action, ToolMenuCatalog.isKnownAction(action) else { model.tab = 2; model.showWindow(); continue }
            // URL handlers can be called by any application, including a browser.
            // Review direct mutations before honoring an external action request.
            if ["hide", "unhide", "hideAll", "unhideAll", "iconClear", "folderFromName", "cut", "pasteCut", "desktopAlias"].contains(action) || (action == "deletePermanent" && UserDefaults.standard.bool(forKey: "deleteWithoutConfirmation")) {
                let alert = NSAlert(); alert.messageText = "确认文件操作"
                alert.informativeText = (ToolMenuCatalog.entries.first { $0.id == action }?.title ?? action) + "\n" + model.selectedFiles.prefix(12).map(\.path).joined(separator: "\n")
                alert.addButton(withTitle: "继续"); alert.addButton(withTitle: "取消")
                NSApp.activate(ignoringOtherApps: true)
                guard alert.runModal() == .alertFirstButtonReturn else { continue }
            }
            model.performContextAction(action)
        }
    }
    @objc func textQRCode(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        model.textTool(.qr, suppliedText: pasteboard.string(forType: .string))
    }
    @objc func translateGoogle(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        model.textTool(.google, suppliedText: pasteboard.string(forType: .string))
    }
    @objc func translateBaidu(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        model.textTool(.baidu, suppliedText: pasteboard.string(forType: .string))
    }
    private func serviceURLs(_ pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
    @objc func copyFilePaths(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = serviceURLs(pasteboard)
        guard !urls.isEmpty else { error.pointee = "请选择文件或文件夹。"; return }
        pasteboard.clearContents(); pasteboard.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
    }
    @objc func editSelectedImage(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = serviceURLs(pasteboard)
        guard !urls.isEmpty else { error.pointee = "请选择图片文件。"; return }
        model.importImages(urls)
    }
}
