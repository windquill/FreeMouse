import AppKit
import Combine
import Darwin

struct ManagedApplicationProcess: Identifiable, Equatable {
    let pid: Int32
    let bundlePath: String
    let bundleIdentifier: String?
    let name: String
    let launchDate: Date?
    let identity: NetworkProcessIdentity?
    var id: Int32 { pid }
}

enum ApplicationRuntimeAction { case launch, activate, hide, unhide, quit, forceQuit, restart }

enum ApplicationRuntimeError: LocalizedError {
    case invalidApplication, busy, staleProcess, protectedApplication, permissionDenied, refused, stillRunning
    var errorDescription: String? {
        switch self {
        case .invalidApplication: return "应用无效：需要包含有效可执行文件的本地 .app。"
        case .busy: return "此应用正在处理其他操作。"
        case .staleProcess: return "应用进程已变化，请刷新列表后重试。"
        case .protectedApplication: return "不能在此处结束本工具或受保护的系统应用。"
        case .permissionDenied: return "无法验证此进程属于当前账号；不会自动提权。"
        case .refused: return "应用未接受操作请求。"
        case .stillRunning: return "应用仍在运行，可能正在等待保存或确认；未执行后续启动。"
        }
    }
}

@MainActor
final class ApplicationRuntime: ObservableObject {
    @Published private(set) var processes: [ManagedApplicationProcess] = []
    @Published private(set) var busyPaths: Set<String> = []
    private var observers: [NSObjectProtocol] = []
    private let workspace: NSWorkspace

    init(workspace: NSWorkspace = .shared) { self.workspace = workspace }
    deinit {
        for observer in observers { workspace.notificationCenter.removeObserver(observer) }
    }

    static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func validatedApplicationURL(_ path: String) throws -> URL {
        guard path.hasPrefix("/"), !path.contains("\0") else { throw ApplicationRuntimeError.invalidApplication }
        let url = URL(fileURLWithPath: canonicalPath(path), isDirectory: true)
        guard url.isFileURL, url.pathExtension.lowercased() == "app",
              let bundle = Bundle(url: url), bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String == "APPL",
              let executable = bundle.executableURL,
              executable.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(url.path + "/"),
              FileManager.default.isExecutableFile(atPath: executable.path)
        else { throw ApplicationRuntimeError.invalidApplication }
        return url
    }

    func startObserving() {
        guard observers.isEmpty else { return }
        let center = workspace.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refresh() }
            })
        }
        refresh()
    }
    func stopObserving() {
        for observer in observers { workspace.notificationCenter.removeObserver(observer) }
        observers.removeAll()
    }
    func refresh() {
        processes = workspace.runningApplications.compactMap { app in
            guard !app.isTerminated, let url = app.bundleURL, url.pathExtension.lowercased() == "app" else { return nil }
            return ManagedApplicationProcess(pid: app.processIdentifier, bundlePath: Self.canonicalPath(url.path),
                bundleIdentifier: app.bundleIdentifier, name: app.localizedName ?? url.deletingPathExtension().lastPathComponent,
                launchDate: app.launchDate, identity: NetworkProcessKiller.snapshot(app.processIdentifier))
        }.sorted { $0.pid < $1.pid }
    }
    func processes(for path: String) -> [ManagedApplicationProcess] {
        let canonical = Self.canonicalPath(path)
        return processes.filter { $0.bundlePath == canonical }
    }

    static func isProtected(pid: Int32, bundleIdentifier: String?, ownPID: Int32 = getpid()) -> Bool {
        pid <= 1 || pid == ownPID || ["com.apple.finder", "com.apple.dock", "com.apple.loginwindow",
            "com.apple.systemuiserver", "com.apple.windowserver"].contains(bundleIdentifier?.lowercased() ?? "")
    }

    private func revalidate(_ expected: ManagedApplicationProcess, destructive: Bool) throws -> NSRunningApplication {
        guard let app = NSRunningApplication(processIdentifier: expected.pid), !app.isTerminated,
              let url = app.bundleURL, Self.canonicalPath(url.path) == expected.bundlePath,
              app.bundleIdentifier == expected.bundleIdentifier, app.launchDate == expected.launchDate,
              let identity = expected.identity, NetworkProcessKiller.snapshot(expected.pid) == identity
        else { throw ApplicationRuntimeError.staleProcess }
        if destructive {
            guard !Self.isProtected(pid: expected.pid, bundleIdentifier: expected.bundleIdentifier) else {
                throw ApplicationRuntimeError.protectedApplication
            }
            var info = proc_bsdinfo()
            let size = MemoryLayout<proc_bsdinfo>.size
            guard proc_pidinfo(expected.pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == Int32(size), info.pbi_uid == getuid()
            else { throw ApplicationRuntimeError.permissionDenied }
        }
        return app
    }

    static func validatedConfirmedTargets(current: [ManagedApplicationProcess], expected: [ManagedApplicationProcess], path: String) throws -> [ManagedApplicationProcess] {
        let canonical = canonicalPath(path)
        guard !expected.isEmpty,
              expected.allSatisfy({ $0.bundlePath == canonical }),
              Set(expected.map(\.pid)).count == expected.count,
              current.sorted(by: { $0.pid < $1.pid }) == expected.sorted(by: { $0.pid < $1.pid })
        else { throw ApplicationRuntimeError.staleProcess }
        return expected
    }

    func perform(_ action: ApplicationRuntimeAction, path: String, expectedProcesses: [ManagedApplicationProcess]? = nil) async throws {
        let canonical = Self.canonicalPath(path)
        guard !busyPaths.contains(canonical) else { throw ApplicationRuntimeError.busy }
        let targets: [ManagedApplicationProcess]
        if action == .forceQuit {
            guard let expectedProcesses else { throw ApplicationRuntimeError.staleProcess }
            // Confirmation applies to these immutable instances, never a refreshed replacement.
            refresh()
            targets = try Self.validatedConfirmedTargets(current: processes(for: canonical), expected: expectedProcesses, path: canonical)
        } else if let expectedProcesses {
            refresh()
            targets = try Self.validatedConfirmedTargets(current: processes(for: canonical), expected: expectedProcesses, path: canonical)
        } else {
            targets = processes(for: canonical)
        }
        busyPaths.insert(canonical)
        defer { busyPaths.remove(canonical); refresh() }
        switch action {
        case .launch:
            try await launch(canonical)
        case .activate, .hide, .unhide:
            guard !targets.isEmpty else { throw ApplicationRuntimeError.staleProcess }
            for target in targets {
                let app = try revalidate(target, destructive: false)
                let accepted: Bool
                switch action {
                case .activate: accepted = app.isActive || app.activate(options: [.activateAllWindows])
                case .hide: accepted = app.isHidden || app.hide()
                default: accepted = !app.isHidden || app.unhide()
                }
                guard accepted else { throw ApplicationRuntimeError.refused }
            }
        case .quit, .forceQuit, .restart:
            if action == .restart { _ = try Self.validatedApplicationURL(canonical) }
            guard !targets.isEmpty else { throw ApplicationRuntimeError.staleProcess }
            // Check every target before requesting any termination.
            for target in targets { _ = try revalidate(target, destructive: true) }
            var quitting: [NSRunningApplication] = []
            for target in targets {
                let app = try revalidate(target, destructive: true)
                guard action == .forceQuit ? app.forceTerminate() : app.terminate() else { throw ApplicationRuntimeError.refused }
                quitting.append(app)
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(6))
            while quitting.contains(where: { !$0.isTerminated }) && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            guard quitting.allSatisfy(\.isTerminated) else { throw ApplicationRuntimeError.stillRunning }
            // A replacement instance must also prevent a restart from launching.
            if action == .restart {
                guard !workspace.runningApplications.contains(where: {
                    !$0.isTerminated && $0.bundleURL.map { Self.canonicalPath($0.path) == canonical } == true
                }) else { throw ApplicationRuntimeError.stillRunning }
                try await launch(canonical)
            }
        }
    }
    private func launch(_ path: String) async throws {
        let url = try Self.validatedApplicationURL(path)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        _ = try await workspace.openApplication(at: url, configuration: configuration)
    }
}
