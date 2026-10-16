import CoreGraphics
import Testing
@testable import FreeMouse

struct ScrollWindowExclusionTests {
    @Test func statusBarWindowSentinelCannotCrashCaptureStartup() {
        // NSStatusBarWindow returned this positive, non-CGWindowID value in
        // the user's macOS crash report. A valid screen inventory must skip it.
        let ids = ScrollWindowExclusion.knownWindowIDs(from: [7, 4_294_967_296, 42])
        #expect(ids == [7, 42])
    }

    @Test func otherInvalidAndUnrealizedWindowNumbersAreIgnored() {
        let ids = ScrollWindowExclusion.knownWindowIDs(from: [Int.min, -1, 0, Int.max])
        #expect(ids.isEmpty)
    }

    @Test func representableWindowIDsAreRetainedAndDeduplicated() {
        let ids = ScrollWindowExclusion.knownWindowIDs(from: [1, 42, 42, Int(UInt32.max)])
        #expect(ids == [1, 42, UInt32.max])
    }

    @Test func knownOwnOverlayExcludedWhenRunningApplicationIsMissing() {
        let windows = [
            ScrollWindowIdentity(windowID: 71, ownerPID: nil, ownerBundleID: nil),
            ScrollWindowIdentity(windowID: 72, ownerPID: 99, ownerBundleID: "target.app")
        ]
        #expect(ScrollWindowExclusion.ids(in: windows, ownPID: 10,
            ownBundleID: "local.freemouse.toolbox", knownOwnWindowIDs: [71]) == [71])
    }

    @Test func oldInstanceOverlaysExcludedWithoutExcludingTargetApplication() {
        let windows = [
            ScrollWindowIdentity(windowID: 81, ownerPID: 10, ownerBundleID: nil),
            ScrollWindowIdentity(windowID: 82, ownerPID: 11, ownerBundleID: "local.freemouse.toolbox"),
            ScrollWindowIdentity(windowID: 83, ownerPID: 12, ownerBundleID: "target.app")
        ]
        #expect(ScrollWindowExclusion.ids(in: windows, ownPID: 10,
            ownBundleID: "local.freemouse.toolbox", knownOwnWindowIDs: []) == [81, 82])
    }

    @Test func missingOwnBundleNeverMatchesAnonymousTargetWindows() {
        let windows = [
            ScrollWindowIdentity(windowID: 91, ownerPID: 10, ownerBundleID: nil),
            ScrollWindowIdentity(windowID: 92, ownerPID: 12, ownerBundleID: nil)
        ]
        #expect(ScrollWindowExclusion.ids(in: windows, ownPID: 10,
            ownBundleID: nil, knownOwnWindowIDs: []) == [91])
    }
}
