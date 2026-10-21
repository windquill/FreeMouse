import Foundation
import Testing
@testable import FreeMouse

@Suite("Application runtime target safety")
@MainActor
struct ApplicationRuntimeTests {
    @Test func protectsOwnAndSystemProcesses() {
        #expect(ApplicationRuntime.isProtected(pid: 42, bundleIdentifier: "local.example.app", ownPID: 42))
        #expect(ApplicationRuntime.isProtected(pid: 1, bundleIdentifier: nil, ownPID: 42))
        for identifier in ["com.apple.finder", "com.apple.dock", "com.apple.loginwindow", "com.apple.SystemUIServer", "com.apple.WindowServer"] {
            #expect(ApplicationRuntime.isProtected(pid: 100, bundleIdentifier: identifier, ownPID: 42))
        }
        #expect(!ApplicationRuntime.isProtected(pid: 100, bundleIdentifier: "local.example.app", ownPID: 42))
    }

    @Test func rejectsNonApplicationLaunchTargets() {
        for path in ["relative.app", "https://example.com/Test.app", "/bin/sh", "/missing/Application.app"] {
            #expect(throws: (any Error).self) { _ = try ApplicationRuntime.validatedApplicationURL(path) }
        }
    }

    @Test func canonicalPathNormalizesDotSegments() {
        #expect(ApplicationRuntime.canonicalPath("/Applications/../Applications/Example.app/") == "/Applications/Example.app")
    }

    @Test func processIdentityIncludesStartTime() {
        let original = NetworkProcessIdentity(pid: 123, startSeconds: 10, startMicroseconds: 5, name: "Fixture")
        let reused = NetworkProcessIdentity(pid: 123, startSeconds: 20, startMicroseconds: 5, name: "Fixture")
        #expect(original != reused)
    }

    @Test func restartingAbsentProcessCannotLaunch() async {
        let runtime = ApplicationRuntime()
        do {
            try await runtime.perform(.restart, path: "/missing/RuntimeFixture.app")
            Issue.record("Restart unexpectedly accepted an invalid application")
        } catch { }
        #expect(runtime.busyPaths.isEmpty)
    }
    @Test func forceConfirmationRejectsReplacementAndAdditionalInstances() throws {
        let path = "/Applications/RuntimeFixture.app"
        func process(_ pid: Int32, started: UInt64 = 10) -> ManagedApplicationProcess {
            .init(pid: pid, bundlePath: path, bundleIdentifier: "local.runtime.fixture", name: "Fixture",
                  launchDate: Date(timeIntervalSince1970: Double(started)),
                  identity: .init(pid: pid, startSeconds: started, startMicroseconds: 0, name: "Fixture"))
        }
        let confirmed = process(123)
        #expect(try ApplicationRuntime.validatedConfirmedTargets(current: [confirmed], expected: [confirmed], path: path) == [confirmed])
        for current in [[process(124)], [process(123, started: 20)], [confirmed, process(124)], []] {
            #expect(throws: (any Error).self) {
                _ = try ApplicationRuntime.validatedConfirmedTargets(current: current, expected: [confirmed], path: path)
            }
        }
        #expect(throws: (any Error).self) {
            _ = try ApplicationRuntime.validatedConfirmedTargets(current: [confirmed, confirmed], expected: [confirmed, confirmed], path: path)
        }
        #expect(throws: (any Error).self) {
            _ = try ApplicationRuntime.validatedConfirmedTargets(current: [confirmed], expected: [confirmed], path: "/Applications/Other.app")
        }
    }

}
