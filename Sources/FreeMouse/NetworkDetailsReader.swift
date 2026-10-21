import Foundation
import CoreWLAN
import Darwin
import SystemConfiguration

enum NetworkDetailsReader {
    static func read(name: String?) -> NetworkInterfaceDetails? {
        guard let name else { return nil }
        let configured = (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface])?.first {
            (SCNetworkInterfaceGetBSDName($0) as String?) == name
        }
        var details = NetworkInterfaceDetails(name: name,
            displayName: configured.flatMap { SCNetworkInterfaceGetLocalizedDisplayName($0) as String? } ?? name,
            isUp: false,
            hardwareAddress: configured.flatMap { SCNetworkInterfaceGetHardwareAddressString($0) as String? })
        var addresses: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&addresses) == 0 {
            defer { freeifaddrs(addresses) }
            var pointer = addresses
            while let item = pointer {
                defer { pointer = item.pointee.ifa_next }
                guard String(cString: item.pointee.ifa_name) == name else { continue }
                details.isUp = item.pointee.ifa_flags & UInt32(IFF_UP) != 0 && item.pointee.ifa_flags & UInt32(IFF_RUNNING) != 0
                guard let address = item.pointee.ifa_addr else { continue }
                let family = Int32(address.pointee.sa_family)
                guard family == AF_INET || family == AF_INET6 else { continue }
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
                let text = String(cString: host)
                if family == AF_INET { details.localIPv4 = text }
                else if details.localIPv6 == nil || !text.hasPrefix("fe80:") { details.localIPv6 = text }
            }
        }
        // CoreWLAN returns nil when location authorization is unavailable. Never request it here.
        details.ssid = CWWiFiClient.shared().interface(withName: name)?.ssid()
        return details
    }
}

private final class NetworkProcessOutput: @unchecked Sendable {
    // Written by one reader; accessed by the caller only after its semaphore signals.
    var data = Data()
}

final class NetworkProcessRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var child: Process?
    private var revision = 0
    private let queue = DispatchQueue(label: "FreeMouse.network.processes", qos: .utility)
    enum ReadError: Error { case unavailable }
    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        revision += 1
        if let child, child.isRunning { child.terminate() }
    }
    func read() async -> Result<String, Error> {
        let token = lock.withLock { revision }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.queue.async {
                    continuation.resume(returning: self.run(token: token))
                }
            }
        } onCancel: { self.cancel() }
    }
    private func run(token: Int) -> Result<String, Error> {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        // Stats' process-only CSV output: name.pid, bytes_in, bytes_out.
        process.arguments = ["-P", "-L", "1", "-n", "-k", "time,interface,state,rx_dupe,rx_ooo,re-tx,rtt_avg,rcvsize,tx_win,tc_class,tc_mgt,cc_algo,P,C,R,W,arch"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        lock.lock()
        guard revision == token else { lock.unlock(); return .failure(CancellationError()) }
        child = process
        do { try process.run() } catch {
            child = nil; lock.unlock()
            return .failure(error)
        }
        lock.unlock()
        // Drain concurrently so large process lists cannot fill the pipe and deadlock.
        let output = NetworkProcessOutput()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            defer { try? pipe.fileHandleForReading.close(); drained.signal() }
            while let data = try? pipe.fileHandleForReading.read(upToCount: 64 * 1024), !data.isEmpty {
                let remaining = max(0, 4 * 1024 * 1024 - output.data.count)
                output.data.append(data.prefix(remaining))
            }
        }
        let timedOut = finished.wait(timeout: .now() + 3) == .timedOut
        if timedOut {
            lock.lock()
            if process.isRunning { process.terminate() }
            lock.unlock()
            if finished.wait(timeout: .now() + 0.2) == .timedOut {
                // Only the child created above is targeted; never enumerate or kill other processes.
                lock.lock()
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
                lock.unlock()
                _ = finished.wait(timeout: .now() + 0.2)
            }
        }
        lock.lock(); child = nil; lock.unlock()
        guard drained.wait(timeout: .now() + 0.5) == .success,
              !timedOut, process.terminationStatus == 0,
              let text = String(data: output.data, encoding: .utf8), !text.isEmpty else { return .failure(ReadError.unavailable) }
        return .success(text)
    }
}
