import Testing
import Foundation
@testable import FreeMouse

struct ScrollFlowTests {
    @Test func shortViewportsKeepTwentyPixelsOfOverlapAndNeverOverrunBudget() {
        #expect(ScrollMotionBudget.step(viewportHeight: 24, scale: 1, pending: 0, rate: 400, elapsed: 0.02) == 4)
        #expect(ScrollMotionBudget.step(viewportHeight: 24, scale: 1, pending: 4, rate: 400, elapsed: 0.02) == 0)
        #expect(ScrollMotionBudget.step(viewportHeight: 900, scale: 2, pending: 178, rate: 400, elapsed: 0.02) == 2)
        #expect(ScrollMotionBudget.step(viewportHeight: 12, scale: 2, pending: 0, rate: 400, elapsed: 0.02) == 2)
    }

    @Test func stationaryManualCaptureNeverAutoPauses() {
        var flow = ScrollCaptureFlow(); flow.started(at: 0); flow.accepted(at: 0)
        #expect((flow.unchanged(at: 30)) == false)
        #expect(flow.phase == .running)
    }
    @Test func autoNoProgressFallsBackToManualWithoutDiscarding() {
        var flow = ScrollCaptureFlow(); flow.started(at: 0); flow.accepted(at: 0)
        flow.setAutomatic(true, at: 10)
        #expect((flow.unchanged(at: 10.2)) == false)
        #expect((flow.unchanged(at: 11.6)) == true)
        #expect(flow.mode == .manual)
        #expect(flow.phase == .running)
        #expect(flow.hasImage)
    }
    @Test func transientFailuresRecoverButRepeatedAutoFailureStopsMotion() {
        var flow = ScrollCaptureFlow(); flow.started(at: 0); flow.setAutomatic(true, at: 0)
        for n in 1...4 { let stopped = flow.rejected(at: Double(n)/10); #expect(!stopped) }
        flow.accepted(at: 1)
        let initialStop = flow.rejected(at: 1.1); #expect(!initialStop)
        for n in 2...4 { let stopped = flow.rejected(at: 1 + Double(n)/10); #expect(!stopped) }
        let stopped = flow.rejected(at: 1.5); #expect(stopped)
        #expect(flow.mode == .manual)
        #expect(flow.hasImage)
    }
    @Test func finishRetainsInflightAcceptedFrameAndStopsMotion() {
        var flow = ScrollCaptureFlow(); flow.started(at: 0); flow.setAutomatic(true, at: 0)
        let startedFinish = flow.requestFinish(.copy); #expect(startedFinish)
        flow.accepted(at: 0.2)
        #expect(flow.phase == .finishing)
        #expect(flow.hasImage)
        #expect(!flow.shouldScroll)
        let repeated = flow.requestFinish(.save); #expect(!repeated)
        flow.end(); flow.accepted(at: 1)
        #expect(flow.phase == .ended)
    }
    @Test func pauseResumeRestartsNoProgressTimer() {
        var flow = ScrollCaptureFlow(); flow.started(at: 0); flow.accepted(at: 0); flow.setAutomatic(true, at: 0)
        flow.togglePause(at: 1)
        #expect(flow.phase == .paused)
        #expect(!flow.shouldScroll)
        flow.togglePause(at: 20)
        #expect(flow.shouldScroll)
        let stopped = flow.unchanged(at: 20.2); #expect(!stopped)
    }
    @Test func toolbarPlacementAndScrollPointStayOnNegativeDisplay() throws {
        let screen = CGRect(x: -1440, y: 200, width: 1440, height: 900)
        let selection = CGRect(x: -1400, y: 250, width: 1320, height: 800)
        let layout = ScrollOverlayLayout.make(selection: selection, visibleScreen: screen)
        #expect(screen.contains(layout.toolbar))
        #expect(screen.contains(layout.preview))
        let point = try #require(ScrollOverlayLayout.exposedPoint(in: selection, avoiding: [layout.toolbar]))
        #expect(selection.contains(point))
        #expect(!layout.toolbar.contains(point))
    }
}
