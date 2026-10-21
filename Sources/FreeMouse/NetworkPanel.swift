// Layout and dashboard sizing adapted from Stats Modules/Net/popup.swift (MIT).
// Copyright © 2020 Serhiy Mytrovtsiy. License: ThirdParty/Stats.
import AppKit
import SwiftUI

/// The detail popover reads the same samples as the menu bar; it owns no timers.
@MainActor
struct NetworkPanel: View {
    @ObservedObject var monitor: NetworkMonitor
    var onOpenToolbox: () -> Void
    private let downloadColor = Color(nsColor: .systemBlue)
    private let uploadColor = Color(nsColor: .systemRed)

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header
                rates
                history
                connections
                totals
                status
                interface
                addresses
                processes
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .frame(width: 280)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        ZStack {
            Text("网络").font(.system(size: 16, weight: .semibold))
            HStack {
                Image(systemName: "wifi").font(.system(size: 17))
                Spacer()
                Button(action: onOpenToolbox) { Image(systemName: "command").font(.system(size: 16)) }
                    .buttonStyle(.borderless).help("打开工具箱").accessibilityLabel("工具箱")
            }
        }.frame(height: 42)
    }

    private var rates: some View {
        HStack(spacing: 0) {
            rate("下载", symbol: "arrow.down", value: monitor.speed.download, color: downloadColor)

            rate("上传", symbol: "arrow.up", value: monitor.speed.upload, color: uploadColor)
        }
        .frame(height: 90)
    }

    private func rate(_ title: String, symbol: String, value: Double, color: Color) -> some View {
        VStack(spacing: 2) {
            let parts = NetworkSpeedFormatter.string(value).split(separator: " ", maxSplits: 1)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(String(parts.first ?? "0")).font(.system(size: 26, weight: .light))
                Text(parts.count > 1 ? String(parts[1]) : "B/s").font(.system(size: 13, weight: .light))
            }
            .monospacedDigit().minimumScaleFactor(0.6).lineLimit(1)
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 4).fill(color).frame(width: 12, height: 12)
                Text(title).font(.system(size: 11))
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("负载历史")
            NetworkLoadChart(samples: monitor.history)
                .padding(.vertical, 1)
                .frame(height: 90)
                .background(Color.gray.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .accessibilityLabel("上传与下载负载历史，分别按各自峰值缩放")

        }
    }

    private var connections: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("连接历史")
            NetworkConnectionChart(samples: monitor.connectionHistory)
            .padding(.vertical, 1)
            .frame(height: 30)
            .background(Color.gray.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .accessibilityLabel("最近连接检测历史")
        }
    }

    private var totals: some View {
        VStack(spacing: 0) {
            sectionTitle("接口", action: monitor.resetTotals, help: "重置累计上传和下载流量")
            totalRow("总上传：", value: monitor.totalUpload, color: uploadColor)
            totalRow("总下载：", value: monitor.totalDownload, color: downloadColor)
        }
    }

    private var status: some View {
        VStack(spacing: 0) {
            badgeRow("状态", value: monitor.interface?.isUp)
            badgeRow("网络连接状态", value: monitor.reachable)
            detail("延迟", value: milliseconds(monitor.latency)).help("HTTPS 请求往返延迟")
            detail("Jitter", value: milliseconds(monitor.jitter)).help("相邻 HTTPS 延迟样本的抖动")
        }
    }

    private var interface: some View {
        VStack(spacing: 0) {
            sectionTitle("接口")
            detail("接口", value: monitor.interface.map { "\($0.displayName) (\($0.name))" } ?? "未知")
            badgeRow("状态", value: monitor.interface?.isUp)
            detail("物理地址", value: monitor.interface?.hardwareAddress ?? "未知")
            HStack {
                Text("网络：")
                Spacer()
                if let ssid = monitor.interface?.ssid, !ssid.isEmpty {
                    Text(ssid).lineLimit(1).textSelection(.enabled)
                } else {
                    Button("申请详细信息", action: monitor.requestWiFiDetails)
                        .controlSize(.small).help("申请读取 Wi-Fi 名称所需的系统权限")
                }
            }.font(.system(size: 13)).frame(height: 22)
        }
    }

    private var addresses: some View {
        VStack(spacing: 0) {
            sectionTitle("地址", action: monitor.refreshPublicIP, help: "刷新公网 IP 和国家信息")
            detail("本地 IP", value: monitor.interface?.localIPv4 ?? "未知")
            if let address = monitor.interface?.localIPv6, !address.isEmpty {
                detail("本地 IPv6", value: address)
            }
            detail("公网 IP", value: publicAddress)
        }
    }

    private var publicAddress: String {
        guard let ip = monitor.publicIP else { return "未知" }
        guard let country = monitor.country, !country.isEmpty else { return ip }
        return "\(ip) (\(country))"
    }

    private var processes: some View {
        VStack(spacing: 0) {
            sectionTitle("高占用进程")
            HStack {
                Text("进程")
                Spacer()
                RoundedRectangle(cornerRadius: 2).fill(downloadColor).frame(width: 8, height: 8)
                    .frame(width: 67, alignment: .trailing)
                RoundedRectangle(cornerRadius: 2).fill(uploadColor).frame(width: 8, height: 8)
                    .frame(width: 67, alignment: .trailing)
            }.font(.system(size: 13)).frame(height: 22)
            ForEach(Array(monitor.processes.prefix(8))) { process in
                HStack(spacing: 5) {
                    Button("Kill") { monitor.killProcess(process) }
                        .buttonStyle(.borderless).font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.red).frame(width: 22)
                        .disabled(monitor.killUnavailableReason(process) != nil)
                        .help(monitor.killUnavailableReason(process) ?? "强制结束 \(process.name)（PID \(process.id)），可能丢失未保存内容")
                        .accessibilityLabel("强制结束 \(process.name)，PID \(process.id)")
                    Image(nsImage: processIcon(process.id)).resizable().frame(width: 16, height: 16)
                    Text(process.name).lineLimit(1).truncationMode(.middle).help(process.name)
                    Spacer(minLength: 0)
                    Text(NetworkSpeedFormatter.string(process.download))
                        .frame(width: 67, alignment: .trailing)
                    Text(NetworkSpeedFormatter.string(process.upload))
                        .frame(width: 67, alignment: .trailing)
                }
                .font(.system(size: 11)).monospacedDigit().frame(height: 22)
            }
            if monitor.processes.isEmpty {
                Text(monitor.processStatus ?? "暂无进程流量数据")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3)
            }
            if let message = monitor.processActionMessage {
                Text(message).font(.system(size: 11))
                    .foregroundStyle(monitor.processActionFailed ? Color.red : Color.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3)
            }
        }
    }

    private func sectionTitle(_ title: String, action: (() -> Void)? = nil, help: String = "") -> some View {
        ZStack {
            HStack(spacing: 8) {
                Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
                Text(title).font(.system(size: 10, weight: .semibold)).kerning(1)
                    .foregroundStyle(Color(nsColor: .tertiaryLabelColor)).fixedSize()
                Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
            }
            if let action {
                HStack {
                    Spacer()
                    Button(action: action) { Image(systemName: "arrow.clockwise").font(.system(size: 10)) }
                        .buttonStyle(.borderless).help(help).accessibilityLabel(help)
                        .padding(.leading, 5).background(Color(nsColor: .windowBackgroundColor))
                }
            }
        }.frame(height: 30)
    }

    private func badgeRow(_ label: String, value: Bool?) -> some View {
        HStack {
            Text(label + "：").font(.system(size: 13))
            Spacer()
            Text(value.map { $0 ? "UP" : "DOWN" } ?? "未知")
                .font(.system(size: 11, weight: .light)).foregroundStyle(.white)
                .frame(width: 50, height: 14)
                .background(value.map { Color(nsColor: $0 ? .systemGreen : .systemRed) } ?? Color(nsColor: .secondaryLabelColor))
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }.frame(height: 22)
    }

    private func detail(_ label: String, value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label + "：").font(.system(size: 13)).fixedSize()
            Spacer(minLength: 0)
            Text(value).font(monospaced ? .system(size: 13, design: .monospaced) : .system(size: 13))
                .multilineTextAlignment(.trailing).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }.frame(minHeight: 22)
    }

    private func totalRow(_ label: String, value: Double, color: Color) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text(label)
            Spacer()
            Text(total(value)).fontWeight(.medium).monospacedDigit()
        }.font(.system(size: 13)).frame(height: 22)
    }

    private func milliseconds(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "未知" }
        return String(format: "%.1f ms", value)
    }

    private func total(_ value: Double) -> String {
        let safe = value.isFinite ? max(0, min(value, Double(Int64.max - 1024))) : 0
        return ByteCountFormatter.string(fromByteCount: Int64(safe), countStyle: .binary)
    }

    private func processIcon(_ pid: Int32) -> NSImage {
        NSRunningApplication(processIdentifier: pid)?.icon
            ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)!
    }
}
