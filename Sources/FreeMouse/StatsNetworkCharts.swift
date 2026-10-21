// Adapted directly from Stats Kit/plugins/Charts.swift (MIT).
// Copyright © 2020 Serhiy Mytrovtsiy. License: ThirdParty/Stats/LICENSE.
// Kept: independent network half charts, scaleValue, line/gradient/min-max drawing,
// and GridChartView cell geometry. Removed: settings, hover tooltips and animation.
import AppKit
import SwiftUI

private enum StatsChartScale { case none, linear, square, cube, logarithmic, fixed }

private func statsScaleValue(scale: StatsChartScale = .linear, value: Double, maxValue: Double, zeroValue: Double, maxHeight: CGFloat, limit: Double) -> CGFloat {
    var value = value
    if scale == .none && value > 1 && maxValue != 0 {
        value /= maxValue
    }
    var localMaxValue = maxValue
    var y = value * maxHeight

    switch scale {
    case .square:
        if value > 0 {
            value = sqrt(value)
        }
        if localMaxValue > 0 {
            localMaxValue = sqrt(maxValue)
        }
    case .cube:
        if value > 0 {
            value = cbrt(value)
        }
        if localMaxValue > 0 {
            localMaxValue = cbrt(maxValue)
        }
    case .logarithmic:
        if value > 0 {
            value = log(value/zeroValue)
        }
        if localMaxValue > 0 {
            localMaxValue = log(maxValue/zeroValue)
        }
    case .fixed:
        if value > limit {
            value = limit
        }
        localMaxValue = limit
    default: break
    }

    if value < 0 {
        value = 0
    }
    if localMaxValue <= 0 {
        localMaxValue = 1
    }

    if scale != .none {
        y = (maxHeight * value)/localMaxValue
    }

    return y
}


@MainActor
final class StatsNetworkChartView: NSView {
    private let inChart = StatsNetworkLineView(flipY: true, color: .systemBlue)
    private let outChart = StatsNetworkLineView(flipY: false, color: .systemRed)

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(inChart)
        addSubview(outChart)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        let safeHeight = max(bounds.height, 2)
        outChart.frame = NSRect(x: 0, y: safeHeight / 2, width: bounds.width, height: safeHeight / 2)
        inChart.frame = NSRect(x: 0, y: 0, width: bounds.width, height: safeHeight / 2)
    }
    func setSamples(_ samples: [NetworkSpeed]) {
        inChart.setValues(samples.map(\.download))
        outChart.setValues(samples.map(\.upload))
    }
}

@MainActor
private final class StatsNetworkLineView: NSView {
    private var points: [Double?] = Array(repeating: nil, count: 180)
    private let flipY: Bool
    private let color: NSColor
    init(flipY: Bool, color: NSColor) {
        self.flipY = flipY
        self.color = color
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func setValues(_ values: [Double]) {
        let suffix = Array(values.suffix(180)).map { $0.isFinite ? max(0, $0) : 0 }
        points = Array(repeating: nil, count: max(0, 180 - suffix.count)) + suffix.map { Optional($0) }
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setShouldAntialias(true)
        let maxValue = points.compactMap { $0 }.max() ?? 0
        let lineColor = color
        let gradientColor = color.withAlphaComponent(0.5)
        let gradient = NSGradient(colors: [gradientColor.withAlphaComponent(0.5), gradientColor.withAlphaComponent(1.0)])
        let offset: CGFloat = 1 / (window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1)
        let height = frame.height - offset
        let xRatio = frame.width / CGFloat(points.count - 1)
        let zero: CGFloat = flipY ? frame.height : 0
        var lines: [[CGPoint]] = []
        var line: [CGPoint] = []
        for (i, value) in points.enumerated() {
            guard let value else {
                if !line.isEmpty { lines.append(line); line = [] }
                continue
            }
            var y = statsScaleValue(scale: .none, value: value, maxValue: maxValue,
                                    zeroValue: 256, maxHeight: height, limit: 1)
            if flipY { y = height - y }
            line.append(CGPoint(x: CGFloat(i) * xRatio, y: y))
        }
        if !line.isEmpty { lines.append(line) }
        var path = NSBezierPath()
        for linePoints in lines {
            if linePoints.count == 1 {
                path = NSBezierPath(ovalIn: CGRect(x: linePoints[0].x-offset, y: linePoints[0].y-offset, width: 1, height: 1))
                lineColor.set(); path.stroke()
                gradientColor.set(); path.fill()
                continue
            }
            path = NSBezierPath()
            path.move(to: linePoints[0])
            for i in 1..<linePoints.count { path.line(to: linePoints[i]) }
            lineColor.set()
            path.lineWidth = offset
            path.stroke()
            path = path.copy() as! NSBezierPath
            path.line(to: CGPoint(x: linePoints[linePoints.count-1].x, y: zero))
            path.line(to: CGPoint(x: linePoints[0].x, y: zero))
            path.close()
            if let gradient { gradient.draw(in: path, angle: 90) }
            else { gradientColor.set(); path.fill() }
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .light),
            .foregroundColor: NSColor.textColor,
            .paragraphStyle: NSMutableParagraphStyle()
        ]
        let text = NetworkSpeedFormatter.string(maxValue)
        let width = (text as NSString).size(withAttributes: attributes).width
        let y: CGFloat = flipY ? 1 : height - 9
        NSAttributedString(string: text, attributes: attributes).draw(with: CGRect(x: 1, y: y, width: width, height: 8))
    }
}

@MainActor
final class StatsGridChartView: NSView {
    private var values: [Bool?] = Array(repeating: nil, count: 90)
    func setValues(_ samples: [Bool?]) {
        let suffix = Array(samples.suffix(90))
        values = Array(repeating: nil, count: max(0, 90 - suffix.count)) + suffix
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        let grid = (rows: 30, columns: 3)
        let spacing: CGFloat = 2
        let size = CGSize(width: (frame.width - ((CGFloat(grid.rows)-1) * spacing)) / CGFloat(grid.rows),
                          height: (frame.height - ((CGFloat(grid.columns)-1) * spacing)) / CGFloat(grid.columns))
        var origin = CGPoint(x: 0, y: (size.height + spacing) * CGFloat(grid.columns - 1))
        var i = 0
        for _ in 0..<grid.columns {
            for _ in 0..<grid.rows {
                let box = NSBezierPath(roundedRect: NSRect(origin: origin, size: size), xRadius: 1, yRadius: 1)
                let color = values[i].map { $0 ? NSColor.systemGreen : NSColor.systemRed }
                    ?? NSColor.underPageBackgroundColor.withAlphaComponent(0.4)
                color.setFill(); box.fill(); box.close()
                i += 1
                origin.x += size.width + spacing
            }
            origin.x = 0
            origin.y -= size.height + spacing
        }
    }
}

struct NetworkLoadChart: NSViewRepresentable {
    var samples: [NetworkSpeed]
    func makeNSView(context: Context) -> StatsNetworkChartView { StatsNetworkChartView(frame: .zero) }
    func updateNSView(_ nsView: StatsNetworkChartView, context: Context) { nsView.setSamples(samples) }
}

struct NetworkConnectionChart: NSViewRepresentable {
    var samples: [Bool?]
    func makeNSView(context: Context) -> StatsGridChartView { StatsGridChartView(frame: .zero) }
    func updateNSView(_ nsView: StatsGridChartView, context: Context) { nsView.setValues(samples) }
}
