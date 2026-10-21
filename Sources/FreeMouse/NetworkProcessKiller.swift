import Darwin
import Foundation

struct NetworkProcessIdentity: Equatable {
    let pid: Int32
    let startSeconds: UInt64
    let startMicroseconds: UInt64
    let name: String

    func matches(displayName: String) -> Bool {
        // nettop truncates some kernel names; the captured start time identifies
        // the instance when the user later clicks Kill.
        guard !name.isEmpty, !displayName.isEmpty else { return false }
        return name == displayName
            || (displayName.utf8.count >= 15 && name.hasPrefix(displayName))
            || (name.utf8.count >= 15 && displayName.hasPrefix(name))
    }

    func canAttach(displayName: String, samplingStartedAt: TimeInterval) -> Bool {
        let started = Double(startSeconds) + Double(startMicroseconds) / 1_000_000
        return samplingStartedAt.isFinite && started <= samplingStartedAt && matches(displayName: displayName)
    }
}

enum NetworkProcessKillError: Error, Equatable, LocalizedError {
    case invalidTarget, ownProcess, unavailable, identityChanged, permissionDenied
    case systemError(Int32)

    var errorDescription: String? {
        switch self {
        case .invalidTarget: return "不能结束系统保留进程。"
        case .ownProcess: return "请通过工具箱菜单退出 FreeMouse。"
        case .unavailable: return "进程已退出或无法核对进程身份，请等待列表刷新。"
        case .identityChanged: return "进程身份已变化，已取消操作，请等待列表刷新。"
        case .permissionDenied: return "当前账号没有结束此进程的权限；不会自动提权。"
        case .systemError(let code): return "结束进程失败：" + String(cString: strerror(code))
        }
    }
}

struct NetworkProcessKiller {
    var ownPID: Int32 = getpid()
    var readIdentity: (Int32) -> NetworkProcessIdentity? = NetworkProcessKiller.snapshot
    // Return errno immediately, before another system call can overwrite it.
    var sendSignal: (Int32, Int32) -> Int32 = { pid, signal in Darwin.kill(pid, signal) == 0 ? 0 : errno }

    func kill(_ expected: NetworkProcessIdentity) throws {
        guard expected.pid > 1 else { throw NetworkProcessKillError.invalidTarget }
        guard expected.pid != ownPID else { throw NetworkProcessKillError.ownProcess }
        guard let current = readIdentity(expected.pid) else { throw NetworkProcessKillError.unavailable }
        guard current == expected else { throw NetworkProcessKillError.identityChanged }
        let result = sendSignal(expected.pid, SIGKILL)
        switch result {
        case 0: return
        case ESRCH: throw NetworkProcessKillError.unavailable
        case EPERM, EACCES: throw NetworkProcessKillError.permissionDenied
        default: throw NetworkProcessKillError.systemError(result)
        }
    }

    static func snapshot(_ pid: Int32) -> NetworkProcessIdentity? {
        guard pid > 1 else { return nil }
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == Int32(size) else { return nil }
        func string<T>(_ value: T) -> String {
            var value = value
            return withUnsafeBytes(of: &value) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        }
        let name = string(info.pbi_name)
        return .init(pid: pid, startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec,
                     name: name.isEmpty ? string(info.pbi_comm) : name)
    }
}
