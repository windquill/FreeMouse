import Darwin
import Testing
@testable import FreeMouse

struct NetworkProcessKillTests {
    private func identity(_ pid: Int32 = 1234, started: UInt64 = 100) -> NetworkProcessIdentity {
        .init(pid: pid, startSeconds: started, startMicroseconds: 10, name: "test-process")
    }

    @Test func killUsesExactPIDAndSIGKILLAfterIdentityCheck() throws {
        let target = identity()
        var received: (Int32, Int32)?
        let killer = NetworkProcessKiller(ownPID: 9999, readIdentity: { _ in target }, sendSignal: { pid, signal in
            received = (pid, signal); return 0
        })
        try killer.kill(target)
        #expect(received?.0 == 1234)
        #expect(received?.1 == SIGKILL)
    }

    @Test func reservedAndOwnPIDsNeverReceiveSignals() {
        var signals = 0
        let killer = NetworkProcessKiller(ownPID: 9999, readIdentity: { identity($0) }, sendSignal: { _, _ in signals += 1; return 0 })
        for pid: Int32 in [-1, 0, 1] {
            #expect(throws: NetworkProcessKillError.invalidTarget) { try killer.kill(identity(pid)) }
        }
        #expect(throws: NetworkProcessKillError.ownProcess) { try killer.kill(identity(9999)) }
        #expect(signals == 0)
    }

    @Test func reusedPIDIsRejectedWithoutSendingSignal() {
        var signals = 0
        let killer = NetworkProcessKiller(ownPID: 9999, readIdentity: { _ in identity(started: 200) }, sendSignal: { _, _ in signals += 1; return 0 })
        #expect(throws: NetworkProcessKillError.identityChanged) { try killer.kill(identity()) }
        #expect(signals == 0)
    }

    @Test func exitedProcessIsNotSignalled() {
        var signals = 0
        let killer = NetworkProcessKiller(ownPID: 9999, readIdentity: { _ in nil }, sendSignal: { _, _ in signals += 1; return 0 })
        #expect(throws: NetworkProcessKillError.unavailable) { try killer.kill(identity()) }
        #expect(signals == 0)
    }

    @Test func permissionErrorsAreReportedWithoutRetryOrEscalation() {
        var signals = 0
        let target = identity()
        let killer = NetworkProcessKiller(ownPID: 9999, readIdentity: { _ in target }, sendSignal: { _, _ in signals += 1; return EPERM })
        #expect(throws: NetworkProcessKillError.permissionDenied) { try killer.kill(target) }
        #expect(signals == 1)
    }

    @Test func snapshotNameMustMatchDisplayedProcessBeforeEnablingKill() {
        let target = identity()
        #expect(target.matches(displayName: "test-process"))
        #expect(!target.matches(displayName: "test-proc"))
        let truncated = NetworkProcessIdentity(pid: 1234, startSeconds: 100, startMicroseconds: 10, name: "Google Chrome Helper")
        #expect(truncated.matches(displayName: "Google Chrome H"))
        #expect(!target.matches(displayName: "different-process"))
        #expect(!target.matches(displayName: ""))
    }

    @Test func identityStartedDuringSamplingCannotBeBoundToOldTraffic() {
        let replacement = identity(started: 200)
        #expect(!replacement.canAttach(displayName: "test-process", samplingStartedAt: 199))
        #expect(replacement.canAttach(displayName: "test-process", samplingStartedAt: 201))
        #expect(!replacement.canAttach(displayName: "other-process", samplingStartedAt: 201))
    }
}
