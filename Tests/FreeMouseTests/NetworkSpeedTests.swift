import AppKit
import Darwin
import Testing
@testable import FreeMouse

struct NetworkSpeedTests {
    private func sample(_ upload: UInt64, _ download: UInt64, at time: Double, interface: String = "en0") -> NetworkCounterSample {
        .init(interface: interface, upload: upload, download: download, timestamp: time)
    }

    @Test func firstSampleDoesNotShowLifetimeTraffic() {
        var calculator = NetworkSpeedCalculator()
        #expect(calculator.update(sample(9_000_000, 80_000_000, at: 1)) == .zero)
    }

    @Test func ratesUseActualElapsedTimeAndCorrectDirections() {
        var calculator = NetworkSpeedCalculator()
        _ = calculator.update(sample(100, 200, at: 1))
        let rate = calculator.update(sample(1124, 4296, at: 3))
        #expect(rate.upload == 512)
        #expect(rate.download == 2048)
    }

    @Test func zeroCounterStillProducesTrafficOnNextSample() {
        var calculator = NetworkSpeedCalculator()
        _ = calculator.update(sample(0, 0, at: 1))
        #expect(calculator.update(sample(1024, 2048, at: 2)) == .init(upload: 1024, download: 2048))
    }

    @Test func counterResetNeverUnderflowsAndRecovers() {
        var calculator = NetworkSpeedCalculator()
        _ = calculator.update(sample(9000, 8000, at: 1))
        #expect(calculator.update(sample(10, 20, at: 2)) == .zero)
        #expect(calculator.update(sample(110, 220, at: 3)) == .init(upload: 100, download: 200))
    }

    @Test func interfaceSwitchAndDisconnectDiscardOldBaseline() {
        var calculator = NetworkSpeedCalculator()
        _ = calculator.update(sample(100, 200, at: 1))
        #expect(calculator.update(sample(9000, 9000, at: 2, interface: "en1")) == .zero)
        #expect(calculator.update(nil) == .zero)
        #expect(calculator.update(sample(18000, 18000, at: 3, interface: "en1")) == .zero)
    }

    @Test func wakeAndInvalidIntervalsDoNotShowSpikes() {
        var calculator = NetworkSpeedCalculator()
        _ = calculator.update(sample(100, 200, at: 1))
        #expect(calculator.update(sample(9000, 9000, at: 100)) == .zero)
        #expect(calculator.update(sample(9100, 9100, at: 100)) == .zero)
        #expect(calculator.update(sample(9200, 9300, at: 101)) == .init(upload: 100, download: 200))
    }

    @Test func explicitWakeResetDiscardsTrafficWhileUptimeWasSuspended() {
        var calculator = NetworkSpeedCalculator()
        _ = calculator.update(sample(100, 200, at: 1))
        calculator.reset()
        #expect(calculator.update(sample(1_000_000, 2_000_000, at: 2)) == .zero)
        #expect(calculator.update(sample(1_000_100, 2_000_200, at: 3)) == .init(upload: 100, download: 200))
    }

    @Test func impossibleCounterJumpIsDroppedPerDirection() {
        var calculator = NetworkSpeedCalculator()
        _ = calculator.update(sample(0, 0, at: 1))
        #expect(calculator.update(sample(UInt64.max, 2048, at: 2)) == .init(upload: 0, download: 2048))
    }

    @Test func physicalInterfaceSelectionAvoidsVPNDoubleCounting() {
        #expect(NetworkCounterReader.chooseInterface(primary: "en0", services: ["en1"], active: ["en0", "en1"]) == "en0")
        #expect(NetworkCounterReader.chooseInterface(primary: "utun3", services: ["utun3", "en1"], active: ["en0", "en1", "utun3"]) == "en1")
        #expect(NetworkCounterReader.chooseInterface(primary: "en9", services: [], active: ["lo0", "utun3", "en0"]) == "en0")
        #expect(NetworkCounterReader.chooseInterface(primary: nil, services: [], active: []) == nil)
    }

    @Test func truncatedRouteMessagesAreRejected() {
        #expect(NetworkCounterReader.parse([], index: 1) == nil)
        #expect(NetworkCounterReader.parse([UInt8](repeating: 0, count: 8), index: 1) == nil)
        var header = if_msghdr2()
        header.ifm_msglen = UInt16(MemoryLayout<if_msghdr2>.size)
        header.ifm_type = UInt8(RTM_IFINFO2)
        header.ifm_index = 1
        header.ifm_data.ifi_obytes = 1234
        header.ifm_data.ifi_ibytes = 5678
        let bytes = withUnsafeBytes(of: &header) { Array($0) }
        #expect(NetworkCounterReader.parse(Array(bytes.dropLast()), index: 1) == nil)
        #expect(NetworkCounterReader.parse(bytes, index: 2) == nil)
        let counters = NetworkCounterReader.parse(bytes, index: 1)
        #expect(counters?.upload == 1234)
        #expect(counters?.download == 5678)
    }

    @Test func speedUnitsStayCompactAndNeverShowInvalidValues() {
        #expect(NetworkSpeedFormatter.string(0) == "0 B/s")
        #expect(NetworkSpeedFormatter.string(1024) == "1.0 KB/s")
        #expect(NetworkSpeedFormatter.string(1_572_864) == "1.5 MB/s")
        #expect(NetworkSpeedFormatter.string(1_073_741_824) == "1.0 GB/s")
        #expect(NetworkSpeedFormatter.string(-1) == "0 B/s")
        #expect(NetworkSpeedFormatter.string(.nan) == "0 B/s")
    }

    @MainActor @Test func menuImageFitsCurrentTextAndKeepsRecordingIndicator() {
        let idle = NetworkSpeedMenuImage.make(speed: .zero, recording: false, elapsed: 0)
        let busy = NetworkSpeedMenuImage.make(speed: .init(upload: 9_876_543, download: 987_654_321), recording: false, elapsed: 0)
        #expect(idle.size.width < 70)
        #expect(busy.size.width > idle.size.width)
        #expect(idle.size.height == 22)
        #expect(idle.isTemplate)
        #expect(NetworkSpeedMenuImage.make(speed: .zero, recording: true, elapsed: 60).size.width > idle.size.width)
    }

    @MainActor @Test func trailingSpacingControlsOnlyOwnRightPadding() {
        let tight = NetworkSpeedMenuImage.make(speed: .zero, recording: false, elapsed: 0, trailingSpacing: 0)
        let wide = NetworkSpeedMenuImage.make(speed: .zero, recording: false, elapsed: 0, trailingSpacing: 12)
        #expect(wide.size.width - tight.size.width == 12)
        #expect(NetworkSpeedMenuImage.make(speed: .zero, recording: false, elapsed: 0).size.width == tight.size.width + 2)
        #expect(NetworkSpeedMenuPreferences.trailingSpacing(from: NSNumber(value: -3)) == 0)
        #expect(NetworkSpeedMenuPreferences.trailingSpacing(from: NSNumber(value: 99)) == 12)
        #expect(NetworkSpeedMenuPreferences.trailingSpacing(from: nil) == 2)
        #expect(NetworkSpeedMenuPreferences.trailingSpacing(from: NSNumber(value: Double.infinity)) == 2)
    }

    @MainActor @Test func spacingChangesOnlyTheGapAndKeepsRecordingVisible() {
        let compact = NetworkSpeedMenuImage.make(speed: .zero, recording: false, elapsed: 0, spacing: 0)
        let spaced = NetworkSpeedMenuImage.make(speed: .zero, recording: false, elapsed: 0, spacing: 20)
        #expect(spaced.size.width - compact.size.width == 20)
        #expect(NetworkSpeedMenuImage.make(speed: .zero, recording: false, elapsed: 0).size.width == compact.size.width + 2)
        let recording = NetworkSpeedMenuImage.make(speed: .zero, recording: true, elapsed: 65, spacing: 20)
        #expect(recording.size.width > spaced.size.width)
        #expect(NetworkSpeedMenuImage.make(speed: .zero, recording: false, elapsed: 0, spacing: -10).size == compact.size)
        #expect(NetworkSpeedMenuImage.make(speed: .zero, recording: false, elapsed: 0, spacing: 100).size == spaced.size)
    }

    @Test func invalidSavedSpacingFallsBackToDefaultAndClampsToSliderRange() {
        #expect(NetworkSpeedMenuPreferences.spacing(from: nil) == 2)
        #expect(NetworkSpeedMenuPreferences.spacing(from: "invalid") == 2)
        #expect(NetworkSpeedMenuPreferences.spacing(from: NSNumber(value: Double.nan)) == 2)
        #expect(NetworkSpeedMenuPreferences.spacing(from: NSNumber(value: -5)) == 0)
        #expect(NetworkSpeedMenuPreferences.spacing(from: NSNumber(value: 99)) == 20)
        #expect(NetworkSpeedMenuPreferences.spacing(from: NSNumber(value: 6)) == 6)
    }

    @Test func iconAndSpeedHitTargetsRespectSystemPaddingAndConfiguredGap() {
        #expect(NetworkSpeedMenuHitTarget.target(x: 5, buttonWidth: 104, imageWidth: 92, spacing: 2) == .toolbox)
        #expect(NetworkSpeedMenuHitTarget.target(x: 35, buttonWidth: 104, imageWidth: 92, spacing: 2) == .network)
        #expect(NetworkSpeedMenuHitTarget.target(x: 26, buttonWidth: 122, imageWidth: 110, spacing: 20) == .toolbox)
        #expect(NetworkSpeedMenuHitTarget.target(x: 50, buttonWidth: 122, imageWidth: 110, spacing: 20) == .network)
    }
}
