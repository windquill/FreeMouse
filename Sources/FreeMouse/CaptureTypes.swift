import AppKit

/// ScreenCaptureKit uses display-relative top-left points, never global Cocoa coordinates.
struct CaptureRegion {
    let displayID: CGDirectDisplayID
    let rect: CGRect
    let scale: CGFloat

    var pixelRect: CGRect {
        CGRect(x: rect.minX * scale, y: rect.minY * scale,
               width: rect.width * scale, height: rect.height * scale).integral
    }

    static func from(selection: CGRect, screenFrame: CGRect,
                     displayID: CGDirectDisplayID, scale: CGFloat) -> CaptureRegion {
        let clipped = selection.standardized.intersection(screenFrame)
        return CaptureRegion(displayID: displayID,
            rect: CGRect(x: clipped.minX - screenFrame.minX,
                         y: screenFrame.maxY - clipped.maxY,
                         width: clipped.width, height: clipped.height), scale: scale)
    }
}

enum CaptureError: LocalizedError {
    case noDisplay, invalidRegion, unavailableImage, sizeChanged, noOverlap, limitReached
    var errorDescription: String? {
        switch self {
        case .noDisplay: return "没有找到所选显示器。请重新选择截图区域。"
        case .invalidRegion: return "截图区域无效或超出显示器边界。"
        case .unavailableImage: return "无法读取截图像素。请检查屏幕录制权限。"
        case .sizeChanged: return "采集区域尺寸发生变化，请重新开始。"
        case .noOverlap: return "无法可靠匹配两帧。请向上滚回上一帧附近，再少量向下滚动后采集。"
        case .limitReached: return "截图尺寸超出可处理范围，无法继续采集。"
        }
    }
}

extension NSScreen {
    var captureDisplayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
