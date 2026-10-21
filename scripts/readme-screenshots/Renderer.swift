import AppKit
import SwiftUI

@MainActor final class MenuTarget: NSObject {
    @objc func ignore(_ sender: Any?) {}
}

/// Documentation diagram, generated from the same menu and format registry.
struct ArchiveDiagram: View {
    let entries: [String]
    let formats: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("右键压缩与解压 · 菜单结构示意").font(.title2.bold())
            HStack(alignment: .top, spacing: 22) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("一级菜单").font(.caption).foregroundStyle(.secondary).padding(12)
                    ForEach(entries, id: \.self) { title in
                        HStack {
                            Text(title)
                            Spacer()
                            if title == "压缩" { Image(systemName: "chevron.right") }
                        }.padding(12).background(title == "压缩" ? Color.accentColor.opacity(0.12) : Color.clear)
                    }
                    Spacer()
                }.frame(width: 230).background(.background, in: RoundedRectangle(cornerRadius: 12))
                Image(systemName: "arrow.right").padding(.top, 90).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 0) {
                    Text("压缩子菜单 · \(formats.count) 种创建格式").font(.headline).padding(12)
                    ForEach(formats, id: \.self) { Text($0).font(.system(size: 13)).padding(.horizontal, 14).padding(.vertical, 5) }
                }.frame(width: 330, alignment: .leading).background(.background, in: RoundedRectangle(cornerRadius: 12))
            }
            Text("解压直接位于一级菜单；压缩格式由当前内置引擎实际能力生成。单文件流请勿用于目录或多文件。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width: 700, height: 760).background(Color(nsColor: .windowBackgroundColor))
    }
}

@main struct ReadmeRenderer {
    @MainActor static func render<V: View>(_ view: V, size: NSSize, name: String) throws {
        let hosting = NSHostingView(rootView: view.allowsHitTesting(false))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.title = "OmniDesk 文档演示（示例数据）"
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: size)
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.65))
        hosting.layoutSubtreeIfNeeded()
        guard let layer = hosting.layer,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { throw NSError(domain: "ReadmeRenderer", code: 1) }
        graphics.cgContext.scaleBy(x: 2, y: 2)
        graphics.cgContext.setFillColor(NSColor.white.cgColor)
        graphics.cgContext.fill(hosting.bounds)
        graphics.cgContext.translateBy(x: 0, y: size.height)
        graphics.cgContext.scaleBy(x: 1, y: -1)
        layer.render(in: graphics.cgContext)
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("docs/images/\(name).png")
        try bitmap.representation(using: .png, properties: [:])!.write(to: output)
        window.orderOut(nil)
        print("Rendered \(output.lastPathComponent)")
    }

    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let state = StartupManagerState(store: StartupStore(stateDirectory: root.appendingPathComponent(".build/readme-screenshots/state"), launchAgentsDirectory: root.appendingPathComponent(".build/readme-screenshots/agents")))
        state.applications = [
            StartupApplication(path: "/System/Applications/Notes.app", name: "备忘录", loginEnabled: true),
            StartupApplication(path: "/System/Applications/Utilities/Terminal.app", name: "终端", loginEnabled: false),
            StartupApplication(path: "/System/Applications/Calculator.app", name: "计算器", loginEnabled: nil)]
        state.runtime.processes = [ManagedApplicationProcess(pid: 99991, bundlePath: "/System/Applications/Utilities/Terminal.app", bundleIdentifier: "com.apple.Terminal", name: "终端", launchDate: Date(), identity: nil)]
        try render(StartupManagerView(state: state, runtime: state.runtime), size: NSSize(width: 1080, height: 720), name: "application-manager")

        let input = InputSourceSwitcher(defaults: UserDefaults(suiteName: "local.omnidesk.readme-demo")!)
        input.settings = AppInputSettings(enabled: true, rules: [
            AppInputRule(bundleIdentifier: "com.apple.Safari", name: "Safari", sourceID: "demo.pinyin"),
            AppInputRule(bundleIdentifier: "com.apple.Terminal", name: "终端", sourceID: "demo.abc"),
            AppInputRule(bundleIdentifier: "com.apple.Notes", name: "备忘录", sourceID: "demo.pinyin")])
        input.sources = [AvailableInputSource(id: "demo.abc", name: "ABC"), AvailableInputSource(id: "demo.pinyin", name: "拼音 - 简体")]
        input.switchCount = 128
        try render(AppInputSwitcherView(switcher: input), size: NSSize(width: 650, height: 440), name: "input-source")

        let fan = FanControlWindow()
        fan.fans = [FanReading(id: 0, actual: 3200, minimum: 2317, maximum: 6550, target: 3200, mode: 0)]
        fan.message = "系统自动调节散热 · 演示数据"
        try render(FanControlView(model: fan), size: NSSize(width: 510, height: 405), name: "fan-control")
        fan.shutdown()

        let translation = SystemTranslationState()
        translation.text = "Capture text from your screen and translate it instantly."
        translation.result = "框选屏幕上的文字，即可快速翻译。"
        translation.status = "翻译完成 · 演示文本"
        try render(SystemTranslationView(state: translation), size: NSSize(width: 650, height: 500), name: "translation")

        let target = MenuTarget()
        let config = ToolMenuConfiguration(order: ["extract", "compress"], hidden: ToolMenuCatalog.entries.map(\.id).filter { !["extract", "compress"].contains($0) })
        let menu = FinderMenuBuilder.makeMenu(loadConfiguration: { config }, target: target, action: #selector(MenuTarget.ignore(_:)))
        let entries = menu.items.filter { !$0.isSeparatorItem && $0.title != "设置右键菜单…" }.map(\.title)
        let formats = menu.items.first(where: { $0.title == "压缩" })?.submenu?.items.map(\.title) ?? []
        guard formats.count == 18 else { throw NSError(domain: "ReadmeRenderer", code: 2) }
        try render(ArchiveDiagram(entries: entries, formats: formats), size: NSSize(width: 700, height: 760), name: "archive-menu")
    }
}
