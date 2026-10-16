import CoreGraphics
import Testing
@testable import FreeMouse

struct CameraOverlayLayoutTests {
    @Test(arguments: [CGFloat(1), CGFloat(2)])
    func displayLocalRegionUsesGlobalAppKitPointsWithoutRetinaScaling(scale: CGFloat) {
        let screen = CGRect(x: -1920, y: -300, width: 1920, height: 1080)
        let region = CaptureRegion(displayID: 7,
            rect: CGRect(x: 120, y: 80, width: 800, height: 600), scale: scale)

        #expect(CameraOverlayLayout.captureBounds(region: region, screenFrame: screen)
            == CGRect(x: -1800, y: 100, width: 800, height: 600))
    }

    @Test func defaultSquareStartsInsideBottomRightCornerWithPadding() {
        let bounds = CGRect(x: -1000, y: -200, width: 800, height: 500)

        #expect(CameraOverlayLayout.initialFrame(in: bounds)
            == CGRect(x: -416, y: -184, width: 200, height: 200))
        #expect(CameraOverlayLayout.initialFrame(in: bounds, preferredSide: 80)
            == CGRect(x: -296, y: -184, width: 80, height: 80))
    }

    @Test func smallRecordingRegionsKeepTheWholeSquareVisible() {
        for bounds in [CGRect(x: -20, y: 10, width: 2, height: 2),
                       CGRect(x: -20, y: 10, width: 8, height: 20),
                       CGRect(x: -20, y: 10, width: 40, height: 30),
                       CGRect(x: -20, y: 10, width: 210, height: 400)] {
            let frame = CameraOverlayLayout.initialFrame(in: bounds)

            #expect(bounds.contains(frame))
            #expect(frame.width == frame.height)
            #expect(frame.width >= 2)
            #expect(frame.width <= min(bounds.width, bounds.height))
        }
    }

    @Test func preferredSideCannotCreateAnInvisibleSquare() {
        let bounds = CGRect(x: 10, y: 20, width: 600, height: 400)
        let frame = CameraOverlayLayout.initialFrame(in: bounds, preferredSide: 0)

        #expect(frame.width == 2)
        #expect(frame.height == 2)
        #expect(bounds.contains(frame))
    }

    @Test func draggingInsideTheRecordingRegionPreservesPositionAndSize() {
        let bounds = CGRect(x: -1000, y: -200, width: 800, height: 500)
        let frame = CGRect(x: -700, y: -50, width: 200, height: 200)

        #expect(CameraOverlayLayout.clamped(frame, to: bounds) == frame)
    }

    @Test func draggingPastAnyEdgeStopsAtThatEdge() {
        let bounds = CGRect(x: -1000, y: -200, width: 800, height: 500)
        let examples: [(CGRect, CGRect)] = [
            (CGRect(x: -1200, y: -50, width: 200, height: 200),
             CGRect(x: -1000, y: -50, width: 200, height: 200)),
            (CGRect(x: -100, y: -50, width: 200, height: 200),
             CGRect(x: -400, y: -50, width: 200, height: 200)),
            (CGRect(x: -700, y: -300, width: 200, height: 200),
             CGRect(x: -700, y: -200, width: 200, height: 200)),
            (CGRect(x: -700, y: 250, width: 200, height: 200),
             CGRect(x: -700, y: 100, width: 200, height: 200))
        ]

        for (proposed, expected) in examples {
            #expect(CameraOverlayLayout.clamped(proposed, to: bounds) == expected)
        }
    }

    @Test func oversizedOverlayShrinksToFitTheRecordingRegion() {
        let bounds = CGRect(x: -1000, y: -200, width: 800, height: 500)
        let proposed = CGRect(x: -700, y: 100, width: 1200, height: 1200)

        #expect(CameraOverlayLayout.clamped(proposed, to: bounds)
            == CGRect(x: -700, y: -200, width: 500, height: 500))
    }

    @Test func clampingKeepsSmallAndNonSquareFramesSquare() {
        let bounds = CGRect(x: 10, y: 20, width: 30, height: 8)

        #expect(CameraOverlayLayout.clamped(
            CGRect(x: 100, y: 200, width: 200, height: 100), to: bounds)
            == CGRect(x: 32, y: 20, width: 8, height: 8))
        #expect(CameraOverlayLayout.clamped(
            CGRect(x: 10, y: 20, width: 1, height: 1), to: bounds)
            == CGRect(x: 10, y: 20, width: 2, height: 2))
    }

    @Test func invalidBoundsDoNotCreateAnOverlay() {
        let frame = CGRect(x: 10, y: 20, width: 200, height: 200)
        for bounds in [CGRect.zero,
                       CGRect(x: 0, y: 0, width: 1, height: 100),
                       CGRect(x: 0, y: 0, width: 100, height: 1),
                       CGRect(x: 0, y: 0, width: -100, height: 100)] {
            #expect(CameraOverlayLayout.initialFrame(in: bounds) == .zero)
            #expect(CameraOverlayLayout.clamped(frame, to: bounds) == .zero)
        }
    }

    @Test func windowNumbersRejectUnrealizedAndOutOfRangeWindowsWithoutTrapping() {
        for number in [Int.min, -1, 0, Int(UInt32.max) + 1, Int.max] {
            #expect(CameraOverlayLayout.windowID(from: number) == nil)
        }

        #expect(CameraOverlayLayout.windowID(from: 1) == 1)
        #expect(CameraOverlayLayout.windowID(from: 42) == 42)
        #expect(CameraOverlayLayout.windowID(from: Int(UInt32.max)) == UInt32.max)
    }
}
