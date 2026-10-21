import AppKit

enum FinderMenuBuilder {
    static func makeMenu(loadConfiguration: () throws -> ToolMenuConfiguration?, target: AnyObject, action: Selector) -> NSMenu {
        let menu = NSMenu(title: "OmniDesk")
        menu.autoenablesItems = false
        do {
            if let configuration = try loadConfiguration() {
                for entry in configuration.visibleEntries {
                    guard let tag = FinderMenuActionRegistry.tag(for: entry.id) else { continue }
                    let item = NSMenuItem(title: entry.title, action: action, keyEquivalent: "")
                    item.target = target; item.tag = tag
                    if entry.id == "newTemplate" {
                        item.action = nil
                        let formats = NSMenu(); formats.autoenablesItems = false; item.submenu = formats
                        for format in ToolMenuCatalog.templateFormats {
                            guard let tag = FinderMenuActionRegistry.tag(for: "newTemplate." + format.id) else { continue }
                            let child = NSMenuItem(title: format.title, action: action, keyEquivalent: "")
                            child.target = target; child.tag = tag; formats.addItem(child)
                        }
                    }
                    menu.addItem(item)
                }
            } else {
                let missing = NSMenuItem(title: "请先在软件设置中配置右键菜单", action: nil, keyEquivalent: "")
                missing.isEnabled = false; menu.addItem(missing)
            }
        } catch {
            let failed = NSMenuItem(title: "菜单配置不可用，请打开设置", action: nil, keyEquivalent: "")
            failed.isEnabled = false; menu.addItem(failed)
        }
        if menu.numberOfItems > 0 { menu.addItem(.separator()) }
        let settings = NSMenuItem(title: "设置右键菜单…", action: action, keyEquivalent: "")
        settings.target = target
        settings.tag = FinderMenuActionRegistry.tag(for: FinderMenuActionRegistry.settingsAction)!
        menu.addItem(settings)
        return menu
    }
}
