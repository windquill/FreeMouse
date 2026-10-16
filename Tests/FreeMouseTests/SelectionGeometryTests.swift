import CoreGraphics
import Testing
@testable import FreeMouse
struct SelectionGeometryTests {
    let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
    let rect = CGRect(x: 100, y: 100, width: 200, height: 150)
    @Test func movementKeepsSizeAndClampsToDisplay() {
        #expect(SelectionGeometry.moved(rect, delta: CGSize(width: 900, height: -900), bounds: bounds) == CGRect(x: 600, y: 0, width: 200, height: 150))
    }
    @Test func allEightHandlesAreHittable() {
        for h in SelectionHandle.allCases { #expect(SelectionGeometry.handle(at: h.point(in: rect), rect: rect) == h) }
        #expect(SelectionGeometry.handle(at: CGPoint(x: 200, y: 175), rect: rect) == nil)
    }
    @Test func edgesResizeOneAxis() {
        #expect(SelectionGeometry.resized(rect, handle: .right, point: CGPoint(x: 450, y: 500), bounds: bounds) == CGRect(x: 100, y: 100, width: 350, height: 150))
    }
    @Test func cornerCannotInvertOrLeaveDisplay() {
        #expect(SelectionGeometry.resized(rect, handle: .bottomLeft, point: CGPoint(x: -20, y: -30), bounds: bounds) == CGRect(x: 0, y: 0, width: 300, height: 250))
        let r = SelectionGeometry.resized(rect, handle: .topRight, point: .zero, bounds: bounds)
        #expect(r.width == 4 && r.height == 4)
    }
}
