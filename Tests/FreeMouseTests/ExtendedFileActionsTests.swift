import Foundation
import Testing
@testable import FreeMouse

struct ExtendedFileActionsTests {
    private func temporary(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("FreeMouse-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }
    private func file(_ root: URL, _ name: String, _ value: String = "abc") throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(value.utf8).write(to: url, options: .withoutOverwriting)
        return url
    }

    @Test func hashesUseFileBytesForAllFourAlgorithms() throws {
        try temporary { root in
            let url = try file(root, "abc")
            #expect(try ExtendedFileTools.hash(url, algorithm: .md5) == "900150983cd24fb0d6963f7d28e17f72")
            #expect(try ExtendedFileTools.hash(url, algorithm: .sha1) == "a9993e364706816aba3e25717850c26c9cd0d89d")
            #expect(try ExtendedFileTools.hash(url, algorithm: .sha256) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
            #expect(try ExtendedFileTools.hash(url, algorithm: .sha512) == "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f")
        }
    }
    @Test func collisionPreflightsWholeCopyBatchWithoutWritingEarlierItems() throws {
        try temporary { root in
            let destination = root.appendingPathComponent("out")
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            let a = try file(root, "a"), b = try file(root, "b")
            let existing = try file(destination, "b", "existing")
            #expect(throws: (any Error).self) { try ExtendedFileTools.copy([a, b], to: destination) }
            #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("a").path))
            #expect(try String(contentsOf: existing, encoding: .utf8) == "existing")
            #expect(try String(contentsOf: a, encoding: .utf8) == "abc")
        }
    }
    @Test func movingDirectoryIntoDescendantThroughSymlinkIsRejected() throws {
        try temporary { root in
            let directory = root.appendingPathComponent("parent"), child = directory.appendingPathComponent("child")
            try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
            let link = root.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: child)
            #expect(throws: (any Error).self) { try ExtendedFileTools.move([directory], to: link) }
            #expect(FileManager.default.fileExists(atPath: child.path))
        }
    }
    @Test func danglingDestinationSymlinkIsNeverOverwritten() throws {
        try temporary { root in
            let destination = root.appendingPathComponent("out")
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            let source = try file(root, "item")
            let target = destination.appendingPathComponent("item")
            try FileManager.default.createSymbolicLink(atPath: target.path, withDestinationPath: root.appendingPathComponent("missing").path)
            #expect(throws: (any Error).self) { try ExtendedFileTools.move([source], to: destination) }
            #expect(FileManager.default.fileExists(atPath: source.path))
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: target.path) == root.appendingPathComponent("missing").path)
        }
    }
    @Test func copyThenMovePreservesBytesAndRemovesOnlyMovedSource() throws {
        try temporary { root in
            let destination = root.appendingPathComponent("out")
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            let a = try file(root, "a", "first"), b = try file(root, "b", "second")
            let copied = try ExtendedFileTools.copy([a], to: destination)
            let moved = try ExtendedFileTools.move([b], to: destination)
            #expect(try String(contentsOf: #require(copied.first), encoding: .utf8) == "first")
            #expect(try String(contentsOf: #require(moved.first), encoding: .utf8) == "second")
            #expect(FileManager.default.fileExists(atPath: a.path))
            #expect(!FileManager.default.fileExists(atPath: b.path))
        }
    }
    @Test func folderFromNamePreflightsSameStemCollisionBeforeMoving() throws {
        try temporary { root in
            let first = try file(root, "name.txt"), second = try file(root, "name.png")
            #expect(throws: (any Error).self) { try ExtendedFileTools.folderFromName([first, second]) }
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("name").path))
            #expect(FileManager.default.fileExists(atPath: first.path))
            let outputs = try ExtendedFileTools.folderFromName([first])
            let output = try #require(outputs.first)
            #expect(output.path == root.appendingPathComponent("name/name.txt").path)
            #expect(try String(contentsOf: output, encoding: .utf8) == "abc")
        }
    }
    @Test func deletionRejectsRootHomeAndTheirAliasesBeforeRemovingAnyFile() throws {
        try temporary { root in
            let source = try file(root, "safe")
            #expect(throws: (any Error).self) { try ExtendedFileTools.deletePermanently([source, URL(fileURLWithPath: "/")]) }
            #expect(FileManager.default.fileExists(atPath: source.path))
            #expect(throws: (any Error).self) { try ExtendedFileTools.validatePermanentDeletion([FileManager.default.homeDirectoryForCurrentUser]) }
            let link = root.appendingPathComponent("home-alias")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: FileManager.default.homeDirectoryForCurrentUser)
            #expect(throws: (any Error).self) { try ExtendedFileTools.validatePermanentDeletion([link]) }
            try ExtendedFileTools.deletePermanently([source])
            #expect(!FileManager.default.fileExists(atPath: source.path))
        }
    }
    @Test func unhideAllLeavesDotNamesUntouchedAndDoesNotRecurse() throws {
        try temporary { root in
            _ = try file(root, "visible")
            let dot = try file(root, ".dot")
            let child = root.appendingPathComponent("child")
            try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
            let nested = try file(child, "nested")
            let urls = try ExtendedFileTools.directoryItems([root], unhiding: true)
            #expect(Set(urls.map(\.lastPathComponent)) == ["visible", "child"])
            #expect(!urls.map(\.lastPathComponent).contains(dot.lastPathComponent))
            #expect(!urls.map(\.lastPathComponent).contains(nested.lastPathComponent))
        }
    }
    @Test func hiddenCutJournalsBeforeMutationAndRestoresAfterInterruption() throws {
        try temporary { root in
            let url = try file(root, "visible"), journal = root.appendingPathComponent("journal.json")
            let cut = try ExtendedCutSession(urls: [url], hide: true, journalURL: journal)
            #expect(FileManager.default.fileExists(atPath: journal.path))
            #expect(try ExtendedFileTools.hiddenStates([url]) == [true])
            #expect(try ExtendedFileTools.recoverCutJournal(at: journal) == 1)
            #expect(try ExtendedFileTools.hiddenStates([url]) == [false])
            #expect(!FileManager.default.fileExists(atPath: journal.path))
            try cut.restore()
        }
    }
    @Test func nonHiddenCutDoesNotWriteJournalOrChangeFile() throws {
        try temporary { root in
            let url = try file(root, "visible"), journal = root.appendingPathComponent("journal.json")
            let cut = try ExtendedCutSession(urls: [url], hide: false, journalURL: journal)
            #expect(!FileManager.default.fileExists(atPath: journal.path))
            #expect(try ExtendedFileTools.hiddenStates([url]) == [false])
            #expect(try String(contentsOf: url, encoding: .utf8) == "abc")
            try cut.restore()
        }
    }
    @Test func cutNeverMovesAReplacementAtTheOriginalPath() throws {
        try temporary { root in
            let source = try file(root, "source"), replacement = try file(root, "replacement", "new data")
            let cut = try ExtendedCutSession(urls: [source], hide: false, journalURL: root.appendingPathComponent("journal.json"))
            let destination = root.appendingPathComponent("out")
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            try FileManager.default.removeItem(at: source)
            try FileManager.default.moveItem(at: replacement, to: source)
            #expect(throws: (any Error).self) { try cut.move(to: destination) }
            #expect(try String(contentsOf: source, encoding: .utf8) == "new data")
            #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        }
    }
    @Test func recoveryKeepsJournalAndLeavesReplacementFileUntouched() throws {
        try temporary { root in
            let source = try file(root, "source"), replacement = try file(root, "replacement", "new data")
            let journal = root.appendingPathComponent("journal.json")
            let cut = try ExtendedCutSession(urls: [source], hide: true, journalURL: journal)
            try FileManager.default.removeItem(at: source)
            try FileManager.default.moveItem(at: replacement, to: source)
            #expect(throws: (any Error).self) { try ExtendedFileTools.recoverCutJournal(at: journal) }
            #expect(FileManager.default.fileExists(atPath: journal.path))
            #expect(try ExtendedFileTools.hiddenStates([source]) == [false])
            #expect(try String(contentsOf: source, encoding: .utf8) == "new data")
            #expect(throws: (any Error).self) { try cut.restore() }
        }
    }
    @Test func aliasesAreActualFinderBookmarksAndNeverOverwrite() throws {
        try temporary { root in
            let source = try file(root, "source")
            let out = root.appendingPathComponent("out")
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: false)
            let alias = try #require(ExtendedFileTools.createAliases([source], in: out).first)
            #expect(try alias.resourceValues(forKeys: [.isAliasFileKey]).isAliasFile == true)
            let resolved = try URL(resolvingAliasFileAt: alias, options: [.withoutUI, .withoutMounting])
            #expect(resolved.lastPathComponent == "source")
            #expect(try String(contentsOf: resolved, encoding: .utf8) == "abc")
            let before = try Data(contentsOf: alias)
            #expect(throws: (any Error).self) { try ExtendedFileTools.createAliases([source], in: out) }
            #expect(try Data(contentsOf: alias) == before)
        }
    }
    @Test func systemDirectoryAliasesCannotBypassDeletionProtection() throws {
        for path in ["/etc", "/private/etc", "/var", "/private/var"] {
            #expect(throws: (any Error).self) { try ExtendedFileTools.validatePermanentDeletion([URL(fileURLWithPath: path)]) }
        }
    }
}
