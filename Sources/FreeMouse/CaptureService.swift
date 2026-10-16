import AppKit
import ScreenCaptureKit

@MainActor
final class CaptureService {
    private let selector = RegionSelector()

    func fullScreenRegion() -> CaptureRegion? {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main,
              let id = screen.captureDisplayID else { return nil }
        return CaptureRegion(displayID: id, rect: CGRect(origin: .zero, size: screen.frame.size), scale: screen.backingScaleFactor)
    }

    func chooseRegion() async -> CaptureRegion? { await selector.select() }

    func chooseCapture() async -> CaptureSelection? { await selector.selectCapture() }

    func capture(region: CaptureRegion) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == region.displayID }) else { throw CaptureError.noDisplay }
        let bounds = CGRect(origin: .zero, size: display.frame.size)
        guard !region.rect.isEmpty, region.rect.isFinite, bounds.contains(region.rect),
              region.scale.isFinite, region.scale > 0,
              region.pixelRect.width * region.pixelRect.height <= 40_000_000 else { throw CaptureError.invalidRegion }
        let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        filter.includeMenuBar = true
        let config = SCStreamConfiguration()
        config.sourceRect = region.rect
        config.width = Int(region.pixelRect.width)
        config.height = Int(region.pixelRect.height)
        config.showsCursor = false
        config.captureResolution = .best
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    func chooseWindow() async throws -> CGImage? {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let windows = content.windows.filter {
            $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier &&
            $0.windowLayer == 0 && $0.frame.width > 40 && $0.frame.height > 40
        }.sorted { ($0.owningApplication?.applicationName ?? "") < ($1.owningApplication?.applicationName ?? "") }
        guard !windows.isEmpty else { throw CaptureError.unavailableImage }
        let alert = NSAlert()
        alert.messageText = "选择要截图的窗口"
        alert.informativeText = "列表只包含当前屏幕上的普通窗口。"
        alert.addButton(withTitle: "截图")
        alert.addButton(withTitle: "取消")
        let picker = WindowCapturePicker.make(choices: windows.map { window in
            CaptureWindowChoice(windowID: window.windowID,
                title: "\(window.owningApplication?.applicationName ?? "应用") — \(window.title?.isEmpty == false ? window.title! : "未命名窗口")")
        })
        alert.accessoryView = picker
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        guard let selectedID = WindowCapturePicker.selectedWindowID(in: picker),
              let window = windows.first(where: { $0.windowID == selectedID }) else {
            throw CaptureError.unavailableImage
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.width = max(1, Int(filter.contentRect.width * scale))
        config.height = max(1, Int(filter.contentRect.height * scale))
        guard config.width <= 16_384, config.height <= 16_384,
              config.width * config.height <= 40_000_000 else { throw CaptureError.invalidRegion }
        config.showsCursor = false
        config.captureResolution = .best
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}

private extension CGRect {
    var isFinite: Bool { origin.x.isFinite && origin.y.isFinite && width.isFinite && height.isFinite }
}
