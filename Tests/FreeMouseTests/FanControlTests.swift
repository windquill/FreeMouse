import Testing
@testable import FreeMouse

struct FanControlTests {
    @Test func testRejectsUnsafeOrMissingHardwareMaximum() {
        #expect(FanSafety.maximumRPM(minimum: 1000, maximum: .nan) == nil)
        #expect(FanSafety.maximumRPM(minimum: 1000, maximum: 0) == nil)
        #expect(FanSafety.maximumRPM(minimum: 5000, maximum: 4000) == nil)
        #expect(FanSafety.maximumRPM(minimum: 1200, maximum: 6200) == 6200)
    }
    @Test func testShellArgumentCannotInjectThroughPath() {
        #expect(FanSafety.shellQuote("a'b $(touch bad)") == "'a'\\''b $(touch bad)'")
    }
    @Test func testMaximumRequiresEveryFanToVerify() {
        #expect(!FanSafety.verifiedMaximum([]))
        #expect(!FanSafety.verifiedMaximum([FanReading(id: 0, actual: 1200, minimum: 1000, maximum: 6000, target: 3000, mode: 1)]))
        #expect(FanSafety.verifiedMaximum([FanReading(id: 0, actual: 1200, minimum: 1000, maximum: 6000, target: 6000, mode: 1)]))
    }
}
