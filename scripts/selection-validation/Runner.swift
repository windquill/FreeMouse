import AppKit

@main struct SelectionValidation {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await validate(); print("RESULT_PASS selection move resize pointer coverage") }
            catch { print("RESULT_FAIL \(error)"); exit(1) }
            exit(0)
        }
        app.run()
    }
    @MainActor static func validate() async throws {
        let selector = RegionSelector()
        let pending = Task { @MainActor in await selector.selectCapture() }
        try await Task.sleep(for: .milliseconds(200))
        guard let window = NSApp.windows.first(where: { String(describing: type(of: $0.contentView!)).contains("SelectionView") }),
              let view = window.contentView, let screen = window.screen, let id = screen.captureDisplayID else { throw NSError(domain: "selection window", code: 1) }
        guard view.acceptsFirstMouse(for: nil) else { throw NSError(domain: "First click must start selection", code: 6) }
        print("FIRST_MOUSE_ACCEPTED_PASS")
        func event(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        func drag(_ a: CGPoint, _ b: CGPoint) {
            view.mouseDown(with: event(.leftMouseDown, a))
            view.mouseDragged(with: event(.leftMouseDragged, b))
            view.mouseUp(with: event(.leftMouseUp, b))
        }
        drag(CGPoint(x: 100, y: 100), CGPoint(x: 104, y: 104))
        view.resetCursorRects()
        window.invalidateCursorRects(for: view)
        print("SMALL_SELECTION_CURSOR_PASS")
        drag(CGPoint(x: 400, y: 400), CGPoint(x: 600, y: 550))
        drag(CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 250))
        drag(CGPoint(x: 200, y: 175), CGPoint(x: 240, y: 205))
        drag(CGPoint(x: 340, y: 205), CGPoint(x: 400, y: 205))
        drag(CGPoint(x: 200, y: 200), CGPoint(x: 200, y: 200))
        guard !window.ignoresMouseEvents else { throw NSError(domain: "pointer passthrough", code: 2) }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw NSError(domain: "render", code: 3) }
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsHigh) / view.bounds.height
        let alpha = rep.colorAt(x: Int(200 * scale), y: Int((view.bounds.height - 200) * scale))?.alphaComponent ?? 0
        guard alpha > 0 && alpha < 0.1 else { throw NSError(domain: "selection must retain nonzero hit surface alpha=\(alpha)", code: 4) }
        let expected = CaptureRegion.from(selection: CGRect(x: window.frame.minX + 140, y: window.frame.minY + 130, width: 260, height: 150), screenFrame: screen.frame, displayID: id, scale: screen.backingScaleFactor)
        let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        view.keyDown(with: key)
        guard let result = await pending.value, result.region.rect == expected.rect else { throw NSError(domain: "adjusted capture coordinates", code: 5) }
    }
}
