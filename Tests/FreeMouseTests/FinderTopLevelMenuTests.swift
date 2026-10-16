import AppKit
import Testing
@testable import FreeMouse

@Suite("Finder first-level menu")
@MainActor
struct FinderTopLevelMenuTests {
    // Catches reintroducing the outer toolbox submenu, ignoring the saved
    // visibility/order, or losing the fixed action identity during flattening.
    @Test func visibleSnapshotActionsAppearDirectlyInSavedOrder() throws {
        let hidden = ToolMenuCatalog.entries.map(\.id).filter {
            !["newFolder", "paths", "newTemplate"].contains($0)
        }
        let configuration = ToolMenuConfiguration(order: ["newFolder", "paths", "newTemplate"], hidden: hidden)
        let snapshot = try FinderMenuSnapshot.encode(configuration)
        let store = FinderMenuStore(readValue: { snapshot }, writeValue: { _ in })
        let target = FinderMenuTestTarget()
        let menu = FinderMenuBuilder.makeMenu(loadConfiguration: store.load, target: target,
                                             action: #selector(FinderMenuTestTarget.performTool(_:)))

        #expect(menu.items.map(\.tag) == [1003, 1010, 1001, 0, 9001])
        #expect(menu.items.map(\.title) == ["新建文件夹…", "复制路径", "新建文件…", "", "设置右键菜单…"])
        #expect(!menu.autoenablesItems)
        let pathItem = try #require(menu.items.first { $0.tag == 1010 })
        #expect(pathItem.submenu == nil)
        #expect(pathItem.target === target)
        #expect(pathItem.action == #selector(FinderMenuTestTarget.performTool(_:)))
        let settings = try #require(menu.items.last)
        #expect(settings.target === target)
        #expect(settings.action == #selector(FinderMenuTestTarget.performTool(_:)))
    }

    // Catches flattening the format choices as well as the toolbox wrapper,
    // or replacing format identities with visible row positions.
    @Test func newFileRetainsItsFormatSubmenuAndFixedActionTags() throws {
        let hidden = ToolMenuCatalog.entries.map(\.id).filter { $0 != "newTemplate" }
        let target = FinderMenuTestTarget()
        let menu = FinderMenuBuilder.makeMenu(
            loadConfiguration: { ToolMenuConfiguration(hidden: hidden) }, target: target,
            action: #selector(FinderMenuTestTarget.performTool(_:)))

        let newFile = try #require(menu.items.first { $0.tag == 1001 })
        let formats = try #require(newFile.submenu)
        #expect(formats.items.map(\.tag) == [2001, 2002, 2003, 2004, 2005, 2006, 2007, 2008, 2009,
                                            2010, 2011, 2012, 2013, 2014, 2015, 2016, 2017])
        #expect(formats.items.first?.title == "文本 TXT")
        #expect(formats.items.last?.title == "YAML")
        #expect(formats.items.allSatisfy { $0.target === target && $0.action == #selector(FinderMenuTestTarget.performTool(_:)) })
    }

    // Catches a disappearing settings entry or an orphan separator when all
    // optional actions are hidden.
    @Test func hidingEveryActionLeavesDirectSettingsWithoutASeparator() {
        let hidden = ToolMenuCatalog.entries.map(\.id)
        let menu = FinderMenuBuilder.makeMenu(
            loadConfiguration: { ToolMenuConfiguration(hidden: hidden) }, target: FinderMenuTestTarget(),
            action: #selector(FinderMenuTestTarget.performTool(_:)))

        #expect(menu.items.map(\.tag) == [9001])
        #expect(menu.items.first?.title == "设置右键菜单…")
        #expect(menu.items.first?.submenu == nil)
    }

    // Catches error/first-run paths keeping the extra wrapper or hiding the
    // settings recovery entry while the snapshot is unavailable.
    @Test(arguments: [false, true])
    func unavailableSnapshotShowsDirectRecoveryEntries(readFails: Bool) {
        let menu = FinderMenuBuilder.makeMenu(loadConfiguration: {
            if readFails { throw FinderMenuPreferenceError.readFailed }
            return nil
        }, target: FinderMenuTestTarget(), action: #selector(FinderMenuTestTarget.performTool(_:)))

        #expect(menu.items.count == 3)
        #expect(menu.items.first?.isEnabled == false)
        #expect(menu.items.first?.submenu == nil)
        #expect(menu.items.dropFirst().first?.isSeparatorItem == true)
        #expect(menu.items.last?.tag == 9001)
        #expect(menu.items.last?.title == "设置右键菜单…")
    }
}

private final class FinderMenuTestTarget: NSObject {
    @objc func performTool(_ sender: NSMenuItem) {}
}
