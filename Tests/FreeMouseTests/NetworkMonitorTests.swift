import Foundation
import Testing
@testable import FreeMouse

private final class MemoryNetworkDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    override func double(forKey key: String) -> Double { values[key] as? Double ?? 0 }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
}

struct NetworkMonitorTests {
    @Test func processCountersAreDifferencedAndFirstSampleIsBaseline() {
        var calculator = NetworkProcessCalculator()
        #expect(calculator.update("time,bytes_in,bytes_out\nSafari.42,100,200\n", timestamp: 1).isEmpty)
        let result = calculator.update("time,bytes_in,bytes_out\nSafari.42,300,260\n", timestamp: 3)
        #expect(result.count == 1)
        #expect(result.first?.download == 100)
        #expect(result.first?.upload == 30)
    }
    @Test func resetCountersAndNewProcessesDoNotProduceSpikes() {
        var calculator = NetworkProcessCalculator()
        _ = calculator.update("name,bytes_in,bytes_out\na.1,900,800\n", timestamp: 1)
        let result = calculator.update("name,bytes_in,bytes_out\na.1,1,2\nb.2,99999,99999\n", timestamp: 4)
        #expect(result.first?.download == 0)
        #expect(result.first?.upload == 0)
        #expect(!result.contains { $0.id == 2 })
    }
    @MainActor @Test func historyIsBoundedAndTotalsUseElapsedTime() {
        let defaults = MemoryNetworkDefaults()
        var timestamp = 0.0
        let monitor = NetworkMonitor(defaults: defaults, snapshot: {
            timestamp += 1
            return .init(interface: "en0", upload: UInt64(timestamp * 10), download: UInt64(timestamp * 20), timestamp: timestamp)
        })
        for _ in 0..<190 { monitor.sample() }
        #expect(monitor.history.count == 180)
        #expect(monitor.connectionHistory.count == 90)
        #expect(monitor.totalUpload == 1890)
        monitor.resetTotals()
        #expect(monitor.totalDownload == 0)
    }

    @Test func processRankingIsBoundedAndIgnoresMalformedRows() {
        var calculator = NetworkProcessCalculator()
        let baseline = (1...12).map { "app.\($0),100,100" }.joined(separator: "\n")
        _ = calculator.update(baseline, timestamp: 1)
        let current = (1...12).map { "app.\($0),\(100 + $0 * 10),100" }.joined(separator: "\n")
        let ranked = calculator.update("bad,row\n" + current, timestamp: 2)
        #expect(ranked.count == 8)
        #expect(ranked.first?.id == 12)
        #expect(ranked.last?.id == 5)
    }

    @MainActor @Test func wakeRebaselinesWithoutErasingPersistedTotals() {
        let defaults = MemoryNetworkDefaults()
        var count: UInt64 = 0
        let monitor = NetworkMonitor(defaults: defaults, snapshot: {
            count += 1
            return .init(interface: "en0", upload: count * 100, download: count * 200, timestamp: Double(count))
        })
        monitor.sample(); monitor.sample()
        #expect(monitor.totalUpload == 100)
        monitor.resetBaseline()
        #expect(monitor.speed == .zero)
        monitor.sample()
        #expect(monitor.totalUpload == 100)
        let reopened = NetworkMonitor(defaults: defaults, snapshot: { nil })
        #expect(reopened.totalUpload == 100)
        #expect(reopened.totalDownload == 200)
    }
}
