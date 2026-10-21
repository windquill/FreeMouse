// Network counter reading and two-row display adapted from Stats (MIT).
// Copyright (c) 2019 Serhiy Mytrovtsiy.
// Pinned source and full license: ThirdParty/Stats.
import AppKit
import Darwin
import SystemConfiguration

struct NetworkSpeed: Equatable {
    var upload: Double
    var download: Double
    static let zero = Self(upload: 0, download: 0)
}

struct NetworkCounterSample {
    var interface: String
    var upload: UInt64
    var download: UInt64
    var timestamp: TimeInterval
}

struct NetworkSpeedCalculator {
    private var previous: NetworkCounterSample?
    mutating func reset() { previous = nil }

    mutating func update(_ sample: NetworkCounterSample?) -> NetworkSpeed {
        defer { previous = sample }
        guard let sample, let previous, sample.interface == previous.interface else { return .zero }
        let elapsed = sample.timestamp - previous.timestamp
        // Rebaseline after sleep or a delayed timer rather than showing stale traffic.
        guard elapsed.isFinite, elapsed > 0, elapsed <= 5 else { return .zero }
        func rate(_ current: UInt64, _ old: UInt64) -> Double {
            guard current >= old else { return 0 }
            let delta = Double(current - old)
            // Stats' 100 Gbps fallback rejects one-shot counter jumps on reconnect.
            guard delta <= 12_500_000_000 * elapsed else { return 0 }
            return delta / elapsed
        }
        return .init(upload: rate(sample.upload, previous.upload), download: rate(sample.download, previous.download))
    }
}

enum NetworkCounterReader {
    private static let virtualPrefixes = ["utun", "ipsec", "ppp", "tun", "tap", "gif", "stf", "wg", "lo"]

    static func chooseInterface(primary: String?, services: [String], active: [String]) -> String? {
        func usable(_ name: String) -> Bool {
            active.contains(name) && !virtualPrefixes.contains(where: { name.hasPrefix($0) })
        }
        if let primary, usable(primary) { return primary }
        return services.first(where: usable) ?? active.first(where: usable)
    }

    static func snapshot() -> NetworkCounterSample? {
        guard let interface = currentInterface() else { return nil }
        let index = if_nametoindex(interface)
        guard index != 0 else { return nil }
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, Int32(index)]
        var size: size_t = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0,
              size > 0, size <= 16 * 1024 * 1024 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0) == 0,
              size <= buffer.count,
              let bytes = parse(Array(buffer.prefix(size)), index: index) else { return nil }
        return .init(interface: interface, upload: bytes.upload, download: bytes.download,
                     timestamp: ProcessInfo.processInfo.systemUptime)
    }

    // Stats' NET_RT_IFLIST2 reader uses 64-bit counters; if_data from getifaddrs
    // contains 32-bit counters and wraps during large transfers.
    static func parse(_ buffer: [UInt8], index: UInt32) -> (upload: UInt64, download: UInt64)? {
        var offset = 0
        while offset + MemoryLayout<if_msghdr>.size <= buffer.count {
            var header = if_msghdr()
            buffer.withUnsafeBytes { source in
                _ = memcpy(&header, source.baseAddress!.advanced(by: offset), MemoryLayout<if_msghdr>.size)
            }
            let length = Int(header.ifm_msglen)
            guard length >= MemoryLayout<if_msghdr>.size, length <= buffer.count - offset else { return nil }
            if Int32(header.ifm_type) == RTM_IFINFO2 {
                guard length >= MemoryLayout<if_msghdr2>.size else { return nil }
                var header2 = if_msghdr2()
                buffer.withUnsafeBytes { source in
                    _ = memcpy(&header2, source.baseAddress!.advanced(by: offset), MemoryLayout<if_msghdr2>.size)
                }
                if UInt32(header2.ifm_index) == index {
                    return (header2.ifm_data.ifi_obytes, header2.ifm_data.ifi_ibytes)
                }
            }
            offset += length
        }
        return nil
    }

    private static func currentInterface() -> String? {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0 else { return nil }
        defer { freeifaddrs(addresses) }
        var active: [String] = []
        var pointer = addresses
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            let flags = current.pointee.ifa_flags
            guard flags & UInt32(IFF_UP) != 0, flags & UInt32(IFF_RUNNING) != 0,
                  flags & UInt32(IFF_LOOPBACK | IFF_POINTOPOINT) == 0,
                  current.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK) else { continue }
            active.append(String(cString: current.pointee.ifa_name))
        }
        func state(_ key: String) -> [String: Any]? {
            SCDynamicStoreCopyValue(nil, key as CFString) as? [String: Any]
        }
        let primary = state("State:/Network/Global/IPv4")?["PrimaryInterface"] as? String
            ?? state("State:/Network/Global/IPv6")?["PrimaryInterface"] as? String
        let order = state("Setup:/Network/Global/IPv4")?["ServiceOrder"] as? [String] ?? []
        let services: [String] = order.compactMap { id in
            for family in ["IPv4", "IPv6"] {
                if let service = state("State:/Network/Service/\(id)/\(family)"),
                   service["Router"] != nil, let name = service["InterfaceName"] as? String { return name }
            }
            return nil
        }
        return chooseInterface(primary: primary, services: services, active: active)
    }
}

enum NetworkSpeedFormatter {
    static func string(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond > 0 else { return "0 B/s" }
        var value = bytesPerSecond
        let units = ["B/s", "KB/s", "MB/s", "GB/s", "TB/s"]
        var unit = 0
        while value >= 1024, unit < units.count - 1 { value /= 1024; unit += 1 }
        return String(format: unit == 0 ? "%.0f %@" : "%.1f %@", locale: Locale(identifier: "en_US_POSIX"), value, units[unit])
    }
}

enum NetworkSpeedMenuPreferences {
    static let spacingKey = "menuBarNetworkIconSpacing"
    static let defaultSpacing: Double = 2
    static let trailingSpacingKey = "menuBarNetworkTrailingSpacing"
    static let defaultTrailingSpacing: Double = 2
    static func spacing(from savedValue: Any?) -> Double {
        guard let number = savedValue as? NSNumber, number.doubleValue.isFinite else { return defaultSpacing }
        return min(20, max(0, number.doubleValue))
    }
    static func trailingSpacing(from savedValue: Any?) -> Double {
        guard let number = savedValue as? NSNumber, number.doubleValue.isFinite else { return defaultTrailingSpacing }
        return min(12, max(0, number.doubleValue))
    }
}

enum NetworkSpeedMenuHitTarget {
    case toolbox, network
    static func target(x: CGFloat, buttonWidth: CGFloat, imageWidth: CGFloat, spacing: Double) -> Self {
        let imageInset = max(0, (buttonWidth - imageWidth) / 2)
        let iconBoundary = imageInset + 16 + CGFloat(NetworkSpeedMenuPreferences.spacing(from: NSNumber(value: spacing))) / 2
        return x <= iconBoundary ? .toolbox : .network
    }
}

@MainActor enum NetworkSpeedMenuImage {
    /// Logarithmic interpolation keeps KB/s and MB/s changes visible on one scale.
    static func color(for bytesPerSecond: Double) -> NSColor {
        guard bytesPerSecond.isFinite, bytesPerSecond > 0 else { return .secondaryLabelColor }
        let stops: [(Double, NSColor)] = [(1024, .systemBlue), (1_048_576, .systemGreen),
                                         (10_485_760, .systemOrange), (104_857_600, .systemRed)]
        if bytesPerSecond <= stops[0].0 { return stops[0].1 }
        for index in 1..<stops.count where bytesPerSecond < stops[index].0 {
            let (low, start) = stops[index - 1]
            let (high, end) = stops[index]
            let fraction = CGFloat(log(bytesPerSecond / low) / log(high / low))
            return start.blended(withFraction: fraction, of: end) ?? end
        }
        return .systemRed
    }
    static func make(speed: NetworkSpeed, recording: Bool, elapsed: TimeInterval,
                     spacing: Double = NetworkSpeedMenuPreferences.defaultSpacing,
                     trailingSpacing: Double = NetworkSpeedMenuPreferences.defaultTrailingSpacing) -> NSImage {
        let textX = 16 + CGFloat(NetworkSpeedMenuPreferences.spacing(from: NSNumber(value: spacing)))
        let trailing = CGFloat(NetworkSpeedMenuPreferences.trailingSpacing(from: NSNumber(value: trailingSpacing)))
        let timer = recording ? String(format: "%02d:%02d", Int(max(0, elapsed)) / 60, Int(max(0, elapsed)) % 60) : ""
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        let timerFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let rows = ["↑ " + NetworkSpeedFormatter.string(speed.upload), "↓ " + NetworkSpeedFormatter.string(speed.download)]
        let rowWidth = ceil(rows.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0)
        let textEnd = textX + rowWidth
        let timerWidth = recording ? ceil((timer as NSString).size(withAttributes: [.font: timerFont]).width) : 0
        let width = textEnd + (recording ? 6 + timerWidth : 0) + trailing
        let image = NSImage(size: NSSize(width: width, height: 22), flipped: false) { _ in
            let symbol = NSImage(systemSymbolName: recording ? "stop.circle.fill" : "cursorarrow.rays", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(paletteColors: [recording ? .systemRed : .labelColor]))
            symbol?.draw(in: NSRect(x: 0, y: 3, width: 16, height: 16))
            let style = NSMutableParagraphStyle()
            style.alignment = .left
            for (text, y, color) in [(rows[0], CGFloat(11), color(for: speed.upload)),
                                     (rows[1], CGFloat(0), color(for: speed.download))] {
                let line = NSMutableAttributedString(string: text, attributes: [
                    .font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: style
                ])
                line.addAttribute(.foregroundColor, value: color, range: NSRange(location: 0, length: 1))
                line.draw(in: NSRect(x: textX, y: y, width: rowWidth, height: 11))
            }
            if recording {
                (timer as NSString).draw(in: NSRect(x: textEnd + 6, y: 4, width: timerWidth, height: 15),
                                         withAttributes: [.font: timerFont, .foregroundColor: NSColor.systemRed])
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}
