import CoreGraphics

enum CameraOverlayLayout {
    /// Capture regions use display-local top-left points; AppKit windows use global bottom-left points.
    static func captureBounds(region: CaptureRegion, screenFrame: CGRect) -> CGRect {
        CGRect(x: screenFrame.minX + region.rect.minX,
               y: screenFrame.maxY - region.rect.maxY,
               width: region.rect.width, height: region.rect.height)
    }

    static func initialFrame(in bounds: CGRect, preferredSide: CGFloat = 200) -> CGRect {
        guard isUsable(bounds) else { return .zero }
        let side = min(max(2, preferredSide), min(bounds.width, bounds.height))
        let horizontalInset = min(16, (bounds.width - side) / 2)
        let verticalInset = min(16, (bounds.height - side) / 2)
        return CGRect(x: bounds.maxX - horizontalInset - side,
                      y: bounds.minY + verticalInset,
                      width: side, height: side)
    }

    static func clamped(_ frame: CGRect, to bounds: CGRect) -> CGRect {
        guard isUsable(bounds) else { return .zero }
        let side = min(max(2, min(frame.width, frame.height)),
                       min(bounds.width, bounds.height))
        return CGRect(x: min(max(frame.minX, bounds.minX), bounds.maxX - side),
                      y: min(max(frame.minY, bounds.minY), bounds.maxY - side),
                      width: side, height: side)
    }

    static func windowID(from windowNumber: Int) -> CGWindowID? {
        guard windowNumber > 0 else { return nil }
        return CGWindowID(exactly: windowNumber)
    }

    private static func isUsable(_ bounds: CGRect) -> Bool {
        bounds.origin.x.isFinite && bounds.origin.y.isFinite
            && bounds.size.width.isFinite && bounds.size.height.isFinite
            && bounds.size.width >= 2 && bounds.size.height >= 2
    }
}
