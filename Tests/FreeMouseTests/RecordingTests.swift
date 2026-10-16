import Foundation
import Testing
@testable import FreeMouse

struct RecordingTests {
    // Losing the preparing lock permits two native streams to be started.
    @Test func testPreparingOwnsSessionAndRejectsSecondStart() throws {
        var state = RecordingLifecycle()
        let session = try state.begin()
        #expect(state.isBusy)
        #expect(!state.isRecording)
        #expect(state.token == session)
        #expect(throws: (any Error).self) { try state.begin() }
    }

    // Marking stop as idle allows a new file before the previous one is finalized.
    @Test func testStoppingKeepsSessionBusyUntilFinalized() throws {
        var state = RecordingLifecycle()
        let session = try state.begin()
        #expect({ state.started(session) }() == true)
        #expect(state.isRecording)
        #expect({ state.beginFinishing(session) }() == true)
        #expect(!state.isRecording)
        #expect(state.isBusy)
        #expect(throws: (any Error).self) { try state.begin() }
        #expect({ state.beginFinishing(session) }() == false)
        #expect({ state.finish(session) }() == true)
        #expect(!state.isBusy)
        #expect({ state.finish(session) }() == false)
    }

    // An old callback must not release ownership of the next recording.
    @Test func testStaleCompletionCannotFinishNextSession() throws {
        var state = RecordingLifecycle()
        let old = try state.begin()
        #expect({ state.fail(old) }() == true)
        let current = try state.begin()
        #expect({ state.started(old) }() == false)
        #expect({ state.finish(old) }() == false)
        #expect({ state.fail(old) }() == false)
        #expect(state.token == current)
        #expect(state.isBusy)
    }

    // Failing during setup or finalization must permit another user attempt.
    @Test func testFailureReleasesEveryActivePhase() throws {
        for phase in [0, 1, 2] {
            var state = RecordingLifecycle()
            let session = try state.begin()
            if phase > 0 { #expect({ state.started(session) }() == true) }
            if phase > 1 { #expect({ state.beginFinishing(session) }() == true) }
            #expect({ state.fail(session) }() == true)
            #expect(!state.isBusy)
            #expect(state.token == nil)
            #expect({ state.fail(session) }() == false)
            _ = try state.begin()
        }
    }
}
