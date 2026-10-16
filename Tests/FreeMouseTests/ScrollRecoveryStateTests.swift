import Testing
@testable import FreeMouse

struct ScrollRecoveryStateTests {
    @Test func aVerifiedReturnToCapturedContentClearsTheIncompleteWarning() {
        var flow = ScrollCaptureFlow()
        flow.started(at: 0); flow.accepted(at: 0)
        _ = flow.rejected(at: 1)
        #expect(flow.hasUnmatchedFrame)
        flow.matchedWithoutAdvance()
        #expect(!flow.hasUnmatchedFrame)
        #expect(flow.hasImage)
        #expect(flow.phase == .running)
    }

    @Test func recoveryDoesNotResumeAUserPause() {
        var flow = ScrollCaptureFlow()
        flow.started(at: 0); flow.accepted(at: 0)
        flow.togglePause(at: 1)
        _ = flow.rejected(at: 1.1)
        #expect(flow.hasUnmatchedFrame)
        flow.matchedWithoutAdvance()
        #expect(!flow.hasUnmatchedFrame)
        #expect(flow.phase == .paused)
        #expect(!flow.shouldScroll)
    }

    @Test func aDuplicateDoesNotPretendThatTheDocumentAdvanced() {
        var flow = ScrollCaptureFlow()
        flow.started(at: 0); flow.accepted(at: 0); flow.setAutomatic(true, at: 0)
        _ = flow.rejected(at: 0.4)
        flow.matchedWithoutAdvance()
        let expired = flow.unchanged(at: 1.5)
        #expect(expired)
        #expect(flow.mode == .manual)
        #expect(!flow.hasUnmatchedFrame)
    }

    @Test func aVerifiedTailDuringFinishClearsOnlyTheMatchWarning() {
        var flow = ScrollCaptureFlow()
        flow.started(at: 0); flow.accepted(at: 0)
        _ = flow.requestFinish(.save)
        _ = flow.rejected(at: 0.1)
        #expect(flow.hasUnmatchedFrame)
        flow.matchedWithoutAdvance()
        #expect(!flow.hasUnmatchedFrame)
        #expect(flow.phase == .finishing)
        #expect(!flow.shouldScroll)
    }
}
