import AppKit
import CryptoKit
import SwiftUI
import UniformTypeIdentifiers

struct StartupEntry: Codable, Identifiable, Equatable {
    let id: String
    let applicationPath: String
    var name: String { URL(fileURLWithPath: applicationPath).deletingPathExtension().lastPathComponent }
}

enum StartupManagerError: LocalizedError {
    case invalidApplication, unsafePath, foreignFile, invalidState, unknownEntry
    var errorDescription: String? {
        switch self {
        case .invalidApplication: return "请选择有效的本地 .app 应用程序。"
        case .unsafePath: return "路径包含符号链接或不是安全的普通文件/目录，操作已停止。"
        case .foreignFile: return "目标文件不属于 OmniDesk，未覆盖或删除。"
        case .invalidState: return "OmniDesk 启动项记录无效，未修改文件。"
        case .unknownEntry: return "启动项记录已改变，请刷新后重试。"
        }
    }
}

/// Only manages its own per-app agents. It never calls launchctl or runs an application.
struct StartupStore {
    let stateDirectory: URL
    let launchAgentsDirectory: URL
    private let fm = FileManager.default
    private let owner = "OmniDesk.StartupManager.v1"
    private var stateURL: URL { stateDirectory.appendingPathComponent("startup-applications-v1.plist") }
    private struct Registry: Codable { let owner: String; let entries: [StartupEntry] }

    static var live: StartupStore {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return StartupStore(stateDirectory: home.appendingPathComponent("Library/Application Support/OmniDesk"),
                            launchAgentsDirectory: home.appendingPathComponent("Library/LaunchAgents"))
    }
    static func identifier(for path: String) -> String {
        "com.omnidesk.startup." + SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func agentPropertyList(for entry: StartupEntry) -> [String: Any] {
        ["Label": entry.id, "ProgramArguments": ["/usr/bin/open", "-a", entry.applicationPath],
         "RunAtLoad": true, "OmniDeskOwner": "OmniDesk.StartupManager.v1"]
    }
    func agentURL(for entry: StartupEntry) -> URL {
        launchAgentsDirectory.appendingPathComponent(entry.id + ".plist")
    }
    private func valid(_ entry: StartupEntry) -> Bool {
        entry.applicationPath.hasPrefix("/") && !entry.applicationPath.utf8.contains(0) &&
        URL(fileURLWithPath: entry.applicationPath).standardizedFileURL.path == entry.applicationPath &&
        entry.id == Self.identifier(for: entry.applicationPath)
    }
    /// Walk existing path components before any read/write, including dangling symlinks.
    private func checkPath(_ url: URL, directory: Bool) throws {
        let path = url.standardizedFileURL.path
        guard url.isFileURL, path.hasPrefix("/"), !path.utf8.contains(0) else { throw StartupManagerError.unsafePath }
        var cursor = URL(fileURLWithPath: "/", isDirectory: true)
        for (index, component) in url.standardizedFileURL.pathComponents.dropFirst().enumerated() {
            cursor.appendPathComponent(component)
            let attributes: [FileAttributeKey: Any]
            do { attributes = try fm.attributesOfItem(atPath: cursor.path) }
            catch let error as NSError where error.domain == NSCocoaErrorDomain &&
                (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError) { continue }
            let type = attributes[.type] as? FileAttributeType
            let last = index == url.standardizedFileURL.pathComponents.count - 2
            guard type != .typeSymbolicLink,
                  type == .typeDirectory || (last && !directory && type == .typeRegular) else {
                throw StartupManagerError.unsafePath
            }
        }
    }
    func entries() throws -> [StartupEntry] {
        try checkPath(stateURL, directory: false)
        guard fm.fileExists(atPath: stateURL.path) else { return [] }
        let registry = try PropertyListDecoder().decode(Registry.self, from: Data(contentsOf: stateURL))
        guard registry.owner == owner, registry.entries.allSatisfy(valid),
              Set(registry.entries.map(\.id)).count == registry.entries.count else { throw StartupManagerError.invalidState }
        return registry.entries.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    private func save(_ entries: [StartupEntry]) throws {
        _ = try self.entries() // Reject foreign/corrupt records before an overwrite.
        try checkPath(stateDirectory, directory: true)
        try fm.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        let data = try PropertyListEncoder().encode(Registry(owner: owner, entries: entries))
        try data.write(to: stateURL, options: fm.fileExists(atPath: stateURL.path) ? .atomic : .withoutOverwriting)
    }
    private func validateApplication(_ url: URL) throws -> URL {
        guard url.isFileURL, url.pathExtension.lowercased() == "app", !url.path.utf8.contains(0) else {
            throw StartupManagerError.invalidApplication
        }
        let canonical = url.standardizedFileURL
        try checkPath(canonical, directory: true)
        guard let bundle = Bundle(url: canonical), bundle.infoDictionary?["CFBundlePackageType"] as? String == "APPL",
              let executable = bundle.executableURL,
              executable.standardizedFileURL.path.hasPrefix(canonical.path + "/Contents/"),
              fm.fileExists(atPath: executable.path) else { throw StartupManagerError.invalidApplication }
        try checkPath(executable, directory: false)
        return canonical
    }
    @discardableResult func add(application: URL) throws -> StartupEntry {
        let application = try validateApplication(application)
        var list = try entries()
        let entry = StartupEntry(id: Self.identifier(for: application.path), applicationPath: application.path)
        if !list.contains(entry) { list.append(entry); try save(list) }
        return entry
    }
    private func verifyRegistered(_ entry: StartupEntry) throws {
        guard valid(entry), try entries().contains(entry) else { throw StartupManagerError.unknownEntry }
    }
    /// Exact dictionary matching prevents removing someone else's file even with the same label.
    func isEnabled(_ entry: StartupEntry) throws -> Bool {
        guard valid(entry) else { throw StartupManagerError.unknownEntry }
        let url = agentURL(for: entry)
        try checkPath(url, directory: false)
        guard fm.fileExists(atPath: url.path) else { return false }
        guard let value = try? PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any],
              NSDictionary(dictionary: value).isEqual(to: Self.agentPropertyList(for: entry)) else {
            throw StartupManagerError.foreignFile
        }
        return true
    }
    func setEnabled(_ enabled: Bool, entry: StartupEntry) throws {
        try verifyRegistered(entry)
        let existing = try isEnabled(entry)
        if enabled {
            _ = try validateApplication(URL(fileURLWithPath: entry.applicationPath))
            guard !existing else { return }
            try checkPath(launchAgentsDirectory, directory: true)
            try fm.createDirectory(at: launchAgentsDirectory, withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: Self.agentPropertyList(for: entry), format: .xml, options: 0)
            // Never overwrite an entry created concurrently or an existing foreign file.
            try data.write(to: agentURL(for: entry), options: .withoutOverwriting)
        } else if existing {
            try fm.removeItem(at: agentURL(for: entry))
        }
    }
    func remove(_ entry: StartupEntry) throws {
        try verifyRegistered(entry)
        try setEnabled(false, entry: entry)
        try save(entries().filter { $0.id != entry.id })
    }
}

enum ApplicationManagerFilter: String, CaseIterable, Identifiable {
    case all = "全部", running = "运行中", stopped = "未运行", loginEnabled = "已开登录启动"
    var id: String { rawValue }
}

enum ApplicationBatchOperation: Equatable { case launch, quit }

enum ApplicationManagerFiltering {
    static func filtered(_ apps: [StartupApplication], filter: ApplicationManagerFilter, search: String, runningPaths: Set<String>) -> [StartupApplication] {
        apps.filter { app in
            let matchesSearch = search.isEmpty || app.name.localizedCaseInsensitiveContains(search) || app.path.localizedCaseInsensitiveContains(search)
            let matchesFilter: Bool
            switch filter {
            case .all: matchesFilter = true
            case .running: matchesFilter = runningPaths.contains(app.path)
            case .stopped: matchesFilter = !runningPaths.contains(app.path)
            case .loginEnabled: matchesFilter = app.loginEnabled == true
            }
            return matchesSearch && matchesFilter
        }
    }
    static func batchPaths(_ operation: ApplicationBatchOperation, visible: [StartupApplication], selected: Set<String>, runningPaths: Set<String>) -> [String] {
        // Hidden selections never become surprise batch targets after a filter change.
        Set(visible.map(\.path)).intersection(selected).filter { path in
            switch operation {
            case .launch: return !runningPaths.contains(path)
            case .quit: return runningPaths.contains(path)
            }
        }.sorted()
    }
}

@MainActor final class StartupManagerState: ObservableObject {
    @Published var entries: [StartupEntry] = []
    @Published var enabled: Set<String> = []
    @Published var conflicts: Set<String> = []
    @Published var applications: [StartupApplication] = []
    @Published var services: [StartupLaunchService] = []
    @Published var notices: [String] = []
    @Published var message: String?
    @Published var search = ""
    @Published var tab = 0
    @Published var applicationFilter: ApplicationManagerFilter = .all
    @Published var selectedPaths: Set<String> = []
    @Published var batchBusy = false
    @Published var loginPaths: Set<String>?
    let runtime = ApplicationRuntime()
    private var metadataCache: [String: (NSImage, String)] = [:]
    private var canonicalPathCache: [String: String] = [:]
    let store: StartupStore
    init(store: StartupStore = .live) { self.store = store }
    private func canonicalPath(_ path: String) -> String {
        if let cached = canonicalPathCache[path] { return cached }
        let canonical = ApplicationRuntime.canonicalPath(path)
        canonicalPathCache[path] = canonical
        return canonical
    }
    var runningPaths: Set<String> {
        let live = Set(runtime.processes.map(\.bundlePath))
        return live.union(applications.filter { live.contains(canonicalPath($0.path)) }.map(\.path))
    }
    var displayApplications: [StartupApplication] {
        var list = applications
        var paths = Set(list.map { canonicalPath($0.path) })
        for process in runtime.processes where paths.insert(process.bundlePath).inserted {
            list.append(StartupApplication(path: process.bundlePath, name: process.name, loginEnabled: loginPaths.map { $0.contains(process.bundlePath) }))
        }
        return list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    var filteredApplications: [StartupApplication] {
        ApplicationManagerFiltering.filtered(displayApplications, filter: applicationFilter, search: search, runningPaths: runningPaths)
    }
    func metadata(for path: String) -> (icon: NSImage, version: String) {
        if let cached = metadataCache[path] { return cached }
        let version = Bundle(path: path)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let result = (NSWorkspace.shared.icon(forFile: path), version)
        metadataCache[path] = result
        return result
    }
    func batchTargets(_ operation: ApplicationBatchOperation) -> [String] {
        ApplicationManagerFiltering.batchPaths(operation, visible: filteredApplications, selected: selectedPaths, runningPaths: runningPaths)
    }
    func performRuntime(_ action: ApplicationRuntimeAction, path: String, expectedProcesses: [ManagedApplicationProcess]? = nil) {
        message = nil
        Task { @MainActor in
            do { try await runtime.perform(action, path: path, expectedProcesses: expectedProcesses) }
            catch { message = error.localizedDescription }
            runtime.refresh()
        }
    }
    func performBatch(_ operation: ApplicationBatchOperation) {
        let paths = batchTargets(operation)
        guard !paths.isEmpty, !batchBusy else { return }
        batchBusy = true
        message = nil
        Task { @MainActor in
            var failures: [String] = []
            for path in paths {
                do { try await runtime.perform(operation == .launch ? .launch : .quit, path: path) }
                catch { failures.append("\(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)：\(error.localizedDescription)") }
            }
            runtime.refresh()
            batchBusy = false
            if !failures.isEmpty { message = failures.joined(separator: "\n") }
        }
    }
    var filteredServices: [StartupLaunchService] {
        services.filter { search.isEmpty || $0.label.localizedCaseInsensitiveContains(search) || ($0.applicationPath ?? "").localizedCaseInsensitiveContains(search) }
    }
    func refresh() {
        metadataCache = [:]
        canonicalPathCache = [:]
        notices = []
        do {
            entries = try store.entries()
            enabled = []; conflicts = []
            for entry in entries {
                do { if try store.isEnabled(entry) { enabled.insert(entry.id) } }
                catch { conflicts.insert(entry.id); notices.append(error.localizedDescription) }
            }
        } catch { notices.append(error.localizedDescription) }
        var loginItems: [StartupLoginRecord]?
        do { loginItems = try StartupSystemAccess.loginItems() }
        catch { notices.append(error.localizedDescription) }
        loginPaths = loginItems.map { Set($0.map(\.path)) }
        let home = FileManager.default.homeDirectoryForCurrentUser
        applications = StartupInstalledApplications.scan(roots: [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/System/Applications"), home.appendingPathComponent("Applications")], loginItems: loginItems)
        if let loginItems, loginItems.contains(where: { !$0.path.hasPrefix("/") }) {
            notices.append("部分系统登录项没有可用路径，无法安全直接修改；请在系统登录项设置中检查。")
        }
        var disabled: [String: [String: Bool]] = [:]
        let userDomain = StartupLaunchControl.userDomain
        for domain in [userDomain, "system"] {
            do { disabled[domain] = try StartupLaunchControl.disabled(in: domain) }
            catch { notices.append("启动域 \(domain)：\(error.localizedDescription)") }
        }
        services = StartupLaunchService.read(directories: [
            (home.appendingPathComponent("Library/LaunchAgents"), userDomain),
            (URL(fileURLWithPath: "/Library/LaunchAgents"), userDomain),
            (URL(fileURLWithPath: "/Library/LaunchDaemons"), "system"),
            (URL(fileURLWithPath: "/System/Library/LaunchAgents"), userDomain),
            (URL(fileURLWithPath: "/System/Library/LaunchDaemons"), "system")], disabled: disabled, errors: &notices)
        services += StartupLaunchService.embedded(in: applications, userDomain: userDomain, disabled: disabled, errors: &notices)
        for entry in entries {
            let ownFile = enabled.contains(entry.id)
            let ownEffective = ownFile ? services.first(where: { $0.label == entry.id && $0.domain == userDomain })?.enabled : false
            let standard = loginItems.map { $0.contains { $0.path == entry.applicationPath } }
            let effective: Bool? = (standard == true || ownEffective == true) ? true : (standard == nil || ownEffective == nil ? nil : false)
            if let index = applications.firstIndex(where: { $0.path == entry.applicationPath }) {
                let app = applications[index]
                applications[index] = StartupApplication(path: app.path, name: app.name, loginEnabled: effective)
            } else {
                applications.append(StartupApplication(path: entry.applicationPath, name: entry.name, loginEnabled: effective))
            }
        }
        runtime.refresh()
    }
    func perform(_ action: () throws -> Void) {
        message = nil
        do { try action() } catch { message = error.localizedDescription }
        refresh()
    }
    func setApplicationLogin(_ value: Bool, path: String) throws {
        try StartupSystemAccess.setLoginItem(path: path, enabled: value)
        // Migrate old own-agent entries to the standard login item to avoid duplicate launches.
        for entry in entries where entry.applicationPath == path {
            try store.setEnabled(false, entry: entry)
        }
    }
    func chooseApplication() {
        let panel = NSOpenPanel()
        panel.title = "添加登录时打开的应用"
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform { try setApplicationLogin(true, path: url.standardizedFileURL.path) }
    }
}

@MainActor final class StartupManagerWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let state = StartupManagerState()
    func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "应用与启动项管理"
            window.delegate = self
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: StartupManagerView(state: state, runtime: state.runtime))
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        state.runtime.startObserving()
        state.refresh()
    }
    func windowWillClose(_ notification: Notification) { state.runtime.stopObserving() }
    func shutdown() { state.runtime.stopObserving() }
}

private struct StartupManagerView: View {
    @ObservedObject var state: StartupManagerState
    @ObservedObject var runtime: ApplicationRuntime
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("应用与启动项管理").font(.title2.bold())
                Spacer()
                Button("刷新") { state.message = nil; state.refresh() }
                Button("系统登录项设置") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") { NSWorkspace.shared.open(url) }
                }
                Button("添加应用…") { state.chooseApplication() }
            }
            Text("启动、显示或退出应用；独立设置标准登录项和后台启动服务。启动设置变更影响以后登录或加载；首次读取标准登录项需要自动化授权。")
                .font(.caption).foregroundStyle(.secondary)
            TextField("搜索应用、路径或服务标签", text: $state.search).textFieldStyle(.roundedBorder)
            Picker("查看", selection: $state.tab) {
                Text("应用（\(state.displayApplications.count)）").tag(0)
                Text("后台启动服务（\(state.services.count)）").tag(1)
                if !state.entries.isEmpty { Text("旧版 OmniDesk 项目").tag(2) }
            }.pickerStyle(.segmented)
            if state.tab == 0 { applicationsList }
            else if state.tab == 1 { servicesList }
            else { legacyList }
            Text("应用列表扫描 /Applications、/System/Applications、~/Applications（最多 5 层）并合并系统标准登录项；内嵌启动配置与登录辅助程序在后台服务中列出。开关仅表示标准登录项，不代表其他启动机制。SMAppService 注册状态无法通过公共接口完整查询或代其他应用修改，未确认的项目显示未知，请由原应用或系统设置管理。")
                .font(.caption2).foregroundStyle(.secondary)
            if let message = state.message { Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            if !state.notices.isEmpty {
                ScrollView { Text(Array(Set(state.notices)).sorted().joined(separator: "\n")).font(.caption).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }.frame(maxHeight: 75)
            }
        }.padding(18).frame(minWidth: 980, minHeight: 640)
    }
    private var applicationsList: some View {
        let allApplications = state.displayApplications
        let runningPaths = state.runningPaths
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("筛选", selection: $state.applicationFilter) {
                    ForEach(ApplicationManagerFilter.allCases) { filter in Text(filter.rawValue).tag(filter) }
                }.pickerStyle(.segmented).frame(maxWidth: 480)
                Spacer()
                Text("显示 \(state.filteredApplications.count) · 运行 \(allApplications.filter { runningPaths.contains($0.path) }.count) · 登录开启 \(allApplications.filter { $0.loginEnabled == true }.count) · 登录未知 \(allApplications.filter { $0.loginEnabled == nil }.count)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Toggle("全选当前列表", isOn: Binding(get: {
                    let paths = Set(state.filteredApplications.map(\.path))
                    return !paths.isEmpty && paths.isSubset(of: state.selectedPaths)
                }, set: { value in
                    let paths = Set(state.filteredApplications.map(\.path))
                    if value { state.selectedPaths.formUnion(paths) } else { state.selectedPaths.subtract(paths) }
                })).toggleStyle(.checkbox)
                Text("选中可见 \(Set(state.filteredApplications.map(\.path)).intersection(state.selectedPaths).count) / 总计 \(state.selectedPaths.count)").font(.caption).foregroundStyle(.secondary)
                Button("清空选择") { state.selectedPaths = [] }.disabled(state.selectedPaths.isEmpty)
                Spacer()
                if state.batchBusy { ProgressView().controlSize(.small) }
                Button("启动所选（\(state.batchTargets(.launch).count)）") { state.performBatch(.launch) }
                    .disabled(state.batchBusy || state.batchTargets(.launch).isEmpty)
                Button("普通退出所选（\(state.batchTargets(.quit).count)）") { state.performBatch(.quit) }
                    .disabled(state.batchBusy || state.batchTargets(.quit).isEmpty)
            }.font(.caption)
            List(state.filteredApplications) { app in
                ApplicationManagerRow(app: app, state: state, runtime: runtime)
            }
            Text("批量操作仅作用于当前可见且选中的应用；退出会向应用发送正常退出请求，应用可能弹出保存提示。强制退出仅可逐个确认执行。")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
    private var servicesList: some View {
        List(state.filteredServices) { service in
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(service.label).font(.headline)
                    if let app = service.applicationPath { Text(app).font(.caption).foregroundStyle(.secondary) }
                    Text(service.path).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                    Text(service.domain == "system" ? "系统后台服务 · 修改需管理员认证" : "当前用户的后台启动服务").font(.caption2).foregroundStyle(.secondary)
                    if let reason = service.reason { Text(reason).font(.caption).foregroundStyle(.orange) }
                }
                Spacer()
                if let enabled = service.enabled {
                    Toggle("允许启动", isOn: Binding(get: { enabled }, set: { value in
                        state.perform { try StartupLaunchControl.setEnabled(value, service: service) }
                    })).toggleStyle(.switch).disabled(!service.canModify)
                } else { Text("状态未知").foregroundStyle(.orange) }
            }.padding(.vertical, 5)
        }
    }
    private var legacyList: some View {
        List(state.entries) { entry in
            HStack {
                VStack(alignment: .leading) {
                    Text(entry.name).font(.headline)
                    Text(entry.applicationPath).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if state.conflicts.contains(entry.id) { Text("文件冲突").foregroundStyle(.red) }
                Button("转为系统登录项") { state.perform { try state.setApplicationLogin(true, path: entry.applicationPath) } }
                Button("移除") { state.perform { try state.store.remove(entry) } }
            }
        }
    }
}

private struct ApplicationManagerRow: View {
    let app: StartupApplication
    @ObservedObject var state: StartupManagerState
    @ObservedObject var runtime: ApplicationRuntime
    private var processes: [ManagedApplicationProcess] { runtime.processes(for: app.path) }
    private var running: Bool { !processes.isEmpty }
    private var busy: Bool { runtime.busyPaths.contains(ApplicationRuntime.canonicalPath(app.path)) || state.batchBusy }
    var body: some View {
        HStack(spacing: 10) {
            Toggle("选择 \(app.name)", isOn: Binding(get: { state.selectedPaths.contains(app.path) }, set: { value in
                if value { state.selectedPaths.insert(app.path) } else { state.selectedPaths.remove(app.path) }
            })).labelsHidden().toggleStyle(.checkbox).frame(width: 20)
            Image(nsImage: state.metadata(for: app.path).icon).resizable().scaledToFit().frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(app.name).font(.headline).lineLimit(1)
                    Text("v\(state.metadata(for: app.path).version)").font(.caption).foregroundStyle(.secondary)
                    Text(running ? "运行中" : "未运行").font(.caption).foregroundStyle(running ? Color.green : Color.secondary)
                }
                Text(app.path).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(app.path)
                if running {
                    Text("PID：" + processes.map { String($0.pid) }.joined(separator: ", ")).font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                }
                let services = state.services.filter { $0.applicationPath == app.path }
                if !services.isEmpty {
                    Text("后台配置 \(services.count) · 允许 \(services.filter { $0.enabled == true }.count) · 未知 \(services.filter { $0.enabled == nil }.count)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            loginControl.frame(width: 122)
            if busy { ProgressView().controlSize(.small).frame(width: 18) }
            HStack(spacing: 6) {
                if running {
                    Button("显示") { state.performRuntime(.activate, path: app.path) }
                    Button("退出") { state.performRuntime(.quit, path: app.path) }
                } else {
                    Button("启动") { state.performRuntime(.launch, path: app.path) }
                }
                Menu {
                    Button("显示到前台") { state.performRuntime(.activate, path: app.path) }.disabled(!running)
                    Button("隐藏") { state.performRuntime(.hide, path: app.path) }.disabled(!running)
                    Button("取消隐藏") { state.performRuntime(.unhide, path: app.path) }.disabled(!running)
                    Button("重新启动…") { state.performRuntime(.restart, path: app.path) }.disabled(!running)
                    Divider()
                    Button("强制退出…", role: .destructive) { confirmForceQuit() }.disabled(!running)
                    Divider()
                    Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.path)]) }
                    Button("复制路径") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(app.path, forType: .string)
                    }
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).frame(width: 22)
            }.buttonStyle(.bordered).controlSize(.small).frame(width: 160, alignment: .trailing).disabled(busy)
        }.padding(.vertical, 5)
    }
    @ViewBuilder private var loginControl: some View {
        if let enabled = app.loginEnabled {
            Toggle("标准登录项", isOn: Binding(get: { enabled }, set: { value in
                state.perform { try state.setApplicationLogin(value, path: app.path) }
            })).toggleStyle(.switch).controlSize(.small).disabled(busy)
        } else { Text("登录状态未知").font(.caption).foregroundStyle(.orange).help("请授权自动化后刷新；其他应用管理的注册状态可能无法查询。") }
    }
    private func confirmForceQuit() {
        let confirmedProcesses = processes
        let alert = NSAlert()
        alert.messageText = "强制退出“\(app.name)”？"
        alert.informativeText = "强制退出可能导致未保存的数据丢失。将结束此应用当前匹配的所有实例（PID：\(confirmedProcesses.map { String($0.pid) }.joined(separator: ", "))）。建议先使用普通退出。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "强制退出")
        if alert.runModal() == .alertSecondButtonReturn {
            state.performRuntime(.forceQuit, path: app.path, expectedProcesses: confirmedProcesses)
        }
    }
}
