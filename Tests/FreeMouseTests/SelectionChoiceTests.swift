import CoreGraphics
import Testing
@testable import FreeMouse

struct SelectionChoiceTests {
    @Test func toolbarUsesSpaceBelowSelection() {
        let area = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let selection = CGRect(x: 200, y: 200, width: 800, height: 500)
        let toolbar = SelectionToolbarPlacement.frame(selection: selection, visibleBounds: area, size: CGSize(width: 444, height: 54))
        #expect(area.contains(toolbar))
        #expect(toolbar.maxY < selection.minY)
    }

    @Test func toolbarMovesAboveBottomEdgeSelection() {
        let area = CGRect(x: 0, y: 30, width: 1440, height: 850)
        let selection = CGRect(x: 5, y: 4, width: 500, height: 400)
        let toolbar = SelectionToolbarPlacement.frame(selection: selection, visibleBounds: area, size: CGSize(width: 444, height: 54))
        #expect(area.contains(toolbar))
        #expect(toolbar.minY > selection.maxY)
    }

    @Test func toolbarStaysVisibleForFullDisplayAndRightEdgeSelection() {
        let area = CGRect(x: 0, y: 28, width: 1440, height: 844)
        for selection in [CGRect(x: 0, y: 0, width: 1440, height: 900), CGRect(x: 1420, y: 500, width: 20, height: 20)] {
            let toolbar = SelectionToolbarPlacement.frame(selection: selection, visibleBounds: area, size: CGSize(width: 444, height: 54))
            #expect(area.contains(toolbar))
            #expect(toolbar.width == 444)
            #expect(toolbar.height == 54)
        }
    }
}
