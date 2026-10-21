import AppKit
import SwiftUI
import Carbon

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate, NSPopoverDelegate {
    let model = AppModel()
    private var statusItem: NSStatusItem!
    private var translationStatusItem: NSStatusItem!
    private var window: NSWindow!
    private var hotKeys: [UUID: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?
    private var statusTimer: Timer?
    private let networkMonitor = NetworkMonitor()
    private var networkSpeed: NetworkSpeed { networkMonitor.speed }
    private var statusMenuIsOpen = false
    private var networkWakeObserver: NSObjectProtocol?
    private var toolboxMenu: NSMenu?
    private var networkPopover: NSPopover?
    private let translationWindow = SystemTranslationWindow()

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
        translationStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        translationStatusItem.button?.image = NSImage(systemSymbolName: "character.bubble", accessibilityDescription: "框选翻译")
        translationStatusItem.button?.toolTip = "框选翻译：拖动选择屏幕文字，松开鼠标自动翻译"
        translationStatusItem.button?.target = self
        translationStatusItem.button?.action = #selector(translateSystem)
        translationWindow.onSelect = { [weak self] in self?.translateSystem() }
        model.onRecordChange = { [weak self] in self?.updateStatus() }
        model.onMenuBarAppearanceChange = { [weak self] in self?.updateStatusButton() }
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        model.contextTools.onMenuBarVisibility = { [weak self] _ in self?.statusItem.isVisible = true }
        statusItem.isVisible = true
        model.contextTools.configureTriggers()
        updateStatus(); installHotKeys()
        networkMonitor.sample()
        networkWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // systemUptime can exclude sleep while byte counters keep growing.
                self.networkMonitor.resetBaseline()
                self.updateStatusButton()
            }
        }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.networkMonitor.sample()
                if self.statusMenuIsOpen { self.updateStatusButton() } else { self.updateStatus() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        statusTimer = timer
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
        statusTimer?.invalidate()
        networkMonitor.stopDetails()
        if let networkWakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(networkWakeObserver) }
        model.shortcuts.registry.suspend()
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
    private func updateStatusButton() {
        let recording = model.recorder.isRecording
        statusItem.button?.image = NetworkSpeedMenuImage.make(speed: networkSpeed, recording: recording, elapsed: model.recorder.elapsed,
            spacing: NetworkSpeedMenuPreferences.spacing(from: UserDefaults.standard.object(forKey: NetworkSpeedMenuPreferences.spacingKey)),
            trailingSpacing: NetworkSpeedMenuPreferences.trailingSpacing(from: UserDefaults.standard.object(forKey: NetworkSpeedMenuPreferences.trailingSpacingKey)))
        statusItem.button?.contentTintColor = recording ? .systemRed : nil
        statusItem.button?.title = ""
        let description = "自在工具箱 · 上传 " + NetworkSpeedFormatter.string(networkSpeed.upload)
            + " · 下载 " + NetworkSpeedFormatter.string(networkSpeed.download)
            + " · 点击网速查看网络详情，点击图标打开工具箱菜单"
            + (recording ? " · 正在录屏，点击图标菜单停止" : "")
        statusItem.button?.toolTip = description
        statusItem.button?.setAccessibilityLabel(description)
    }
    func menuWillOpen(_ menu: NSMenu) { statusMenuIsOpen = true }
    func menuDidClose(_ menu: NSMenu) { statusMenuIsOpen = false }
    private func updateStatus() {
        updateStatusButton()
        let recording = model.recorder.isRecording
        let processingRecording = model.recordingPending || model.recorder.isBusy
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        let entries: [(String, Selector)] = [(shortcutTitle("打开自在工具箱", .toolbox), #selector(show)), (shortcutTitle("区域截图", .region), #selector(region)), (shortcutTitle("全屏截图", .full), #selector(full)), (shortcutTitle("窗口截图", .window), #selector(captureWindow)), (shortcutTitle("滚动长截图", .scroll), #selector(long)), (shortcutTitle("截图识字（OCR）", .ocr), #selector(ocr)), (shortcutTitle("框选翻译…", .translate), #selector(translateSystem)), (shortcutTitle("打开图片编辑…", .openImage), #selector(openImage)), (shortcutTitle("网络面板", .network), #selector(networkAction))]
        for (title, action) in entries { let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item) }
        menu.addItem(.separator())
        if recording {
            let stop = NSMenuItem(title: shortcutTitle("停止并保存录屏", .record), action: #selector(recordAction), keyEquivalent: "")
            stop.target = self; menu.addItem(stop)
        } else if processingRecording {
            let progress = NSMenuItem(title: model.recordingPending ? "正在准备录屏…" : "正在完成录屏…", action: nil, keyEquivalent: "")
            progress.isEnabled = false; menu.addItem(progress)
        } else {
            for (title, action) in [(shortcutTitle("开始区域录屏…", .record), #selector(recordAction)), (shortcutTitle("开始全屏录屏…", .recordFull), #selector(recordFullScreenAction))] {
                let start = NSMenuItem(title: title, action: action, keyEquivalent: "")
                start.target = self; start.isEnabled = !model.busy && !model.scrolling; menu.addItem(start)
            }
        }
        menu.addItem(.separator())
        let camera = NSMenuItem(title: shortcutTitle("录屏时显示摄像头小窗", .camera), action: #selector(toggleRecordingCamera), keyEquivalent: "")
        camera.target = self
        camera.state = model.cameraEnabled ? .on : .off
        camera.isEnabled = !recording && !processingRecording && !model.busy && !model.scrolling
        menu.addItem(camera)
        let preferences = NSMenuItem(title: shortcutTitle("通用与右键设置…", .settings), action: #selector(menuSettings), keyEquivalent: ""); preferences.target = self; menu.addItem(preferences)
        let quit = NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); menu.addItem(quit)
        toolboxMenu = menu
    }
    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { showToolboxMenu(); return }
        let point = sender.convert(event.locationInWindow, from: nil)
        let target = NetworkSpeedMenuHitTarget.target(x: point.x, buttonWidth: sender.bounds.width,
            imageWidth: sender.image?.size.width ?? sender.bounds.width,
            spacing: NetworkSpeedMenuPreferences.spacing(from: UserDefaults.standard.object(forKey: NetworkSpeedMenuPreferences.spacingKey)))
        if event.type == .rightMouseUp || target == .toolbox { showToolboxMenu() }
        else { toggleNetworkPanel() }
    }
    private func showToolboxMenu() {
        networkPopover?.performClose(nil)
        updateStatus()
        guard let button = statusItem.button, let menu = toolboxMenu else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.isFlipped ? button.bounds.maxY + 4 : -4), in: button)
    }
    private func toggleNetworkPanel() {
        if networkPopover?.isShown == true { networkPopover?.performClose(nil); return }
        guard let button = statusItem.button else { return }
        let popover = networkPopover ?? NSPopover()
        if networkPopover == nil {
            popover.behavior = .transient
            popover.animates = false
            popover.delegate = self
            popover.contentViewController = NSHostingController(rootView: NetworkPanel(monitor: networkMonitor) { [weak self] in self?.showToolboxMenu() })
            networkPopover = popover
        }
        let availableHeight = (button.window?.screen?.visibleFrame.height ?? 800) - 60
        popover.contentSize = NSSize(width: 280, height: min(860, max(400, availableHeight)))
        networkMonitor.startDetails()
        button.state = .on
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
    func popoverDidClose(_ notification: Notification) {
        statusItem.button?.state = .off
        networkMonitor.stopDetails()
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
    @objc private func ocr() { model.capture("ocr") }
    @objc private func translateSystem() {
        guard !translationWindow.state.busy, !model.busy, !model.recorder.isBusy,
              !model.recorder.isRecording, !model.scroll.isActive else { return }
        networkPopover?.performClose(nil)
        guard CGPreflightScreenCaptureAccess() else { model.capture("translate"); return }
        translationWindow.hideForSelection()
        model.capture("translate", onImage: { [weak self] image in self?.translationWindow.recognize(image) },
            onCancel: { [weak self] in self?.translationWindow.restoreAfterCancellation() })
    }
    @objc private func networkAction() { toggleNetworkPanel() }
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
                case .ocr: delegate.model.capture("ocr")
                case .translate: delegate.translateSystem()
                case .toolbox: delegate.show()
                case .openImage: delegate.openImage()
                case .recordFull:
                    if delegate.model.recorder.isRecording { delegate.model.stopRecording() }
                    else { delegate.recordFullScreenAction() }
                case .network: delegate.networkAction()
                case .settings: delegate.menuSettings()
                case .camera: delegate.toggleRecordingCamera()
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
