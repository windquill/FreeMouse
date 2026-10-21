// Network process reading adapted from Stats (MIT), Copyright Serhiy Mytrovtsiy.
// License and pinned upstream: ThirdParty/Stats.
import AppKit
import Combine
import CoreLocation
import CoreWLAN
import Darwin
import SystemConfiguration

struct NetworkInterfaceDetails {
    var name: String
    var displayName: String
    var isUp: Bool
    var hardwareAddress: String?
    var localIPv4: String?
    var localIPv6: String?
    var ssid: String?
}

struct NetworkProcessTraffic: Identifiable {
    var id: Int32
    var name: String
    var upload: Double
    var download: Double
}

struct NetworkProcessCalculator {
    private var previous: [Int32: (name: String, upload: UInt64, download: UInt64)] = [:]
    private var timestamp: Double?
    mutating func update(_ output: String, timestamp now: Double) -> [NetworkProcessTraffic] {
        var current: [Int32: (name: String, upload: UInt64, download: UInt64)] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 3, let separator = fields[0].lastIndex(of: "."),
                  let pid = Int32(fields[0][fields[0].index(after: separator)...]), pid > 0,
                  let download = UInt64(fields[1]), let upload = UInt64(fields[2]) else { continue }
            // -P emits process totals. Ignore any duplicate total rows rather than double count.
            current[pid] = (String(fields[0][..<separator]), upload, download)
        }
        defer { previous = current; timestamp = now }
        guard let timestamp, now > timestamp, now - timestamp <= 10 else { return [] }
        let elapsed = now - timestamp
        return current.compactMap { pid, value -> NetworkProcessTraffic? in
            guard let old = previous[pid], old.name == value.name else { return nil }
            return .init(id: pid, name: value.name,
                         upload: value.upload >= old.upload ? Double(value.upload - old.upload) / elapsed : 0,
                         download: value.download >= old.download ? Double(value.download - old.download) / elapsed : 0)
        }.sorted {
            if $0.upload + $0.download == $1.upload + $1.download { return $0.id < $1.id }
            return $0.upload + $0.download > $1.upload + $1.download
        }.prefix(8).map { $0 }
    }
}

@MainActor final class NetworkMonitor: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var speed: NetworkSpeed = .zero
    @Published private(set) var history: [NetworkSpeed] = []
    @Published private(set) var connectionHistory: [Bool?] = []
    @Published private(set) var interface: NetworkInterfaceDetails?
    @Published private(set) var processes: [NetworkProcessTraffic] = []
    @Published private(set) var totalUpload: Double = 0
    @Published private(set) var totalDownload: Double = 0
    @Published private(set) var reachable: Bool?
    @Published private(set) var latency: Double?
    @Published private(set) var jitter: Double?
    @Published private(set) var publicIP: String?
    @Published private(set) var country: String?
    @Published private(set) var processStatus: String?
    private let defaults: UserDefaults
    private let snapshot: () -> NetworkCounterSample?
    private var calculator = NetworkSpeedCalculator()
    private var lastSample: NetworkCounterSample?
    private var detailsTask: Task<Void, Never>?
    private var publicTask: Task<Void, Never>?
    private var connectivityTask: Task<Void, Never>?
    private var processCalculator = NetworkProcessCalculator()
    private let processRunner = NetworkProcessRunner()
    private var locationManager: CLLocationManager?
    private var previousLatency: Double?
    private var generation = UUID()

    init(defaults: UserDefaults = .standard, snapshot: @escaping () -> NetworkCounterSample? = NetworkCounterReader.snapshot) {
        self.defaults = defaults
        self.snapshot = snapshot
        totalUpload = max(0, defaults.double(forKey: "network.totalUpload"))
        totalDownload = max(0, defaults.double(forKey: "network.totalDownload"))
        super.init()
    }
    func sample() {
        let current = snapshot()
        speed = calculator.update(current)
        if let current, let old = lastSample, current.interface == old.interface {
            let elapsed = current.timestamp - old.timestamp
            if elapsed > 0, elapsed <= 5 {
                totalUpload += speed.upload * elapsed
                totalDownload += speed.download * elapsed
                persistTotals()
            }
        }
        lastSample = current
        history.append(speed)
        connectionHistory.append(reachable)
        if history.count > 180 { history.removeFirst(history.count - 180) }
        if connectionHistory.count > 90 { connectionHistory.removeFirst(connectionHistory.count - 90) }
    }
    func resetBaseline() {
        // Cancel work started before sleep, including process counters and HTTP timing.
        let restartDetails = detailsTask != nil
        stopDetails()
        calculator.reset(); lastSample = nil; speed = .zero
        processes = []
        if restartDetails { startDetails() }
    }
    func resetTotals() { totalUpload = 0; totalDownload = 0; persistTotals(); resetBaseline() }
    private func persistTotals() {
        defaults.set(totalUpload, forKey: "network.totalUpload")
        defaults.set(totalDownload, forKey: "network.totalDownload")
    }
    func startDetails() {
        guard detailsTask == nil else { return }
        generation = UUID()
        let token = generation
        connectivityTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkHTTPS(token: token)
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
        detailsTask = Task { [weak self] in
            var iteration = 0
            while !Task.isCancelled {
                guard let self else { return }
                self.interface = NetworkDetailsReader.read(name: self.lastSample?.interface)
                if iteration % 10 == 0 { self.refreshPublicIP() }
                let result = await self.processRunner.read()
                guard !Task.isCancelled, self.generation == token else { return }
                switch result {
                case .success(let output):
                    self.processes = self.processCalculator.update(output, timestamp: ProcessInfo.processInfo.systemUptime)
                    self.processStatus = nil
                case .failure:
                    self.processes = []
                    self.processStatus = "无法读取进程流量（权限不足或读取超时）"
                    self.processCalculator = NetworkProcessCalculator()
                }
                iteration += 1
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }
    func stopDetails() {
        generation = UUID()
        detailsTask?.cancel(); detailsTask = nil
        publicTask?.cancel(); publicTask = nil
        connectivityTask?.cancel(); connectivityTask = nil
        processRunner.cancel()
        processCalculator = NetworkProcessCalculator()
        previousLatency = nil
        reachable = nil; latency = nil; jitter = nil
    }
    func refreshPublicIP() {
        publicTask?.cancel()
        let token = generation
        publicTask = Task { [weak self] in
            do {
                let request = URLRequest(url: URL(string: "https://api.mac-stats.com/ip")!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
                let (data, response) = try await URLSession.shared.data(for: request)
                guard !Task.isCancelled, let self, self.generation == token else { return }
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    self.publicIP = nil; self.country = nil; return
                }
                self.publicIP = (json["ipv4"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? (json["ipv6"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                self.country = json["country"] as? String
            } catch {
                guard !Task.isCancelled, let self, self.generation == token else { return }
                self.publicIP = nil; self.country = nil
            }
        }
    }
    private func checkHTTPS(token: UUID) async {
        var request = URLRequest(url: URL(string: "https://www.apple.com/library/test/success.html")!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        request.httpMethod = "HEAD"
        let start = ProcessInfo.processInfo.systemUptime
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard !Task.isCancelled, generation == token else { return }
            guard let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) else { throw URLError(.badServerResponse) }
            let value = (ProcessInfo.processInfo.systemUptime - start) * 1000
            reachable = true; latency = value
            if let previousLatency { let difference = abs(value - previousLatency); jitter = jitter.map { $0 + (difference - $0) / 16 } ?? difference }
            previousLatency = value
        } catch {
            guard !Task.isCancelled, generation == token else { return }
            reachable = false; latency = nil; jitter = nil; previousLatency = nil
        }
    }
    func requestWiFiDetails() {
        if locationManager == nil { locationManager = CLLocationManager(); locationManager?.delegate = self }
        if locationManager?.authorizationStatus == .notDetermined { locationManager?.requestWhenInUseAuthorization() }
        else if locationManager?.authorizationStatus == .denied || locationManager?.authorizationStatus == .restricted,
                let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
            NSWorkspace.shared.open(url)
        }
        interface = NetworkDetailsReader.read(name: lastSample?.interface)
    }
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.interface = NetworkDetailsReader.read(name: self.lastSample?.interface)
        }
    }
}
