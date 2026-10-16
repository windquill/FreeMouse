import Testing
@testable import FreeMouse

@Suite
struct MenuConfigurationTests {
    private var defaultIDs: [String] { ToolMenuCatalog.entries.map(\.id) }

    @Test func defaultsExposeEveryKnownItemInCatalogOrder() {
        let configuration = ToolMenuConfiguration()
        #expect(configuration.order == defaultIDs)
        #expect(configuration.visibleEntries.map(\.id) == defaultIDs)
        #expect(configuration.hidden.isEmpty)
    }

    @Test func partialDuplicateAndUnknownSettingsAreNormalized() {
        let configuration = ToolMenuConfiguration(
            order: ["paths", "unknown", "cut", "paths"],
            hidden: ["rename", "unknown"]
        )
        let expected = ["paths", "cut"] + defaultIDs.filter { !["paths", "cut"].contains($0) }
        #expect(configuration.order == expected)
        #expect(configuration.hidden == Set(["rename"]))
        #expect(configuration.orderedEntries.map(\.id) == expected)
    }

    @Test func visibilityCanBeToggledWithoutLosingOrder() {
        var configuration = ToolMenuConfiguration(order: ["paths", "cut"])
        let original = configuration.order
        let didHide = configuration.toggleVisibility("paths")
        #expect(didHide)
        #expect(!configuration.visibleEntries.contains { $0.id == "paths" })
        let didShow = configuration.toggleVisibility("paths")
        #expect(didShow)
        #expect(configuration.order == original)
        #expect(configuration.visibleEntries.map(\.id) == original)
    }

    @Test func movingUpAndDownPreservesEveryItemExactlyOnce() {
        var configuration = ToolMenuConfiguration(order: ["paths", "cut", "rename"])
        let didMoveUp = configuration.move("cut", by: -1)
        #expect(didMoveUp)
        #expect(Array(configuration.order.prefix(3)) == ["cut", "paths", "rename"])
        let didMoveDown = configuration.move("cut", by: 1)
        #expect(didMoveDown)
        #expect(Array(configuration.order.prefix(3)) == ["paths", "cut", "rename"])
        #expect(configuration.order.count == defaultIDs.count)
        #expect(Set(configuration.order) == Set(defaultIDs))
    }

    @Test func invalidMovesAndUnknownVisibilityChangesDoNotMutateConfiguration() {
        var configuration = ToolMenuConfiguration(hidden: ["rename"])
        let original = configuration.order
        let originalHidden = configuration.hidden
        let results = [
            configuration.move(defaultIDs[0], by: -1),
            configuration.move(defaultIDs[defaultIDs.count - 1], by: 1),
            configuration.move("unknown", by: 1),
            configuration.move("paths", by: 0),
            configuration.move("paths", by: Int.max),
            configuration.toggleVisibility("unknown")
        ]
        #expect(results.allSatisfy { !$0 })
        #expect(configuration.order == original)
        #expect(configuration.hidden == originalHidden)
    }

    @Test func hiddenItemsRetainTheirChosenPositionWhenShownAgain() {
        var configuration = ToolMenuConfiguration(order: ["paths", "cut", "rename"], hidden: ["cut"])
        let didMove = configuration.move("cut", by: 1)
        #expect(didMove)
        #expect(Array(configuration.visibleEntries.prefix(2)).map(\.id) == ["paths", "rename"])
        let didShow = configuration.toggleVisibility("cut")
        #expect(didShow)
        #expect(Array(configuration.visibleEntries.prefix(3)).map(\.id) == ["paths", "rename", "cut"])
    }

    @Test func hidingAllItemsStillKeepsARecoverableCompleteConfiguration() {
        var configuration = ToolMenuConfiguration(hidden: defaultIDs)
        #expect(configuration.visibleEntries.isEmpty)
        #expect(configuration.order == defaultIDs)
        let didShow = configuration.toggleVisibility("paths")
        #expect(didShow)
        #expect(configuration.visibleEntries.map(\.id) == ["paths"])
    }

    @Test func restoredConfigurationPreservesOrderAndVisibilityEdits() {
        var configuration = ToolMenuConfiguration(order: ["paths", "cut"], hidden: ["hashSHA256"])
        let didMove = configuration.move("cut", by: -1)
        let didHide = configuration.toggleVisibility("names")
        #expect(didMove)
        #expect(didHide)
        let restored = ToolMenuConfiguration(order: configuration.order, hidden: Array(configuration.hidden))
        #expect(restored.order == configuration.order)
        #expect(restored.hidden == configuration.hidden)
        #expect(restored.visibleEntries.map(\.id) == configuration.visibleEntries.map(\.id))
    }
}
