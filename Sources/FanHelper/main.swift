// OmniDesk's narrowly scoped, on-demand fan helper. No launch daemon or installer.
import Foundation
import Darwin

struct FanRestoreRetry {
    private(set) var pending = false
    private var lastAttempt: TimeInterval = 0
    mutating func record(success: Bool, now: TimeInterval) {
        pending = !success
        lastAttempt = now
    }
    func shouldRetry(now: TimeInterval) -> Bool { pending && now - lastAttempt >= 1 }
}

struct Reading: Codable {
    let id: Int
    let actual: Double
    let minimum: Double
    let maximum: Double
    let target: Double
    let mode: Int
}
struct Reply: Codable {
    let fans: [Reading]
    let error: String?
    let state: String
}
func readings(_ smc: SMC) throws -> [Reading] {
    let number = try smc.numericValue("FNum")
    guard number.isFinite, (0...10).contains(number), number.rounded() == number else {
        throw NSError(domain: "OmniDeskFan", code: 1, userInfo: [NSLocalizedDescriptionKey: "本机无法读取风扇控制器"])
    }
    return try (0..<Int(number)).map { id in
        let actual = try smc.numericValue("F\(id)Ac"), minimum = try smc.numericValue("F\(id)Mn"), maximum = try smc.numericValue("F\(id)Mx")
        guard actual.isFinite, minimum.isFinite, maximum.isFinite,
              (0...30000).contains(actual), (0...30000).contains(minimum), (0...30000).contains(maximum) else {
            throw NSError(domain: "OmniDeskFan", code: 2, userInfo: [NSLocalizedDescriptionKey: "风扇 \(id + 1) 传感器数据不完整"])
        }
        return Reading(id: id, actual: actual, minimum: minimum, maximum: maximum,
                       target: (try? smc.numericValue("F\(id)Tg")) ?? 0, mode: Int((try? smc.numericValue(smc.fanModeKey(id))) ?? -1))
    }
}
func emit(_ value: Reply, to fd: Int32 = STDOUT_FILENO) {
    guard var data = try? JSONEncoder().encode(value) else { return }
    data.append(10)
    data.withUnsafeBytes { buffer in
        if let base = buffer.baseAddress { _ = Darwin.write(fd, base, data.count) }
    }
}
var diagnosticFD = STDOUT_FILENO
func fail(_ text: String) -> Never { emit(Reply(fans: [], error: text, state: "error"), to: diagnosticFD); exit(1) }
let arguments = CommandLine.arguments
if arguments.count == 2, arguments[1] == "--self-test" {
    // No SMC instantiation or IOKit calls: build/package verification only.
    do {
        let decoded1 = try decodeFanNumber(type: "ui8 ", size: 1, bytes: [0]); precondition(decoded1 == 0)
        let decoded2 = try decodeFanNumber(type: "flt ", size: 4, bytes: [0, 0, 0, 0]); precondition(decoded2 == 0)
        let decoded3 = try decodeFanNumber(type: "fpe2", size: 2, bytes: [0x5d, 0xc0]); precondition(decoded3 == 6000)
        var writes = 0
        try settleFanWrite(attempts: 4, write: { writes += 1 }, matches: { writes >= 3 }, pause: {}, failure: "fixture transition")
        precondition(writes == 3, "Transient old mode must be retried")
        var rejected = false
        do { try settleFanWrite(attempts: 2, write: { throw NSError(domain: "fixture", code: 42) }, matches: { true }, pause: {}, failure: "fixture reject") }
        catch { rejected = (error as NSError).code == 42 }
        precondition(rejected, "Firmware rejection must remain an error")
        var reset = FanRestoreRetry()
        reset.record(success: false, now: 10)
        precondition(reset.pending && !reset.shouldRetry(now: 10.5))
        precondition(reset.shouldRetry(now: 11))
        reset.record(success: false, now: 11)
        precondition(reset.shouldRetry(now: 12))
        reset.record(success: true, now: 12)
        precondition(!reset.pending && !reset.shouldRetry(now: 20))
    } catch { fail("纯解码/固件状态迁移校验失败") }
    emit(Reply(fans: [Reading(id: 0, actual: 1500, minimum: 1200, maximum: 6000, target: 6000, mode: 1)], error: nil, state: "fixture"))
    exit(0)
}
if arguments.count == 2, arguments[1] == "read" {
    let smc = SMC()
    do { emit(Reply(fans: try readings(smc), error: nil, state: "read")) }
    catch { fail(error.localizedDescription) }
    exit(0)
}
let transportFixture = arguments.count > 1 && arguments[1] == "--transport-fixture"
guard arguments.count == 5, (arguments[1] == "session" && geteuid() == 0) || transportFixture,
      let parent = Int32(arguments[2]), parent > 1, let expectedUID = UInt32(arguments[3]), expectedUID > 0 else {
    fail("不支持的助手调用")
}
let socketPath = arguments[4]
guard socketPath.utf8.count < 104, socketPath.hasPrefix("/"), !socketPath.contains("\n") else { fail("无效的会话地址") }
let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else { fail("无法建立会话") }
var address = sockaddr_un()
address.sun_family = sa_family_t(AF_UNIX)
let length = MemoryLayout<sockaddr_un>.size
withUnsafeMutableBytes(of: &address.sun_path) { destination in
    destination.initializeMemory(as: UInt8.self, repeating: 0)
    destination.copyBytes(from: Array(socketPath.utf8) + [0])
}
let connected = withUnsafePointer(to: &address) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(length)) }
}
guard connected == 0 else { fail("无法连接原应用（errno \(errno)）") }
diagnosticFD = fd
var peerUID: uid_t = 0, peerGID: gid_t = 0
guard getpeereid(fd, &peerUID, &peerGID) == 0, peerUID == expectedUID else { fail("会话身份不匹配") }
var peerPID: pid_t = 0
var peerPIDSize = socklen_t(MemoryLayout<pid_t>.size)
guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &peerPID, &peerPIDSize) == 0, peerPID == parent else { fail("会话进程不匹配") }
_ = signal(SIGPIPE, SIG_IGN)
if transportFixture {
    // Exercises the exact Unix-socket connection, UID/PID authentication and
    // framing above, while deliberately never opening AppleSMC.
    emit(Reply(fans: [], error: nil, state: "ready"), to: fd)
    var fixtureBuffer = ""
    while true {
        var bytes = [UInt8](repeating: 0, count: 1024)
        let count = Darwin.read(fd, &bytes, bytes.count)
        if count <= 0 { exit(0) }
        fixtureBuffer += String(decoding: bytes.prefix(count), as: UTF8.self)
        if fixtureBuffer.count > 4096 { exit(1) }
        while let newline = fixtureBuffer.firstIndex(of: "\n") {
            let command = String(fixtureBuffer[..<newline]); fixtureBuffer.removeSubrange(...newline)
            if command == "ping" { continue }
            if command == "auto" { emit(Reply(fans: [], error: nil, state: "automatic"), to: fd); exit(0) }
            guard command == "max" else { exit(1) }
            emit(Reply(fans: [Reading(id: 0, actual: 6000, minimum: 1200, maximum: 6000, target: 6000, mode: 1)], error: nil, state: "maximum"), to: fd)
        }
    }
}
let smc = SMC()
var ids: [Int] = []
var changed = false
var lastPing = Date()
let deadline = Date().addingTimeInterval(600)
var pending = ""
var boostStarted: Date?
var lastTelemetry = Date.distantPast
var repairAttempts = 0
var restoreRetry = FanRestoreRetry()
func restore() -> Bool {
    // An automatic request permanently ends this boost, even if resetting
    // one fan needs retries. Telemetry must never repair it back to maximum.
    boostStarted = nil
    guard changed else { return true }
    do {
        try smc.checkedAutomatic(ids)
        changed = false
        restoreRetry.record(success: true, now: ProcessInfo.processInfo.systemUptime)
        return true
    } catch {
        restoreRetry.record(success: false, now: ProcessInfo.processInfo.systemUptime)
        emit(Reply(fans: [], error: "恢复系统自动失败，正在重试：\(error.localizedDescription)", state: "restore-error"), to: fd)
        return false
    }
}
// Even after client death keep retrying automatic restoration for transient SMC rejection.
func finish() -> Never {
    if changed {
        while !restore() { sleep(1) }
    }
    close(fd)
    exit(0)
}
emit(Reply(fans: [], error: nil, state: "ready"), to: fd)
while true {
    if kill(parent, 0) != 0 || Date() > deadline || Date().timeIntervalSince(lastPing) > 15 { finish() }
    // Restoration retries are independent of telemetry/boostStarted and pings.
    // Once rollback starts, max commands cannot interrupt it.
    if restoreRetry.shouldRetry(now: ProcessInfo.processInfo.systemUptime), restore() {
        emit(Reply(fans: (try? readings(smc)) ?? [], error: nil, state: "automatic"), to: fd)
        finish()
    }
    var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    let ready = poll(&pollFD, 1, 1000)
    if ready < 0 { finish() }
    if changed, !restoreRetry.pending, let started = boostStarted, Date().timeIntervalSince(lastTelemetry) >= 1 {
        lastTelemetry = Date()
        do {
            var observed = try readings(smc)
            if !observed.allSatisfy({ $0.mode == 1 && abs($0.target - $0.maximum) <= 2 }) {
                guard repairAttempts < 2 else { throw NSError(domain: "OmniDeskFan", code: 5, userInfo: [NSLocalizedDescriptionKey: "系统持续覆盖手动风扇目标，已停止最大转速模式"]) }
                repairAttempts += 1
                try smc.checkedMaximum(ids)
                lastPing = Date()
                observed = try readings(smc)
            }
            let attained = observed.allSatisfy { $0.actual >= $0.maximum * 0.9 }
            if !attained && Date().timeIntervalSince(started) >= 25 {
                throw NSError(domain: "OmniDeskFan", code: 6, userInfo: [NSLocalizedDescriptionKey: "目标已写入，但 25 秒内实际转速未接近硬件上限；已恢复自动，未将写入成功当作提速成功"])
            }
            emit(Reply(fans: observed, error: nil, state: attained ? "maximum" : "ramping"), to: fd)
        } catch {
            let restored = restore()
            boostStarted = nil
            emit(Reply(fans: (try? readings(smc)) ?? [], error: error.localizedDescription, state: restored ? "automatic" : "restore-error"), to: fd)
        }
    }
    if ready == 0 { continue }
    if pollFD.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { finish() }
    var bytes = [UInt8](repeating: 0, count: 512)
    let count = Darwin.read(fd, &bytes, bytes.count)
    if count <= 0 { finish() }
    pending += String(decoding: bytes.prefix(count), as: UTF8.self)
    if pending.utf8.count > 1024 { finish() }
    while let newline = pending.firstIndex(of: "\n") {
        let command = String(pending[..<newline]); pending.removeSubrange(...newline)
        lastPing = Date()
        switch command {
        case "ping": break
        case "max":
            if restoreRetry.pending {
                emit(Reply(fans: [], error: "正在重试恢复系统自动，请等待恢复完成", state: "restore-error"), to: fd)
                continue
            }
            do {
                let current = try readings(smc)
                ids = current.map(\.id)
                guard !ids.isEmpty else { throw NSError(domain: "OmniDeskFan", code: 3, userInfo: [NSLocalizedDescriptionKey: "此设备没有可控制风扇"] ) }
                changed = true // Mark BEFORE first write, so partial failures always roll back.
                try smc.checkedMaximum(ids)
                let observed = try readings(smc)
                guard observed.allSatisfy({ $0.mode == 1 && abs($0.target - $0.maximum) <= 2 }) else {
                    throw NSError(domain: "OmniDeskFan", code: 4, userInfo: [NSLocalizedDescriptionKey: "最大转速写入后校验失败"])
                }
                boostStarted = Date()
                repairAttempts = 0
                // A bounded handshake can outlast 15 seconds. It does not mean
                // the main app missed heartbeats; its pings are queued below.
                lastPing = Date()
                emit(Reply(fans: observed, error: nil, state: "ramping"), to: fd)
            } catch {
                lastPing = Date()
                boostStarted = nil
                let restored = restore()
                emit(Reply(fans: (try? readings(smc)) ?? [], error: error.localizedDescription + (restored ? "；已恢复系统自动" : "；正在重试恢复系统自动"), state: restored ? "automatic" : "restore-error"), to: fd)
            }
        case "auto":
            if restore() { emit(Reply(fans: (try? readings(smc)) ?? [], error: nil, state: "automatic"), to: fd); finish() }
        default: finish()
        }
    }
}
