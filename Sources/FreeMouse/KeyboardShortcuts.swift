import AppKit
import Carbon
import SwiftUI

enum ShortcutAction: String, CaseIterable, Codable, Identifiable {
    case region, scroll, full, window, record, ocr
    var id: String { rawValue }
    var hotKeyID: UInt32 { UInt32(Self.allCases.firstIndex(of: self)! + 1) }
    var title: String {
        switch self {
        case .region: return "区域截图"
        case .scroll: return "滚动长截图"
        case .full: return "全屏截图"
        case .window: return "窗口截图"
        case .record: return "开始/停止区域录屏"
        case .ocr: return "截图识字（OCR）"
        }
    }
}

struct KeyboardShortcut: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    var isValid: Bool {
        Self.keyNames[keyCode] != nil && modifiers & UInt32(cmdKey | controlKey | optionKey) != 0 &&
        modifiers & ~UInt32(cmdKey | controlKey | optionKey | shiftKey) == 0
    }
    var display: String {
        [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
            .filter { modifiers & UInt32($0.0) != 0 }.map { $0.1 }.joined() + (Self.keyNames[keyCode] ?? "?")
    }
    static func from(_ event: NSEvent) -> Self {
        var flags: UInt32 = 0
        for (cocoa, carbon) in [(NSEvent.ModifierFlags.command, cmdKey), (.control, controlKey), (.option, optionKey), (.shift, shiftKey)] {
            if event.modifierFlags.contains(cocoa) { flags |= UInt32(carbon) }
        }
        return Self(keyCode: UInt32(event.keyCode), modifiers: flags)
    }
    static let keyNames: [UInt32: String] = [
        0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",11:"B",12:"Q",13:"W",14:"E",15:"R",16:"Y",17:"T",
        18:"1",19:"2",20:"3",21:"4",22:"6",23:"5",24:"=",25:"9",26:"7",27:"−",28:"8",29:"0",30:"]",31:"O",32:"U",33:"[",34:"I",35:"P",
        36:"↩",37:"L",38:"J",39:"'",40:"K",41:";",42:"\\",43:",",44:"/",45:"N",46:"M",47:".",49:"空格",50:"`",
        96:"F5",97:"F6",98:"F7",99:"F3",100:"F8",101:"F9",103:"F11",109:"F10",111:"F12",118:"F4",120:"F2",122:"F1",
        123:"←",124:"→",125:"↓",126:"↑"
    ]
    static let defaults: [ShortcutAction: Self] = [
        .region: .init(keyCode: 0, modifiers: UInt32(cmdKey | optionKey | controlKey)),
        .scroll: .init(keyCode: 1, modifiers: UInt32(cmdKey | optionKey | controlKey)),
        .record: .init(keyCode: 15, modifiers: UInt32(cmdKey | optionKey | controlKey))
    ]
}

/// Registration is injected so rollback can be tested without reserving global keys.
@MainActor final class ShortcutRegistry {
    var register: ((ShortcutAction, KeyboardShortcut) -> UUID?)?
    var unregister: ((UUID) -> Void)?
    private var tokens: [UUID] = []
    private(set) var active: [ShortcutAction: KeyboardShortcut] = [:]
    private(set) var rollbackFailed = false
    @discardableResult func activateAvailable(_ bindings: [ShortcutAction: KeyboardShortcut]) -> [ShortcutAction] {
        suspend()
        active = bindings
        var failures: [ShortcutAction] = []
        for action in ShortcutAction.allCases {
            guard let key = bindings[action] else { continue }
            if let token = register?(action, key) { tokens.append(token) }
            else { failures.append(action) }
        }
        return failures
    }
    func suspend() { tokens.forEach { unregister?($0) }; tokens = [] }
    func apply(_ bindings: [ShortcutAction: KeyboardShortcut]) -> Bool {
        let old = active
        rollbackFailed = false
        suspend()
        var newTokens: [UUID] = []
        for action in ShortcutAction.allCases {
            guard let key = bindings[action] else { continue }
            guard let token = register?(action, key) else {
                newTokens.forEach { unregister?($0) }
                tokens = []
                for oldAction in ShortcutAction.allCases {
                    if let oldKey = old[oldAction] {
                        if let token = register?(oldAction, oldKey) { tokens.append(token) }
                        else { rollbackFailed = true }
                    }
                }
                return false
            }
            newTokens.append(token)
        }
        tokens = newTokens; active = bindings
        return true
    }
}

@MainActor protocol ShortcutPreferences: AnyObject {
    func data(forKey key: String) -> Data?
    func save(_ data: Data, forKey key: String)
}

@MainActor final class ShortcutUserPreferences: ShortcutPreferences {
    func data(forKey key: String) -> Data? { UserDefaults.standard.data(forKey: key) }
    func save(_ data: Data, forKey key: String) { UserDefaults.standard.set(data, forKey: key) }
}

@MainActor final class ShortcutSettings: ObservableObject {
    @Published private(set) var bindings: [ShortcutAction: KeyboardShortcut]
    @Published private(set) var recording: ShortcutAction?
    @Published private(set) var message: String?
    let registry = ShortcutRegistry()
    var onChange: (() -> Void)?
    private let preferences: ShortcutPreferences
    private let storageKey = "keyboardShortcuts.v1"
    init(preferences: ShortcutPreferences? = nil) {
        let preferences = preferences ?? ShortcutUserPreferences()
        self.preferences = preferences
        if let data = preferences.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode([String: KeyboardShortcut].self, from: data) {
            var loaded: [ShortcutAction: KeyboardShortcut] = [:]
            for action in ShortcutAction.allCases { loaded[action] = saved[action.rawValue] }
            bindings = Self.validate(loaded) == nil ? loaded : KeyboardShortcut.defaults
        } else { bindings = KeyboardShortcut.defaults }
    }
    static func validate(_ bindings: [ShortcutAction: KeyboardShortcut]) -> String? {
        var seen: [KeyboardShortcut] = []
        for action in ShortcutAction.allCases {
            guard let key = bindings[action] else { continue }
            guard key.isValid else { return "请使用 ⌘、⌃ 或 ⌥ 加一个按键。" }
            if seen.contains(key) { return "快捷键重复，请为不同功能选择不同组合。" }
            seen.append(key)
        }
        return nil
    }
    func title(_ action: ShortcutAction) -> String { bindings[action]?.display ?? "未设置" }
    func beginRecording(_ action: ShortcutAction) {
        recording = action; message = nil; registry.suspend()
    }
    func cancelRecording() {
        guard recording != nil else { return }
        recording = nil
        let unavailable = registry.activateAvailable(bindings)
        if !unavailable.isEmpty { message = "部分快捷键被占用：" + unavailable.map(\.title).joined(separator: "、") }
    }
    @discardableResult func set(_ key: KeyboardShortcut?, for action: ShortcutAction) -> Bool {
        var proposed = bindings; proposed[action] = key
        return save(proposed)
    }
    func restoreDefaults() { _ = save(KeyboardShortcut.defaults) }
    private func save(_ proposed: [ShortcutAction: KeyboardShortcut]) -> Bool {
        let wasRecording = recording != nil
        recording = nil
        if let error = Self.validate(proposed) {
            message = error
            if wasRecording { _ = registry.apply(bindings) }
            return false
        }
        guard registry.apply(proposed) else {
            message = registry.rollbackFailed
                ? "未保存更改，部分原快捷键也已被占用；请更换组合或恢复默认。"
                : "快捷键被系统或其他应用占用，未保存更改；请换一个组合。"
            return false
        }
        guard let data = try? JSONEncoder().encode(Dictionary(uniqueKeysWithValues: proposed.map { ($0.key.rawValue, $0.value) })) else { return false }
        bindings = proposed; preferences.save(data, forKey: storageKey)
        message = "快捷键已保存并生效。"; onChange?()
        return true
    }
}

struct ShortcutSettingsPane: View {
    @ObservedObject var settings: ShortcutSettings
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(ShortcutAction.allCases) { action in
                HStack {
                    Text(action.title).font(.system(size: 12))
                    Spacer()
                    if settings.recording == action {
                        ShortcutRecorder(settings: settings, action: action).frame(width: 190, height: 28)
                        Button("取消") { settings.cancelRecording() }
                    } else {
                        Button(settings.title(action)) { settings.beginRecording(action) }.frame(minWidth: 140)
                        Button("清除") { _ = settings.set(nil, for: action) }.disabled(settings.bindings[action] == nil)
                    }
                }
            }
            Text("点击组合键后直接按键录入，需包含 ⌘、⌃ 或 ⌥；Esc 取消录入。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            HStack {
                if let message = settings.message { Text(message).font(.system(size: 11)).foregroundStyle(.secondary) }
                Spacer()
                Button("恢复默认") { settings.restoreDefaults() }
            }
        }.padding(14).onDisappear { settings.cancelRecording() }
    }
}

private struct ShortcutRecorder: NSViewRepresentable {
    let settings: ShortcutSettings
    let action: ShortcutAction
    func makeNSView(context: Context) -> ShortcutRecorderView {
        let view = ShortcutRecorderView()
        view.onKey = { event in
            if event.keyCode == 53 { settings.cancelRecording() }
            else { _ = settings.set(KeyboardShortcut.from(event), for: action) }
        }
        return view
    }
    func updateNSView(_ view: ShortcutRecorderView, context: Context) {
        view.onKey = { event in
            if event.keyCode == 53 { settings.cancelRecording() }
            else { _ = settings.set(KeyboardShortcut.from(event), for: action) }
        }
        DispatchQueue.main.async { [weak view] in
            guard let view, view.window != nil, settings.recording == action else { return }
            view.window?.makeFirstResponder(view)
        }
    }
}

private final class ShortcutRecorderView: NSView {
    var onKey: ((NSEvent) -> Void)?
    private var monitor: Any?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window, window.isKeyWindow,
                  window.firstResponder === self else { return event }
            self.onKey?(event)
            return nil
        }
    }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func keyDown(with event: NSEvent) { onKey?(event) }
    override func performKeyEquivalent(with event: NSEvent) -> Bool { onKey?(event); return true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.12).setFill(); bounds.fill()
        ("请按快捷键…" as NSString).draw(at: CGPoint(x: 10, y: 6), withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor])
    }
}
