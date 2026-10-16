import Testing
@testable import FreeMouse

struct ScrollCaptureTimingTests {
    @Test func queuedFrameCannotAcknowledgeMotionPostedAfterItWasCaptured() {
        var pacer = ScrollAutomaticPacer()
        pacer.posted(at: 10)
        pacer.matched(frameTime: 9.9, at: 10.1, advanced: true)
        #expect(pacer.nextStep(at: 11, viewportHeight: 500, scale: 2, speed: 1) == 0)
        pacer.matched(frameTime: 10.1, at: 11.1, advanced: true)
        #expect(pacer.nextStep(at: 11.2, viewportHeight: 500, scale: 2, speed: 1) == 0)
        #expect(pacer.nextStep(at: 11.3, viewportHeight: 500, scale: 2, speed: 1) > 0)
    }

    @Test func freshDuplicateDoesNotConfirmDocumentMotion() {
        var pacer = ScrollAutomaticPacer()
        pacer.posted(at: 1)
        pacer.matched(frameTime: 1.1, at: 1.2, advanced: false)
        #expect(pacer.nextStep(at: 3, viewportHeight: 500, scale: 1, speed: 2) == 0)
    }

    @Test func anotherAnimationFrameExtendsTheSettlingPeriod() {
        var pacer = ScrollAutomaticPacer()
        pacer.posted(at: 1)
        pacer.matched(frameTime: 1.01, at: 1.02, advanced: true)
        #expect(pacer.nextStep(at: 1.1, viewportHeight: 500, scale: 1, speed: 0) == 0)
        pacer.matched(frameTime: 1.13, at: 1.14, advanced: true)
        #expect(pacer.nextStep(at: 1.2, viewportHeight: 500, scale: 1, speed: 0) == 0)
        #expect(pacer.nextStep(at: 1.3, viewportHeight: 500, scale: 1, speed: 0) > 0)
    }

    @Test func everyStepReservesPhysicalOverlapAndHasABoundedSpeed() {
        let pacer = ScrollAutomaticPacer()
        #expect(pacer.nextStep(at: 0, viewportHeight: 24, scale: 1, speed: 2) == 4)
        #expect(pacer.nextStep(at: 0, viewportHeight: 12, scale: 2, speed: 2) == 2)
        #expect(pacer.nextStep(at: 0, viewportHeight: 500, scale: 1, speed: 0) == 40)
        #expect(pacer.nextStep(at: 0, viewportHeight: 500, scale: 1, speed: 1) == 70)
        #expect(pacer.nextStep(at: 0, viewportHeight: 500, scale: 1, speed: 2) == 100)
        #expect(pacer.nextStep(at: 0, viewportHeight: 10, scale: 1, speed: 2) == 0)
    }

    @Test func resetAllowsANewSessionWithoutOldMotion() {
        var pacer = ScrollAutomaticPacer()
        pacer.posted(at: 2)
        pacer.reset()
        #expect(pacer.nextStep(at: 2.1, viewportHeight: 500, scale: 1, speed: 1) > 0)
        pacer.posted(at: 3)
        #expect(pacer.nextStep(at: 30, viewportHeight: 500, scale: 1, speed: 1) == 0)
    }

    @Test func finishingWaitsForMotionBeyondTheOld180MillisecondCutoff() {
        var tail = ScrollFinishSettler(startedAt: 10)
        #expect(tail.decision(at: 10.18, hasPending: false) == .waiting)
        tail.observed(at: 10.24, changed: true)
        #expect(tail.decision(at: 10.4, hasPending: false) == .waiting)
        #expect(tail.decision(at: 10.5, hasPending: false) == .settled)
    }

    @Test func unchangedSCKScreenCanFinishWithoutAnotherCompleteSample() {
        let tail = ScrollFinishSettler(startedAt: 10)
        #expect(tail.decision(at: 10.31, hasPending: false) == .settled)
        #expect(tail.decision(at: 10.5, hasPending: true) == .waiting)
    }

    @Test func duplicatesDoNotProlongFinishButUnmatchedFramesDo() {
        var tail = ScrollFinishSettler(startedAt: 0)
        tail.observed(at: 0.29, changed: false)
        #expect(tail.decision(at: 0.31, hasPending: false) == .settled)
        tail.observed(at: 0.4, changed: true)
        #expect(tail.decision(at: 0.5, hasPending: false) == .waiting)
        tail.observed(at: 1.9, changed: true)
        #expect(tail.decision(at: 2.01, hasPending: true) == .timedOut)
    }
}
