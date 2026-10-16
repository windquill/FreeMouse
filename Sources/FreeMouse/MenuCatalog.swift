import Foundation

struct ToolMenuEntry {
    let id: String
    let title: String
    let group: String
}
enum ToolMenuCatalog {
    static let templateFormats: [(id: String, title: String)] = [
        ("txt", "文本 TXT"), ("rtf", "富文本 RTF"), ("md", "Markdown"), ("xml", "XML"),
        ("docx", "Word"), ("xlsx", "Excel"), ("pptx", "PowerPoint"), ("json", "JSON"),
        ("html", "HTML"), ("css", "CSS"), ("js", "JavaScript"), ("py", "Python"),
        ("sh", "Shell"), ("cpp", "C++"), ("svg", "SVG"), ("csv", "CSV"), ("yaml", "YAML")
    ]
    static func isKnownAction(_ action: String) -> Bool {
        entries.contains { $0.id == action } || templateFormats.contains { action == "newTemplate." + $0.id }
    }

    static let entries: [ToolMenuEntry] = [
        .init(id: "newTemplate", title: "新建文件…", group: "新建"),
        .init(id: "customTemplate", title: "从自定义模板新建…", group: "新建"),
        .init(id: "newFolder", title: "新建文件夹…", group: "新建"),
        .init(id: "folderFromName", title: "按文件名建立文件夹", group: "新建"),
        .init(id: "copyTo", title: "复制到…", group: "文件"),
        .init(id: "moveTo", title: "移动到…", group: "文件"),
        .init(id: "cut", title: "剪切", group: "文件"),
        .init(id: "pasteCut", title: "粘贴剪切项目", group: "文件"),
        .init(id: "cancelCut", title: "取消剪切", group: "文件"),
        .init(id: "paths", title: "复制路径", group: "文件"),
        .init(id: "names", title: "复制文件名", group: "文件"),
        .init(id: "rename", title: "批量重命名…", group: "文件"),
        .init(id: "desktopAlias", title: "发送快捷方式到桌面", group: "文件"),
        .init(id: "airdrop", title: "隔空投送…", group: "文件"),
        .init(id: "deletePermanent", title: "彻底删除…", group: "文件"),
        .init(id: "favorites", title: "常用目录…", group: "打开"),
        .init(id: "terminal", title: "在终端打开…", group: "打开"),
        .init(id: "openWith", title: "使用应用打开…", group: "打开"),
        .init(id: "hide", title: "隐藏选中项目", group: "显示"),
        .init(id: "unhide", title: "取消隐藏选中项目", group: "显示"),
        .init(id: "hideAll", title: "隐藏目录内所有项目", group: "显示"),
        .init(id: "unhideAll", title: "取消隐藏目录内所有项目", group: "显示"),
        .init(id: "iconSet", title: "设置文件图标…", group: "图像"),
        .init(id: "iconClear", title: "恢复文件图标", group: "图像"),
        .init(id: "convertImage", title: "转换图片格式…", group: "图像"),
        .init(id: "iconSetExport", title: "导出应用图标组…", group: "图像"),
        .init(id: "edit", title: "图片标注 / OCR", group: "图像"),
        .init(id: "pin", title: "图片贴图", group: "图像"),
        .init(id: "hashMD5", title: "MD5", group: "文件信息"),
        .init(id: "hashSHA1", title: "SHA-1", group: "文件信息"),
        .init(id: "hashSHA256", title: "SHA-256", group: "文件信息"),
        .init(id: "hashSHA512", title: "SHA-512", group: "文件信息"),
        .init(id: "capture", title: "区域截图", group: "捕捉"),
        .init(id: "captureFull", title: "全屏截图", group: "捕捉"),
        .init(id: "captureScroll", title: "长截图", group: "捕捉"),
        .init(id: "record", title: "录屏…", group: "捕捉"),
        .init(id: "qr", title: "文字转二维码…", group: "文字"),
        .init(id: "translateGoogle", title: "Google 翻译…", group: "文字"),
        .init(id: "translateBaidu", title: "百度翻译…", group: "文字")
    ]
    static func orderedEntries(defaults: UserDefaults = .standard) -> [ToolMenuEntry] {
        ToolMenuConfiguration.load(defaults: defaults).visibleEntries
    }
}

struct ToolMenuConfiguration {
    private(set) var order: [String]
    private(set) var hidden: Set<String>

    init(order: [String] = [], hidden: [String] = []) {
        let catalogOrder = ToolMenuCatalog.entries.map(\.id)
        let known = Set(catalogOrder)
        var seen = Set<String>()
        self.order = (order + catalogOrder).filter { known.contains($0) && seen.insert($0).inserted }
        self.hidden = Set(hidden).intersection(known)
    }

    var orderedEntries: [ToolMenuEntry] {
        order.compactMap { id in ToolMenuCatalog.entries.first { $0.id == id } }
    }

    var visibleEntries: [ToolMenuEntry] {
        orderedEntries.filter { !hidden.contains($0.id) }
    }

    mutating func toggleVisibility(_ id: String) -> Bool {
        guard order.contains(id) else { return false }
        if hidden.remove(id) == nil { hidden.insert(id) }
        return true
    }

    mutating func move(_ id: String, by offset: Int) -> Bool {
        guard offset == -1 || offset == 1, let index = order.firstIndex(of: id) else { return false }
        let destination = index + offset
        guard order.indices.contains(destination) else { return false }
        order.swapAt(index, destination)
        return true
    }

    static func load(defaults: UserDefaults = .standard) -> ToolMenuConfiguration {
        ToolMenuConfiguration(
            order: defaults.stringArray(forKey: "menuOrder") ?? [],
            hidden: defaults.stringArray(forKey: "menuHidden") ?? []
        )
    }

    func save(defaults: UserDefaults = .standard) {
        defaults.set(order, forKey: "menuOrder")
        defaults.set(hidden.sorted(), forKey: "menuHidden")
    }
}
