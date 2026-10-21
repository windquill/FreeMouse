import AppKit
import Carbon
import SwiftUI
import UniformTypeIdentifiers

struct AppInputRule: Codable, Equatable, Identifiable {
    var bundleIdentifier: String
    var name: String
    var sourceID: String
    var id: String { bundleIdentifier }
}

struct AppInputSettings: Codable, Equatable {
    var enabled = false
    var rules: [AppInputRule] = []

    static func decode(_ data: Data?) -> Self {
        guard let data, var value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        var seen = Set<String>()
        value.rules = value.rules.filter {
            !$0.bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !$0.sourceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            seen.insert($0.bundleIdentifier).inserted
        }
        return value
    }

    func target(for bundleID: String?, current: String?, available: Set<String>, ownBundleID: String?) -> String? {
        guard enabled, let bundleID, bundleID != ownBundleID,
              let rule = rules.first(where: { $0.bundleIdentifier == bundleID }),
              available.contains(rule.sourceID), current != rule.sourceID else { return nil }
        return rule.sourceID
    }
}

struct AvailableInputSource: Identifiable {
    var id: String
    var name: String
}

@MainActor
final class InputSourceSwitcher: ObservableObject {
    @Published private(set) var settings: AppInputSettings
    @Published private(set) var sources: [AvailableInputSource] = []
    @Published private(set) var switchCount = 0
    @Published private(set) var message: String?
    private let defaults: UserDefaults
    private var observer: NSObjectProtocol?
    private var window: NSWindow?
    private static let key = "OmniDesk.appInputSourceSettings.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        settings = AppInputSettings.decode(defaults.data(forKey: Self.key))
    }

    func start() {
        guard observer == nil else { return }
        refreshSources()
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor [weak self] in self?.activate(bundleID: app?.bundleIdentifier) }
        }
        if settings.enabled { activate(bundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier) }
    }

    func stop() {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
    }

    func setEnabled(_ enabled: Bool) {
        settings.enabled = enabled
        save()
        message = enabled ? "已启用：切换到已配置的应用时自动切换输入法" : "自动切换已暂停"
    }

    func setSource(_ sourceID: String, for rule: AppInputRule) {
        guard sources.contains(where: { $0.id == sourceID }),
              let index = settings.rules.firstIndex(where: { $0.id == rule.id }) else { return }
        settings.rules[index].sourceID = sourceID
        save()
    }

    func remove(_ rule: AppInputRule) {
        settings.rules.removeAll { $0.id == rule.id }
        save()
    }

    func addApplication() {
        refreshSources()
        guard let source = sources.first else { message = "没有可用的输入法，请先在系统设置中启用输入法"; return }
        let panel = NSOpenPanel()
        panel.title = "选择需要自动切换输入法的应用"
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier else { return }
        guard identifier != Bundle.main.bundleIdentifier else { message = "OmniDesk 的设置界面保留当前输入法"; return }
        guard !settings.rules.contains(where: { $0.id == identifier }) else { message = "该应用已添加"; return }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        settings.rules.append(AppInputRule(bundleIdentifier: identifier, name: name, sourceID: source.id))
        save()
        message = nil
    }

    func refreshSources() {
        sources = sourceList().compactMap { source in
            guard let id = stringProperty(source, kTISPropertyInputSourceID) else { return nil }
            return AvailableInputSource(id: id, name: stringProperty(source, kTISPropertyLocalizedName) ?? id)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func sourceList() -> [TISInputSource] {
        let filter = [kTISPropertyInputSourceIsSelectCapable as String: true,
                      kTISPropertyInputSourceIsEnabled as String: true] as CFDictionary
        guard let result = TISCreateInputSourceList(filter, false) else { return [] }
        return result.takeRetainedValue() as? [TISInputSource] ?? []
    }

    private func stringProperty(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    private func activate(bundleID: String?) {
        guard settings.enabled, let bundleID,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID,
              bundleID != Bundle.main.bundleIdentifier,
              let rule = settings.rules.first(where: { $0.id == bundleID }) else { return }
        let available = sourceList()
        guard let target = available.first(where: { stringProperty($0, kTISPropertyInputSourceID) == rule.sourceID }) else {
            message = "\(rule.name) 的输入法不可用，请重新选择或在系统设置中启用"
            return
        }
        let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
        guard settings.target(for: bundleID, current: current.flatMap { stringProperty($0, kTISPropertyInputSourceID) },
                              available: Set([rule.sourceID]), ownBundleID: Bundle.main.bundleIdentifier) != nil else { return }
        let status = TISSelectInputSource(target)
        if status == noErr { switchCount += 1; message = nil }
        else { message = "切换 \(rule.name) 的输入法失败（\(status)）" }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.key)
    }

    func showWindow() {
        refreshSources()
        if window == nil {
            let created = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 440),
                                   styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            created.title = "应用输入法"
            created.contentView = NSHostingView(rootView: AppInputSwitcherView(switcher: self))
            created.isReleasedWhenClosed = false
            created.minSize = NSSize(width: 560, height: 320)
            created.center()
            window = created
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct AppInputSwitcherView: View {
    @ObservedObject var switcher: InputSourceSwitcher
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("应用输入法").font(.title2.bold())
                    Text("进入应用时，自动使用指定输入法").foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("启用", isOn: Binding(get: { switcher.settings.enabled }, set: switcher.setEnabled))
                    .toggleStyle(.switch)
            }
            Divider()
            if switcher.settings.rules.isEmpty {
                Spacer()
                Text("添加应用，为它选择常用输入法").foregroundStyle(.secondary).frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(switcher.settings.rules) { rule in
                            HStack(spacing: 10) {
                                Image(nsImage: icon(for: rule)).resizable().frame(width: 32, height: 32)
                                Text(rule.name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                                Picker("输入法", selection: Binding(get: { rule.sourceID }, set: { switcher.setSource($0, for: rule) })) {
                                    if !switcher.sources.contains(where: { $0.id == rule.sourceID }) {
                                        Text("不可用：\(rule.sourceID)").tag(rule.sourceID)
                                    }
                                    ForEach(switcher.sources) { source in Text(source.name).tag(source.id) }
                                }.labelsHidden().frame(width: 230)
                                Button { switcher.remove(rule) } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.borderless).help("移除 \(rule.name)")
                            }
                        }
                    }.padding(.vertical, 5)
                }
            }
            if let message = switcher.message { Text(message).font(.caption).foregroundStyle(.secondary) }
            Divider()
            HStack {
                Button("添加应用…", action: switcher.addApplication)
                Button("刷新输入法", action: switcher.refreshSources)
                Spacer()
                Text("本次运行已切换 \(switcher.switchCount) 次").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(22).frame(minWidth: 520, minHeight: 280)
    }
    private func icon(for rule: AppInputRule) -> NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: rule.bundleIdentifier) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSImage(systemSymbolName: "app", accessibilityDescription: rule.name) ?? NSImage()
    }
}
