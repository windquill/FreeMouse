import Foundation
import Testing
@testable import FreeMouse

@Suite("Finder menu integration")
struct FinderMenuIntegrationTests {
    @Test func snapshotRoundTripKeepsVisibilityAndOrder() throws {
        var configuration = ToolMenuConfiguration()
        let toggled = configuration.toggleVisibility("paths")
        let moved = configuration.move("paths", by: -1)
        #expect(toggled)
        #expect(moved)
        let decoded = try FinderMenuSnapshot.decode(FinderMenuSnapshot.encode(configuration))
        #expect(decoded.order == configuration.order)
        #expect(decoded.hidden == configuration.hidden)
        #expect(!decoded.visibleEntries.contains { $0.id == "paths" })
    }

    @Test func invalidSnapshotIsRejected() throws {
        for value: Any in [Data("bad".utf8), "not a snapshot", 7] {
            #expect(throws: (any Error).self) { try FinderMenuSnapshot.decode(value) }
        }
        let future = try PropertyListEncoder().encode(FinderMenuSnapshot(schema: 2, order: [], hidden: []))
        #expect(throws: (any Error).self) { try FinderMenuSnapshot.decode(future) }
        let malformed: [[String: Any]] = [
            ["schema": true, "order": [], "hidden": []],
            ["schema": 1, "order": ["paths", 8], "hidden": []],
            ["schema": 1, "order": [], "hidden": [true]],
            ["schema": 1, "order": []]
        ]
        for object in malformed {
            let data = try PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0)
            #expect(throws: (any Error).self) { try FinderMenuSnapshot.decode(data) }
        }
    }

    @Test func snapshotNormalizesUnknownAndDuplicateItems() throws {
        let data = try PropertyListEncoder().encode(FinderMenuSnapshot(
            schema: 1, order: ["paths", "paths", "unknown"], hidden: ["paths", "unknown", "paths"]))
        let decoded = try FinderMenuSnapshot.decode(data)
        #expect(decoded.order.first == "paths")
        #expect(decoded.order.count == ToolMenuCatalog.entries.count)
        #expect(Set(decoded.order).count == decoded.order.count)
        #expect(decoded.hidden == ["paths"])
    }

    @Test func readRefreshesEveryTimeAndDoesNotFallBack() throws {
        var data: Any? = try FinderMenuSnapshot.encode(ToolMenuConfiguration())
        var reads = 0
        let store = FinderMenuStore(readValue: { reads += 1; return data }, writeValue: { _ in })
        #expect(try store.load()?.hidden.isEmpty == true)
        var changed = ToolMenuConfiguration()
        _ = changed.toggleVisibility("paths")
        data = try FinderMenuSnapshot.encode(changed)
        #expect(try store.load()?.hidden.contains("paths") == true)
        #expect(reads == 2)
        data = "corrupt"
        #expect(throws: (any Error).self) { try store.load() }
    }

    @Test func migrationRunsOnlyWhenMissing() throws {
        var data: Any?
        var writes = 0
        var legacyReads = 0
        let store = FinderMenuStore(readValue: { data }, writeValue: { data = $0; writes += 1 })
        var legacy = ToolMenuConfiguration()
        _ = legacy.toggleVisibility("paths")
        let first = try store.migrateIfNeeded { legacyReads += 1; return legacy }
        #expect(first.hidden.contains("paths"))
        legacy = ToolMenuConfiguration()
        let second = try store.migrateIfNeeded { legacyReads += 1; return legacy }
        #expect(second.hidden.contains("paths"))
        #expect(legacyReads == 1)
        #expect(writes == 1)
    }

    @Test func malformedExistingConfigurationIsNeverOverwritten() throws {
        var writes = 0
        var legacyReads = 0
        let store = FinderMenuStore(readValue: { "corrupt" }, writeValue: { _ in writes += 1 })
        #expect(throws: (any Error).self) {
            try store.migrateIfNeeded { legacyReads += 1; return ToolMenuConfiguration() }
        }
        #expect(writes == 0)
        #expect(legacyReads == 0)
    }

    @Test func migrationRetriesAfterFailedWriteWithoutMarkingComplete() throws {
        enum Failure: Error { case expected }
        var data: Any?
        var shouldFail = true
        var writes = 0
        let store = FinderMenuStore(readValue: { data }, writeValue: {
            writes += 1
            if shouldFail { throw Failure.expected }
            data = $0
        })
        #expect(throws: Failure.self) { try store.migrateIfNeeded { ToolMenuConfiguration() } }
        #expect(data == nil)
        shouldFail = false
        _ = try store.migrateIfNeeded { ToolMenuConfiguration() }
        #expect(writes == 2)
        #expect(try store.load()?.order == ToolMenuConfiguration().order)
    }

    @Test func emptyOrderAndAllHiddenRoundTrip() throws {
        let ids = ToolMenuCatalog.entries.map(\.id)
        let configuration = ToolMenuConfiguration(order: [], hidden: ids)
        let decoded = try FinderMenuSnapshot.decode(FinderMenuSnapshot.encode(configuration))
        #expect(decoded.order == ids)
        #expect(decoded.visibleEntries.isEmpty)
        #expect(FinderMenuActionRegistry.tag(for: FinderMenuActionRegistry.settingsAction) == 9001)
    }

    @Test func savePublishesOneCompleteSnapshot() throws {
        var values: [Data] = []
        let store = FinderMenuStore(readValue: { nil }, writeValue: { values.append($0) })
        var configuration = ToolMenuConfiguration()
        _ = configuration.move("paths", by: -1)
        _ = configuration.toggleVisibility("names")
        try store.save(configuration)
        #expect(values.count == 1)
        let decoded = try FinderMenuSnapshot.decode(#require(values.first))
        #expect(decoded.order == configuration.order)
        #expect(decoded.hidden == configuration.hidden)
    }

    @Test func readAndWriteFailuresReachTheCaller() throws {
        enum Failure: Error { case expected }
        let store = FinderMenuStore(readValue: { throw Failure.expected }, writeValue: { _ in throw Failure.expected })
        #expect(throws: Failure.self) { try store.load() }
        #expect(throws: Failure.self) { try store.save(ToolMenuConfiguration()) }
        #expect(throws: Failure.self) { try store.migrateIfNeeded { ToolMenuConfiguration() } }
    }

    @Test func allActionTagsArePositiveUniqueAndReversible() throws {
        let actions = ToolMenuCatalog.entries.map(\.id)
            + ToolMenuCatalog.templateFormats.map { "newTemplate." + $0.id }
            + ArchiveFormat.all.map { "compress." + $0.id }
            + [FinderMenuActionRegistry.settingsAction]
        var tags = Set<Int>()
        for action in actions {
            let tag = try #require(FinderMenuActionRegistry.tag(for: action))
            #expect(tag > 0)
            #expect(tags.insert(tag).inserted)
            #expect(FinderMenuActionRegistry.action(for: tag) == action)
        }
        #expect(FinderMenuActionRegistry.tag(for: "paths") == 1010)
        #expect(FinderMenuActionRegistry.tag(for: "newTemplate.txt") == 2001)
        #expect(FinderMenuActionRegistry.tag(for: FinderMenuActionRegistry.settingsAction) == 9001)
    }

    @Test func tagsDoNotDependOnVisiblePosition() throws {
        let before = FinderMenuActionRegistry.tag(for: "paths")
        var configuration = ToolMenuConfiguration()
        _ = configuration.move("paths", by: -1)
        _ = configuration.toggleVisibility("paths")
        #expect(before == 1010)
        #expect(FinderMenuActionRegistry.tag(for: "paths") == before)
        #expect(FinderMenuActionRegistry.action(for: -1) == nil)
        #expect(FinderMenuActionRegistry.action(for: 0) == nil)
        #expect(FinderMenuActionRegistry.action(for: 999999) == nil)
        #expect(FinderMenuActionRegistry.tag(for: "unknown") == nil)
    }
}
