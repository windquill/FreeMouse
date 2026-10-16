import CoreGraphics

enum SelectionHandle: CaseIterable {
    case bottomLeft, bottom, bottomRight, right, topRight, top, topLeft, left
    func point(in r: CGRect) -> CGPoint {
        switch self {
        case .bottomLeft: return CGPoint(x: r.minX, y: r.minY)
        case .bottom: return CGPoint(x: r.midX, y: r.minY)
        case .bottomRight: return CGPoint(x: r.maxX, y: r.minY)
        case .right: return CGPoint(x: r.maxX, y: r.midY)
        case .topRight: return CGPoint(x: r.maxX, y: r.maxY)
        case .top: return CGPoint(x: r.midX, y: r.maxY)
        case .topLeft: return CGPoint(x: r.minX, y: r.maxY)
        case .left: return CGPoint(x: r.minX, y: r.midY)
        }
    }
}

enum SelectionGeometry {
    static func handle(at p: CGPoint, rect: CGRect) -> SelectionHandle? {
        if let h = SelectionHandle.allCases.first(where: { h in
            let q = h.point(in: rect)
            return abs(p.x - q.x) <= 7 && abs(p.y - q.y) <= 7
        }) { return h }
        if p.y >= rect.minY && p.y <= rect.maxY {
            if abs(p.x - rect.minX) <= 7 { return .left }
            if abs(p.x - rect.maxX) <= 7 { return .right }
        }
        if p.x >= rect.minX && p.x <= rect.maxX {
            if abs(p.y - rect.minY) <= 7 { return .bottom }
            if abs(p.y - rect.maxY) <= 7 { return .top }
        }
        return nil
    }
    static func moved(_ r: CGRect, delta: CGSize, bounds: CGRect) -> CGRect {
        CGRect(x: min(max(r.minX + delta.width, bounds.minX), bounds.maxX - r.width),
               y: min(max(r.minY + delta.height, bounds.minY), bounds.maxY - r.height),
               width: r.width, height: r.height)
    }
    static func resized(_ r: CGRect, handle: SelectionHandle, point: CGPoint, bounds: CGRect) -> CGRect {
        let x = min(max(point.x, bounds.minX), bounds.maxX)
        let y = min(max(point.y, bounds.minY), bounds.maxY)
        var left = r.minX, right = r.maxX, bottom = r.minY, top = r.maxY
        switch handle {
        case .bottomLeft, .topLeft, .left: left = min(x, right - 4)
        case .bottomRight, .topRight, .right: right = max(x, left + 4)
        default: break
        }
        switch handle {
        case .bottomLeft, .bottomRight, .bottom: bottom = min(y, top - 4)
        case .topLeft, .topRight, .top: top = max(y, bottom + 4)
        default: break
        }
        return CGRect(x: left, y: bottom, width: right - left, height: top - bottom)
    }
}
