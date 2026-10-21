import AppKit
import SwiftUI
import Darwin

struct FanReading: Codable, Identifiable {
    let id: Int
    let actual: Double
    let minimum: Double
    let maximum: Double
    let target: Double
    let mode: Int
}
struct FanReply: Codable {
    let fans: [FanReading]
    let error: String?
    let state: String
}
enum FanSafety {
    static func maximumRPM(minimum: Double, maximum: Double) -> Double? {
        guard minimum.isFinite, maximum.isFinite, minimum >= 0, maximum > 0,
              maximum >= minimum, maximum <= 30000 else { return nil }
        return maximum
    }
    static func verifiedMaximum(_ fans: [FanReading]) -> Bool {
        !fans.isEmpty && fans.allSatisfy {
            maximumRPM(minimum: $0.minimum, maximum: $0.maximum) != nil &&
            $0.mode == 1 && $0.target.isFinite && abs($0.target - $0.maximum) <= 2
        }
    }
    static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

@MainActor
final class FanControlWindow: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var fans: [FanReading] = []
    @Published private(set) var message = "正在读取风扇…"
    @Published private(set) var maximum = false
    @Published private(set) var busy = false
    @Published private(set) var fanless = false
    private var panel: NSWindow?
    private var timer: Timer?
    private var tick = 0
    private var readInProgress = false
    private var wantsMaximum = false
    private var controlError: String?
    private var sessionID = UUID()
    private var listener: Int32 = -1
    private var connection: Int32 = -1
    private var socketDirectory: URL?
    private var socketSource: DispatchSourceRead?
    private var acceptSource: DispatchSourceRead?
    private var received = ""
    private var observers: [NSObjectProtocol] = []
    private let queue = DispatchQueue(label: "OmniDesk.Fan.Read", qos: .utility)
    private var helper: URL? {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/OmniDeskFanHelper")
    }
    override init() {
        super.init()
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.restore() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.restore(); self?.refresh() }
        })
    }
    func show() {
        if panel == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 510, height: 405),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "风扇控制"
            window.contentView = NSHostingView(rootView: FanControlView(model: self))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            panel = window
        }
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        startTimer()
        refresh()
    }
    func windowWillClose(_ notification: Notification) {
        // Closing the panel ends boost too; there is no invisible persistent override.
        restore()
        stopIfIdle()
    }
    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.tick += 1
                if self.connection >= 0 { self.send("ping") }
                if self.tick % 2 == 0, self.panel?.isVisible == true { self.refresh() }
                self.stopIfIdle()
            }
        }
    }
    private func stopIfIdle() {
        if panel?.isVisible != true && connection < 0 && !busy { timer?.invalidate(); timer = nil }
    }
    private func refresh() {
        if connection >= 0 { return } // Privileged session supplies live telemetry.
        guard !readInProgress, let executable = helper, FileManager.default.isExecutableFile(atPath: executable.path) else {
            if helper.map({ !FileManager.default.isExecutableFile(atPath: $0.path) }) ?? true { message = "缺少风扇助手，请使用完整应用包。" }
            return
        }
        readInProgress = true
        queue.async { [weak self] in
            let process = Process(), pipe = Pipe()
            process.executableURL = executable; process.arguments = ["read"]
            process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            var reply: FanReply?
            var issue: String?
            do {
                try process.run()
                let output = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                reply = output.split(separator: 10).reversed().compactMap { try? JSONDecoder().decode(FanReply.self, from: Data($0)) }.first
                if reply == nil { issue = "无法读取风扇。可点击最大转速通过管理员授权尝试。" }
            } catch { issue = error.localizedDescription }
            let result = reply, failure = issue
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.readInProgress = false
                if let result {
                    self.fans = result.fans
                    self.fanless = result.error == nil && result.fans.isEmpty
                    if !self.maximum && !self.busy && self.controlError == nil {
                        self.message = result.error ?? (self.fanless ? "此设备没有风扇（例如 MacBook Air）。" : "系统自动调节散热")
                    }
                } else if !self.maximum && !self.busy && self.controlError == nil { self.message = failure ?? "风扇读取失败" }
            }
        }
    }
    func boost() {
        guard !busy, !fanless else { return }
        controlError = nil
        if connection >= 0 { wantsMaximum = true; busy = true; message = "正在设置硬件最大转速…"; send("max"); return }
        guard let executable = helper, FileManager.default.isExecutableFile(atPath: executable.path) else { message = "缺少风扇助手"; return }
        do { try prepareSocket() } catch { message = error.localizedDescription; disconnect(); return }
        let generation = sessionID
        wantsMaximum = true
        busy = true
        message = "请在系统授权窗口中允许风扇控制…"
        startTimer()
        let command = FanSafety.shellQuote(executable.path) + " session \(getpid()) \(getuid()) " + FanSafety.shellQuote(socketDirectory!.appendingPathComponent("control").path) + " </dev/null >/dev/null 2>&1 &"
        // Quote shell first, then AppleScript. No user-supplied command or RPM enters this shell.
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let scriptText = "do shell script \"\(escaped)\" with administrator privileges with prompt \"OmniDesk 请求将风扇提升到硬件最大转速，最长 10 分钟。\""
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var error: NSDictionary?
            NSAppleScript(source: scriptText)?.executeAndReturnError(&error)
            let failure = error?[NSAppleScript.errorMessage] as? String
            Task { @MainActor [weak self] in
                guard let self, self.sessionID == generation else { return }
                if let failure { self.message = "未启动风扇控制：\(failure)"; self.controlError = self.message; self.busy = false; self.disconnect() }
                else {
                    // Accept runs on main queue after authorization returns.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
                        guard let self, self.sessionID == generation, self.busy, self.connection < 0 else { return }
                        self.message = "风扇助手未能连接，请重新尝试。"; self.controlError = self.message; self.busy = false; self.disconnect()
                    }
                }
            }
        }
    }
    private func prepareSocket() throws {
        disconnect()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("odf-" + String(UUID().uuidString.prefix(12)))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        socketDirectory = directory
        let path = directory.appendingPathComponent("control").path
        guard path.utf8.count < 104 else { throw NSError(domain: "FanControl", code: 1, userInfo: [NSLocalizedDescriptionKey: "临时目录地址过长"] ) }
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            destination.copyBytes(from: Array(path.utf8) + [0])
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0, Darwin.listen(listener, 1) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: .main)
        source.setEventHandler { [weak self] in self?.acceptHelper() }
        acceptSource = source; source.resume()
    }
    private func acceptHelper() {
        let fd = Darwin.accept(listener, nil, nil)
        guard fd >= 0 else { return }
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == 0, connection < 0 else { Darwin.close(fd); return }
        connection = fd
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in self?.receive() }
        socketSource = source; source.resume()
    }
    private func receive() {
        var bytes = [UInt8](repeating: 0, count: 8192)
        let count = Darwin.read(connection, &bytes, bytes.count)
        if count < 0 && errno == EAGAIN { return }
        guard count > 0 else {
            if (maximum || busy) && controlError == nil { message = "控制会话已结束，助手正在恢复系统自动调节。" }
            maximum = false; busy = false; disconnect(); refresh(); return
        }
        received += String(decoding: bytes.prefix(count), as: UTF8.self)
        guard received.utf8.count < 65536 else { restore(); return }
        while let newline = received.firstIndex(of: "\n") {
            let line = String(received[..<newline]); received.removeSubrange(...newline)
            guard let data = line.data(using: .utf8), let reply = try? JSONDecoder().decode(FanReply.self, from: data) else { continue }
            if reply.state == "ready" {
                if wantsMaximum { message = "正在设置硬件最大转速…"; send("max") }
                else { send("auto") }
                continue
            }
            fans = reply.fans
            maximum = ["maximum", "ramping"].contains(reply.state) && FanSafety.verifiedMaximum(reply.fans)
            busy = reply.state == "restore-error"
            if let error = reply.error { message = error; controlError = error }
            else if reply.state == "ramping" { message = "目标已设置，正在核验实际转速上升…" }
            else if maximum { message = "实际转速已达到硬件上限的 90% 以上。最长 10 分钟后自动恢复。" }
            else { message = "已恢复系统自动调节" }
        }
    }
    private func send(_ command: String) {
        guard connection >= 0, let data = (command + "\n").data(using: .utf8) else { return }
        var noSignal: Int32 = 1
        _ = setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        data.withUnsafeBytes { buffer in if let base = buffer.baseAddress { _ = Darwin.write(connection, base, data.count) } }
    }
    func restore() {
        controlError = nil
        wantsMaximum = false
        guard connection >= 0 else { return }
        busy = true; message = "正在恢复系统自动调节…"; send("auto")
    }
    func shutdown() {
        wantsMaximum = false
        send("auto")
        disconnect() // EOF also triggers privileged helper's independent reset watchdog.
        timer?.invalidate(); timer = nil
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
    }
    private func disconnect() {
        sessionID = UUID()
        socketSource?.cancel(); socketSource = nil
        acceptSource?.cancel(); acceptSource = nil
        if connection >= 0 { Darwin.close(connection); connection = -1 }
        if listener >= 0 { Darwin.close(listener); listener = -1 }
        received = ""
        if let directory = socketDirectory {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("control"))
            try? FileManager.default.removeItem(at: directory)
        }
        socketDirectory = nil
        maximum = false
        stopIfIdle()
    }
}

private struct FanControlView: View {
    @ObservedObject var model: FanControlWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "fan.fill").font(.system(size: 32)).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 4) {
                    Text("风扇控制").font(.title2.bold())
                    Text("系统自动 · 硬件最大转速").foregroundStyle(.secondary)
                }
                Spacer()
            }
            Divider()
            if model.fans.isEmpty {
                Text(model.fanless ? "无风扇设备" : "正在获取传感器数据").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 74)
            } else {
                ForEach(model.fans) { fan in
                    HStack {
                        Text("风扇 \(fan.id + 1)")
                        Spacer()
                        Text("\(Int(fan.actual)) RPM").monospacedDigit().font(.headline)
                        Text("上限 \(Int(fan.maximum))").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Text(model.message).font(.callout).foregroundStyle(model.maximum ? Color.blue : Color.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack {
                Button("系统自动") { model.restore() }.disabled(!model.maximum && !model.busy)
                Spacer()
                Button(model.busy ? "正在处理…" : "最大转速") { model.boost() }
                    .buttonStyle(.borderedProminent).disabled(model.busy || model.fanless || model.maximum)
            }
            Text("最大转速会增加噪音与耗电。关闭面板、退出、睡眠或会话超时后恢复系统自动。首次操作需管理员授权。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(minWidth: 460, minHeight: 350)
    }
}
