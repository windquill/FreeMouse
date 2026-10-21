import Foundation
import Testing
@testable import FreeMouse

struct ApplicationManagerFilteringTests {
    @Test func liveRunningSnapshotChangesRunningAndStoppedResults() {
        let apps = [StartupApplication(path: "/Applications/A.app", name: "A", loginEnabled: true),
                    StartupApplication(path: "/Applications/B.app", name: "B", loginEnabled: nil)]
        let running: Set<String> = [apps[0].path]
        #expect(ApplicationManagerFiltering.filtered(apps, filter: .running, search: "", runningPaths: running).map(\.name) == ["A"])
        #expect(ApplicationManagerFiltering.filtered(apps, filter: .stopped, search: "B", runningPaths: running).map(\.name) == ["B"])
        #expect(ApplicationManagerFiltering.filtered(apps, filter: .loginEnabled, search: "", runningPaths: running).map(\.name) == ["A"])
        #expect(ApplicationManagerFiltering.filtered(apps, filter: .running, search: "", runningPaths: []).isEmpty)
    }

    @Test func batchTargetsExcludeHiddenSelectionAndWrongRuntimeState() {
        let visible = [StartupApplication(path: "/A.app", name: "A", loginEnabled: false),
                       StartupApplication(path: "/B.app", name: "B", loginEnabled: false)]
        let selected: Set<String> = ["/A.app", "/B.app", "/Hidden.app"]
        #expect(ApplicationManagerFiltering.batchPaths(.launch, visible: visible, selected: selected, runningPaths: ["/A.app"]) == ["/B.app"])
        #expect(ApplicationManagerFiltering.batchPaths(.quit, visible: visible, selected: selected, runningPaths: ["/A.app", "/Hidden.app"]) == ["/A.app"])
    }
}
