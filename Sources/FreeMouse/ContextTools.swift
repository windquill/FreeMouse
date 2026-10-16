import AppKit
import FinderSync
import CoreImage
import ApplicationServices
import ServiceManagement
import SwiftUI

@MainActor
final class ContextTools: NSObject {
    weak var model: AppModel?
    var onMenuBarVisibility: ((Bool) -> Void)?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var suppressedButtons = Set<Int64>()
    init(model: AppModel) { self.model = model; super.init() }
    func stop() {
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false); CFMachPortInvalidate(eventTap) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        eventTap = nil; runLoopSource = nil; suppressedButtons.removeAll()
    }
    func configureTriggers() {
        stop()
        guard UserDefaults.standard.bool(forKey: "cloudMenuEnabled") else { return }
        guard AXIsProcessTrusted() else { model?.status = "云目录快捷菜单需要辅助功能权限；授权后重新开启该选项。"; return }
        let mask = [CGEventType.rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp].reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let tools = Unmanaged<ContextTools>.fromOpaque(context).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                Task { @MainActor in if let tap = tools.eventTap { CGEvent.tapEnable(tap: tap, enable: true) } }
                return Unmanaged.passUnretained(event)
            }
            let consumed = MainActor.assumeIsolated { tools.consumeTrigger(type: type, event: event) }
            return consumed ? nil : Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            model?.status = "无法启用云目录菜单，请检查辅助功能和输入监控权限。"; return
        }
        eventTap = tap; runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let runLoopSource { CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        CGEvent.tapEnable(tap: tap, enable: true)
    }
    private func consumeTrigger(type: CGEventType, event: CGEvent) -> Bool {
        let button = event.getIntegerValueField(.mouseEventButtonNumber)
        if type == .rightMouseUp || type == .otherMouseUp { return suppressedButtons.remove(button) != nil }
        let right = type == .rightMouseDown && event.flags.contains(.maskControl) && event.flags.contains(.maskAlternate)
        let middle = type == .otherMouseDown && button == 2
        guard right || middle else { return false }
        suppressedButtons.insert(button)
        Task { @MainActor [weak self] in self?.showFromFrontmost() }
        return true
    }
    func showFromFrontmost() {
        guard let model else { return }
        let front = NSWorkspace.shared.frontmostApplication
        if front?.bundleIdentifier == "com.apple.finder" {
            let script = NSAppleScript(source: "tell application \"Finder\"\nset paths to {}\nrepeat with f in (selection as alias list)\nset end of paths to POSIX path of f\nend repeat\nif (count of paths) is 0 then\ntry\nset paths to {POSIX path of (target of front Finder window as alias)}\nend try\nend if\nreturn paths\nend tell")
            var error: NSDictionary?
            if let descriptor = script?.executeAndReturnError(&error), error == nil {
                var urls: [URL] = []
                if descriptor.numberOfItems > 0 {
                    for index in 1...descriptor.numberOfItems {
                        if let path = descriptor.atIndex(index)?.stringValue { urls.append(URL(fileURLWithPath: path)) }
                    }
                }
                model.selectedFiles = urls
            } else { model.status = "无法取得 Finder 选区，请在系统设置允许自动化，或先在工具箱选择文件。"; model.showWindow(); return }
        } else {
            // Never apply an action to stale Finder selection while another app is in front.
            model.selectedFiles = []
        }
        showMenu()
    }
    func showMenu() {
        let menu = NSMenu(title: "自在工具箱")
        for entry in ToolMenuCatalog.orderedEntries() {
            let item = NSMenuItem(title: entry.title, action: #selector(performTool(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = entry.id
            if entry.id == "newTemplate" {
                item.action = nil; let formats = NSMenu(); item.submenu = formats
                for format in ToolMenuCatalog.templateFormats {
                    let child = NSMenuItem(title: format.title, action: #selector(performTool(_:)), keyEquivalent: "")
                    child.target = self; child.representedObject = "newTemplate." + format.id; formats.addItem(child)
                }
            }
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let prefs = NSMenuItem(title: "菜单与通用设置…", action: #selector(settings), keyEquivalent: ""); prefs.target = self; menu.addItem(prefs)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
    @objc private func performTool(_ sender: NSMenuItem) { if let id = sender.representedObject as? String { model?.performContextAction(id) } }
    @objc func settings() {
        model?.menuSettingsScope = 0
        model?.tab = 4
        model?.showWindow()
    }
    func setLogin(_ enabled: Bool) {
        do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
        catch { model?.fail("开机启动设置未完成：\(error.localizedDescription)") }
    }
}

@MainActor
extension AppModel {
    func performContextAction(_ action: String) {
        if extendedFileAction(action) || templateImageAction(action) { return }
        switch action {
        case "paths": copyPaths()
        case "names": copyPaths(namesOnly: true)
        case "rename": renameFiles()
        case "newFolder": createFile(folder: true)
        case "edit": if selectedFiles.isEmpty { openImages() } else { importImages(selectedFiles) }
        case "pin":
            var url = selectedFiles.first
            if url == nil {
                let picker = NSOpenPanel(); picker.allowedContentTypes = [.image]
                if picker.runModal() == .OK { url = picker.url }
            }
            guard let url else { return }
            do { let image = try FileTools.loadImage(url); edit(image); editors.last?.pinCurrentImage() }
            catch { fail(error.localizedDescription) }
        case "capture": capture("region")
        case "captureFull": capture("full")
        case "captureScroll": capture("scroll")
        case "record": tab = 1; showWindow()
        case "favorites": favoriteDirectories()
        case "terminal": chooseTerminal()
        case "openWith": chooseOpeningApp()
        case "qr": textTool(.qr)
        case "translateGoogle": textTool(.google)
        case "translateBaidu": textTool(.baidu)
        default: status = "未识别的操作"
        }
    }
    func favoriteDirectories() {
        var paths = UserDefaults.standard.stringArray(forKey: "favoriteDirectories") ?? []
        let alert = NSAlert(); alert.messageText = "常用目录"
        let list = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 460, height: 30))
        list.addItems(withTitles: paths.isEmpty ? ["尚未添加目录"] : paths)
        alert.accessoryView = list
        alert.addButton(withTitle: "打开"); alert.addButton(withTitle: "添加…"); alert.addButton(withTitle: "移除所选"); alert.addButton(withTitle: "取消")
        let result = alert.runModal()
        if result == .alertFirstButtonReturn, !paths.isEmpty { NSWorkspace.shared.open(URL(fileURLWithPath: paths[list.indexOfSelectedItem])) }
        else if result.rawValue == 1001 {
            let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
            if panel.runModal() == .OK {
                for url in panel.urls where !paths.contains(url.path) { paths.append(url.path) }
                UserDefaults.standard.set(paths, forKey: "favoriteDirectories")
            }
        } else if result.rawValue == 1002, !paths.isEmpty {
            paths.remove(at: list.indexOfSelectedItem); UserDefaults.standard.set(paths, forKey: "favoriteDirectories")
        }
    }
    func chooseOpeningApp() {
        if selectedFiles.isEmpty { chooseFiles() }; guard !selectedFiles.isEmpty else { return }
        let names = ["Visual Studio Code", "Sublime Text", "Sublime Merge", "Warp", "MarkText", "Obsidian", "Tabby", "Visual Studio", "Hyper", "Emacs", "CLion", "CotEditor", "HBuilderX", "PhpStorm", "PyCharm", "Typora", "WebStorm", "IntelliJ IDEA", "Android Studio", "AppCode", "DataGrip", "GoLand", "Rider", "RubyMine"]
        let roots = [URL(fileURLWithPath: "/Applications"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        let apps = names.compactMap { name in roots.map { $0.appendingPathComponent(name + ".app") }.first { FileManager.default.fileExists(atPath: $0.path) } }
        let alert = NSAlert(); alert.messageText = "使用应用打开"
        let choices = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 350, height: 30)); choices.addItems(withTitles: apps.map { $0.deletingPathExtension().lastPathComponent } + ["选择其他应用…"])
        alert.accessoryView = choices; alert.addButton(withTitle: "打开"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var application: URL?
        if choices.indexOfSelectedItem < apps.count { application = apps[choices.indexOfSelectedItem] }
        else {
            let picker = NSOpenPanel(); picker.allowedContentTypes = [.application]; picker.directoryURL = URL(fileURLWithPath: "/Applications")
            if picker.runModal() == .OK { application = picker.url }
        }
        guard let application else { return }
        NSWorkspace.shared.open(selectedFiles, withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            Task { @MainActor in if let error { self?.fail(error.localizedDescription) } }
        }
    }
    func chooseTerminal() {
        if selectedFiles.isEmpty { chooseFiles() }; guard let first = selectedFiles.first else { return }
        let directory = (try? first.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true ? first : first.deletingLastPathComponent()
        let alert = NSAlert(); alert.messageText = "在终端打开当前目录"
        let options = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 28))
        options.addItems(withTitles: ["Terminal · 新窗口", "Terminal · 新标签页", "iTerm2 · 新窗口", "iTerm2 · 新标签页"])
        alert.accessoryView = options; alert.addButton(withTitle: "打开"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let mode = options.indexOfSelectedItem
        if mode >= 2 && NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.googlecode.iterm2") == nil { fail("尚未安装 iTerm2。"); return }
        // A shell path is single-quoted first; the entire command is then AppleScript-quoted.
        let command = "cd -- '" + directory.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let quoted = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script: String
        if mode == 0 { script = "tell application \"Terminal\"\nactivate\ndo script \"\(quoted)\"\nend tell" }
        else if mode == 1 { script = "tell application \"Terminal\" to activate\ntell application \"System Events\" to keystroke \"t\" using command down\ndelay 0.2\ntell application \"Terminal\" to do script \"\(quoted)\" in selected tab of front window" }
        else { script = "tell application \"iTerm2\"\nactivate\n" + (mode == 2 ? "set w to (create window with default profile)\n" : "if (count of windows) is 0 then\nset w to (create window with default profile)\nelse\nset w to current window\ntell w to create tab with default profile\nend if\n") + "tell current session of w to write text \"\(quoted)\"\nend tell" }
        var error: NSDictionary?; NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error { fail("终端打开失败，请检查自动化权限：\(error[NSAppleScript.errorMessage] ?? error)") }
    }
    enum TextTool { case qr, google, baidu }
    func textTool(_ kind: TextTool, suppliedText: String? = nil) {
        var text = suppliedText
        if text == nil {
            let alert = NSAlert(); alert.messageText = kind == .qr ? "文字转二维码" : "翻译所选文字"
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: 160)); scroll.hasVerticalScroller = true
            let input = NSTextView(frame: scroll.bounds); input.isRichText = false; scroll.documentView = input
            alert.accessoryView = scroll; alert.addButton(withTitle: kind == .qr ? "生成" : "打开翻译网页"); alert.addButton(withTitle: "取消")
            if kind != .qr { alert.informativeText = "点击后会将输入文字交给所选翻译网站。" }
            guard alert.runModal() == .alertFirstButtonReturn else { return }; text = input.string
        }
        guard let text, !text.isEmpty else { return }
        if kind == .qr {
            guard text.utf8.count <= 2000 else { fail("二维码文字过长，请减少到 2000 字节以内。"); return }
            guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return }
            filter.setValue(Data(text.utf8), forKey: "inputMessage"); filter.setValue("M", forKey: "inputCorrectionLevel")
            guard let output = filter.outputImage else { fail("二维码生成失败。"); return }
            let padded = output.composited(over: CIImage(color: .white).cropped(to: output.extent.insetBy(dx: -4, dy: -4)))
            let scaled = padded.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
            guard let image = CIContext(options: [.useSoftwareRenderer: true]).createCGImage(scaled, from: scaled.extent) else { fail("二维码生成失败。"); return }
            guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
            NSPasteboard.general.clearContents(); NSPasteboard.general.setData(data, forType: .png)
            edit(image); status = "二维码已复制，可直接粘贴"
        } else {
            guard text.utf8.count < 12_000 else { fail("文字过长，请分段翻译。"); return }
            var url: URL?
            if kind == .google {
                var components = URLComponents(string: "https://translate.google.com/")!
                components.queryItems = [.init(name: "sl", value: "auto"), .init(name: "tl", value: "zh-CN"), .init(name: "text", value: text), .init(name: "op", value: "translate")]; url = components.url
            } else {
                var components = URLComponents(string: "https://fanyi.baidu.com/")!
                var allowed = CharacterSet.urlFragmentAllowed; allowed.remove(charactersIn: "/#%?")
                components.percentEncodedFragment = "auto/zh/" + (text.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""); url = components.url
            }
            if let url { NSWorkspace.shared.open(url) }
        }
    }
}

// SwiftUI retains these view controllers, including the weak-target AppKit controls.
// Each pane owns its own view hierarchy; no settings window is reparented into the dashboard.
struct MenuConfigurationPane: NSViewControllerRepresentable {
    let owner: ContextTools
    @Binding var scopeSelection: Int
    func makeNSViewController(context: Context) -> MenuConfigurationController {
        let controller = MenuConfigurationController(owner: owner, scopeSelection: scopeSelection)
        controller.onScopeChange = { scopeSelection = $0 }
        return controller
    }
    func updateNSViewController(_ controller: MenuConfigurationController, context: Context) {
        controller.onScopeChange = { scopeSelection = $0 }
        controller.selectScope(scopeSelection)
    }
}

struct GeneralPreferencesPane: NSViewControllerRepresentable {
    let owner: ContextTools
    func makeNSViewController(context: Context) -> GeneralPreferencesController { GeneralPreferencesController(owner: owner) }
    func updateNSViewController(_ controller: GeneralPreferencesController, context: Context) {}
}

@MainActor
final class MenuConfigurationController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private weak var contextOwner: ContextTools?
    private let table = NSTableView()
    private let scope = NSPopUpButton(frame: .zero, pullsDown: false)
    private let status = NSTextField(wrappingLabelWithString: "")
    private let count = NSTextField(labelWithString: "")
    private let explanation = NSTextField(wrappingLabelWithString: "")
    private let upButton = NSButton(title: "上移", target: nil, action: nil)
    private let downButton = NSButton(title: "下移", target: nil, action: nil)
    private let finderButton = NSButton(title: "启用 Finder 扩展…", target: nil, action: nil)
    private var configuration = ToolMenuConfiguration()
    private var readable = false
    private(set) var selectedScope: Int
    var onScopeChange: ((Int) -> Void)?
    private var isFinder: Bool { selectedScope == 0 }
    private var entries: [ToolMenuEntry] { configuration.orderedEntries }

    init(owner: ContextTools, scopeSelection: Int) {
        contextOwner = owner; selectedScope = scopeSelection == 1 ? 1 : 0
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = NSView()
        scope.addItems(withTitles: ["Finder 右键菜单", "独立鼠标菜单"])
        scope.selectItem(at: selectedScope)
        scope.target = self; scope.action = #selector(changeScope)
        scope.setAccessibilityLabel("配置哪个右键菜单")
        scope.controlSize = .small
        let targetLabel = NSTextField(labelWithString: "配置对象")
        targetLabel.font = .systemFont(ofSize: 12); targetLabel.textColor = .secondaryLabelColor
        let top = NSStackView(views: [targetLabel, scope, NSView()]); top.orientation = .horizontal; top.spacing = 10

        addColumn("enabled", title: "启用", width: 52, minimum: 52, maximum: 52, resizing: [])
        addColumn("icon", title: "图标", width: 40, minimum: 40, maximum: 40, resizing: [])
        addColumn("name", title: "名称", width: 310, minimum: 190, maximum: 1000, resizing: .autoresizingMask)
        addColumn("group", title: "类型", width: 90, minimum: 70, maximum: 110, resizing: .userResizingMask)
        table.delegate = self; table.dataSource = self; table.rowHeight = 32
        table.intercellSpacing = NSSize(width: 6, height: 2)
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.allowsColumnReordering = false
        table.allowsMultipleSelection = false
        table.setAccessibilityLabel("右键菜单功能与显示顺序")
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false; scroll.autohidesScrollers = true; scroll.borderType = .bezelBorder

        upButton.target = self; upButton.action = #selector(up); upButton.controlSize = .small
        downButton.target = self; downButton.action = #selector(down); downButton.controlSize = .small
        upButton.toolTip = "将选中的功能上移一行"; downButton.toolTip = "将选中的功能下移一行"
        count.font = .systemFont(ofSize: 11); count.textColor = .secondaryLabelColor
        let movement = NSStackView(views: [count, NSView(), upButton, downButton]); movement.orientation = .horizontal; movement.spacing = 8
        status.font = .systemFont(ofSize: 11); status.setContentCompressionResistancePriority(.required, for: .vertical)
        explanation.font = .systemFont(ofSize: 11); explanation.textColor = .secondaryLabelColor
        explanation.setContentCompressionResistancePriority(.required, for: .vertical)
        finderButton.target = self; finderButton.action = #selector(enableFinderMenu); finderButton.controlSize = .small
        let footer = NSStackView(views: [explanation, finderButton]); footer.orientation = .horizontal; footer.spacing = 12
        let stack = NSStackView(views: [top, scroll, movement, status, footer])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor), stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor), stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            top.widthAnchor.constraint(equalTo: stack.widthAnchor), scope.widthAnchor.constraint(equalToConstant: 180),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor), scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 230),
            movement.widthAnchor.constraint(equalTo: stack.widthAnchor), status.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        reloadConfiguration()
    }
    override func viewWillAppear() { super.viewWillAppear(); reloadConfiguration() }
    private func addColumn(_ id: String, title: String, width: CGFloat, minimum: CGFloat, maximum: CGFloat, resizing: NSTableColumn.ResizingOptions) {
        let column = NSTableColumn(identifier: .init(id)); column.title = title
        column.width = width; column.minWidth = minimum; column.maxWidth = maximum; column.resizingMask = resizing
        table.addTableColumn(column)
    }
    func selectScope(_ selection: Int) {
        let next = selection == 1 ? 1 : 0
        guard selectedScope != next else { return }
        selectedScope = next
        guard isViewLoaded else { return }
        scope.selectItem(at: next)
        reloadConfiguration()
    }
    @objc private func changeScope() {
        let next = scope.indexOfSelectedItem == 1 ? 1 : 0
        guard selectedScope != next else { return }
        selectedScope = next
        reloadConfiguration()
        onScopeChange?(next)
    }
    private func reloadConfiguration() {
        do {
            if isFinder { configuration = try FinderMenuPreferences.shared.migrateIfNeeded { ToolMenuConfiguration.load() } }
            else { configuration = ToolMenuConfiguration.load() }
            readable = true
            status.stringValue = isFinder ? "Finder 配置已载入。修改后，下次打开右键菜单时生效。" : "独立鼠标菜单单独保存，不影响 Finder 右键菜单。"
            status.textColor = .secondaryLabelColor
        } catch {
            readable = false; status.stringValue = error.localizedDescription; status.textColor = .systemRed
        }
        explanation.stringValue = isFinder
            ? "首次使用请在系统设置中启用 Finder 扩展。"
            : "在通用设置中开启后，通过 ⌃⌥右键或中键触发。三指轻拍需另行映射。"
        finderButton.isHidden = !isFinder
        table.deselectAll(nil); table.reloadData(); updateMovementButtons()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { readable ? entries.count : 0 }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard readable, entries.indices.contains(row), let identifier = tableColumn?.identifier.rawValue else { return nil }
        let entry = entries[row]
        if identifier == "enabled" {
            let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleFeature(_:)))
            checkbox.identifier = NSUserInterfaceItemIdentifier(entry.id)
            checkbox.state = configuration.hidden.contains(entry.id) ? .off : .on
            checkbox.setAccessibilityLabel("显示" + entry.title)
            checkbox.translatesAutoresizingMaskIntoConstraints = false
            let cell = NSView(); cell.addSubview(checkbox)
            NSLayoutConstraint.activate([checkbox.centerXAnchor.constraint(equalTo: cell.centerXAnchor), checkbox.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
            return cell
        }
        if identifier == "icon" {
            let image = NSImageView(image: NSImage(systemSymbolName: symbol(for: entry), accessibilityDescription: entry.group) ?? NSImage())
            image.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            image.contentTintColor = .secondaryLabelColor; image.imageScaling = .scaleProportionallyDown
            return image
        }
        let label = NSTextField(labelWithString: identifier == "group" ? entry.group : entry.title)
        label.font = .systemFont(ofSize: identifier == "group" ? 11 : 12)
        label.textColor = identifier == "group" || configuration.hidden.contains(entry.id) ? .secondaryLabelColor : .labelColor
        label.lineBreakMode = .byTruncatingTail
        return label
    }
    private func symbol(for entry: ToolMenuEntry) -> String {
        switch entry.id {
        case "newFolder", "folderFromName": return "folder.badge.plus"
        case "newTemplate", "customTemplate": return "doc.badge.plus"
        case "copyTo", "paths", "names": return "doc.on.doc"
        case "moveTo", "pasteCut": return "folder"
        case "cut", "cancelCut": return "scissors"
        case "rename": return "character.cursor.ibeam"
        case "desktopAlias": return "arrow.up.forward.square"
        case "airdrop": return "airplayaudio"
        case "deletePermanent": return "trash"
        case "favorites": return "star"
        case "terminal": return "terminal"
        case "openWith": return "app"
        case "hide", "hideAll": return "eye.slash"
        case "unhide", "unhideAll": return "eye"
        case "edit": return "pencil.and.outline"
        case "pin": return "pin"
        case "capture": return "viewfinder"
        case "captureFull": return "display"
        case "captureScroll": return "rectangle.expand.vertical"
        case "record": return "record.circle"
        case "qr": return "qrcode"
        case "translateGoogle", "translateBaidu": return "character.bubble"
        default: return entry.group == "文件信息" ? "number" : "photo"
        }
    }
    func tableViewSelectionDidChange(_ notification: Notification) { updateMovementButtons() }
    private func updateMovementButtons() {
        let row = table.selectedRow
        upButton.isEnabled = readable && row > 0
        downButton.isEnabled = readable && row >= 0 && row + 1 < entries.count
        count.stringValue = readable ? "已启用 \(configuration.visibleEntries.count) / \(entries.count) 项" : "配置不可用"
    }
    private func save(_ next: ToolMenuConfiguration, selectedID: String) {
        do {
            if isFinder { try FinderMenuPreferences.shared.save(next) } else { next.save() }
            configuration = next
            status.stringValue = isFinder ? "已保存。请重新打开 Finder 右键菜单查看。" : "独立鼠标菜单配置已保存。"
            status.textColor = .secondaryLabelColor
        } catch {
            status.stringValue = error.localizedDescription; status.textColor = .systemRed
            let alert = NSAlert(); alert.messageText = "菜单配置未保存"; alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "知道了"); alert.runModal()
            if (error as? FinderMenuPreferenceError) == .stateUnconfirmed { readable = false }
        }
        table.reloadData()
        if readable, let index = configuration.order.firstIndex(of: selectedID) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false); table.scrollRowToVisible(index)
        }
        updateMovementButtons()
    }
    @objc private func toggleFeature(_ sender: NSButton) {
        guard readable, let id = sender.identifier?.rawValue else { return }
        var next = configuration; guard next.toggleVisibility(id) else { return }; save(next, selectedID: id)
    }
    private func moveSelected(by offset: Int) {
        let row = table.selectedRow; guard readable, entries.indices.contains(row) else { return }
        let id = entries[row].id; var next = configuration
        guard next.move(id, by: offset) else { return }; save(next, selectedID: id)
    }
    @objc private func up() { moveSelected(by: -1) }
    @objc private func down() { moveSelected(by: 1) }
    @objc private func enableFinderMenu() { FIFinderSyncController.showExtensionManagementInterface() }
}

@MainActor
final class GeneralPreferencesController: NSViewController {
    private weak var contextOwner: ContextTools?
    private var checkboxes: [String: NSButton] = [:]
    private let loginButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    init(owner: ContextTools) { contextOwner = owner; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = NSView()
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(stack)
        let items = [
            ("新建成功时提示音", "文件或文件夹创建完成后播放提示音", "creationSound"),
            ("独立鼠标菜单", "使用 ⌃⌥右键或中键打开工具菜单，需要辅助功能权限", "cloudMenuEnabled"),
            ("剪切时暂时隐藏项目", "剪切中的项目暂时隐藏，粘贴或取消后恢复", "cutHidesFiles"),
            ("彻底删除不再确认", "启用前需确认，删除的文件无法从废纸篓恢复", "deleteWithoutConfirmation")
        ]
        for (title, detail, key) in items {
            let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(preference(_:)))
            checkbox.identifier = NSUserInterfaceItemIdentifier(key); checkbox.setAccessibilityLabel(title)
            checkboxes[key] = checkbox
            let row = preferenceRow(title, detail: detail, checkbox: checkbox); stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            let divider = NSBox(); divider.boxType = .separator; stack.addArrangedSubview(divider)
            divider.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        }
        loginButton.target = self; loginButton.action = #selector(login(_:)); loginButton.setAccessibilityLabel("登录时启动")
        let loginRow = preferenceRow("登录时启动", detail: "登录 macOS 后在菜单栏运行", checkbox: loginButton)
        stack.addArrangedSubview(loginRow); loginRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14), stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: view.topAnchor), stack.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        refresh()
    }
    override func viewWillAppear() { super.viewWillAppear(); refresh() }
    private func preferenceRow(_ title: String, detail: String, checkbox: NSButton) -> NSView {
        let titleLabel = NSTextField(labelWithString: title); titleLabel.font = .systemFont(ofSize: 13)
        let detailLabel = NSTextField(wrappingLabelWithString: detail); detailLabel.font = .systemFont(ofSize: 11); detailLabel.textColor = .secondaryLabelColor
        let labels = NSStackView(views: [titleLabel, detailLabel]); labels.orientation = .vertical; labels.alignment = .leading; labels.spacing = 4
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        checkbox.controlSize = .small; checkbox.setContentHuggingPriority(.required, for: .horizontal)
        let row = NSStackView(views: [labels, NSView(), checkbox]); row.orientation = .horizontal; row.spacing = 12
        row.heightAnchor.constraint(equalToConstant: 53).isActive = true
        return row
    }
    private func refresh() {
        for (key, checkbox) in checkboxes { checkbox.state = UserDefaults.standard.bool(forKey: key) ? .on : .off }
        loginButton.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }
    @objc private func preference(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue else { return }
        if key == "deleteWithoutConfirmation", sender.state == .on {
            let alert = NSAlert(); alert.messageText = "跳过永久删除确认？"
            alert.informativeText = "之后点击彻底删除将立即删除所选文件，无法从废纸篓恢复。"
            alert.addButton(withTitle: "启用"); alert.addButton(withTitle: "取消")
            if alert.runModal() != .alertFirstButtonReturn { sender.state = .off; return }
        }
        UserDefaults.standard.set(sender.state == .on, forKey: key)
        if key == "cloudMenuEnabled" { contextOwner?.configureTriggers() }
    }
    @objc private func login(_ sender: NSButton) {
        contextOwner?.setLogin(sender.state == .on)
        sender.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }
}
