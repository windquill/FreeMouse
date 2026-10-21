import AppKit
import Testing
@testable import FreeMouse

@Suite("Archive menus")
@MainActor
struct ArchiveMenuTests {
    @Test func extractIsDirectAndCompressionUsesAvailableFormats() throws {
        let hidden = ToolMenuCatalog.entries.map(\.id).filter { !["extract", "compress"].contains($0) }
        let target = ArchiveMenuTarget()
        let selector = #selector(ArchiveMenuTarget.performTool(_:))
        let menu = FinderMenuBuilder.makeMenu(loadConfiguration: {
            ToolMenuConfiguration(order: ["extract", "compress"], hidden: hidden)
        }, target: target, action: selector)
        #expect(menu.items.map(\.tag) == [1040, 1041, 0, 9001])
        let extract = try #require(menu.items.first)
        #expect(extract.title == "解压到同名文件夹")
        #expect(extract.submenu == nil)
        #expect(extract.action == selector)
        let compress = try #require(menu.items.first { $0.tag == 1041 })
        #expect(compress.title == "压缩")
        // AppKit assigns submenuAction: when a submenu is attached.
        #expect(compress.action != selector)
        let submenu = try #require(compress.submenu)
        #expect(submenu.items.map(\.title) == ArchiveFormat.available.map(\.title))
        #expect(submenu.items.map(\.tag) == ArchiveFormat.available.compactMap {
            FinderMenuActionRegistry.tag(for: "compress." + $0.id)
        })
        #expect(submenu.items.allSatisfy { $0.target === target && $0.action == selector })
    }

    @Test func archiveActionsHavePermanentTagsEvenWhenUnavailable() throws {
        let ids = ["zip", "7z", "tar", "tar.gz", "tar.bz2", "tar.xz", "tar.lzma", "tar.zst", "tar.lz4", "tar.Z", "cpio", "cpio.gz", "xar", "gz", "bz2", "xz", "lzma", "zst", "lz4"]
        for (index, id) in ids.enumerated() {
            let action = "compress." + id
            #expect(ToolMenuCatalog.isKnownAction(action))
            #expect(FinderMenuActionRegistry.tag(for: action) == 3001 + index)
            #expect(FinderMenuActionRegistry.action(for: 3001 + index) == action)
        }
        #expect(FinderMenuActionRegistry.tag(for: "extract") == 1040)
        #expect(FinderMenuActionRegistry.tag(for: "compress") == 1041)
        #expect(!ToolMenuCatalog.isKnownAction("compress.rar"))
        #expect(!ToolMenuCatalog.isKnownAction("compress."))
    }

    @Test func oldSnapshotAddsArchiveEntriesWithoutChangingSavedPreferences() throws {
        let oldIDs = ToolMenuCatalog.entries.map(\.id).filter { !["extract", "compress"].contains($0) }
        let order = ["paths"] + oldIDs.filter { $0 != "paths" }
        let data = try PropertyListEncoder().encode(FinderMenuSnapshot(schema: 1, order: order, hidden: ["cut", "rename"]))
        let store = FinderMenuStore(readValue: { data }, writeValue: { _ in })
        let migrated = try store.migrateIfNeeded { ToolMenuConfiguration() }
        #expect(migrated.order == order + ["extract", "compress"])
        #expect(migrated.hidden == ["cut", "rename"])
        #expect(migrated.visibleEntries.suffix(2).map(\.id) == ["extract", "compress"])
    }
}

private final class ArchiveMenuTarget: NSObject {
    @objc func performTool(_ sender: NSMenuItem) {}
}
