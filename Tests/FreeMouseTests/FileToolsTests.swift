import Testing
import Foundation
@testable import FreeMouse

struct FileToolsTests {
    @Test func testStackBudgetCheckedBeforeImageDecode() throws {
        #expect(throws: (any Error).self) { try FileTools.stackDimensions([CGSize(width: 5000, height: 8000), CGSize(width: 5000, height: 8000)]) }
        #expect(throws: (any Error).self) { try FileTools.stackDimensions([CGSize(width: CGFloat.infinity, height: 2)]) }
        let plan = try FileTools.stackDimensions([CGSize(width: 100, height: 200), CGSize(width: 200, height: 100)])
        #expect(plan.width == 200)
        #expect(plan.heights == [400, 100])
    }
    @Test func testCreatesWithoutReplacingExistingFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try FileTools.createFile(in: dir, name: "笔记.txt", contents: "original")
        let second = try FileTools.createFile(in: dir, name: "笔记.txt", contents: "new")
        #expect(first.lastPathComponent == "笔记.txt")
        #expect(second.lastPathComponent == "笔记 2.txt")
        #expect(try String(contentsOf: first, encoding: .utf8) == "original")
    }
    @Test func testRejectsTraversalBeforeWriting() throws {
        #expect(throws: (any Error).self) { try FileTools.validateName("../outside.txt") }
        #expect(throws: (any Error).self) { try FileTools.validateName("..") }
        #expect(throws: (any Error).self) { try FileTools.validateName("") }
        try FileTools.validateName("中文笔记.md")
    }
    @Test func testRenamePreflightRejectsCollisionWithoutMovingInput() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = dir.appendingPathComponent("a.txt")
        let collision = dir.appendingPathComponent("x_a.txt")
        try Data("a".utf8).write(to: original)
        try Data("b".utf8).write(to: collision)
        #expect(throws: (any Error).self) { try FileTools.renamePlan([original], prefix: "x_", suffix: "") }
        #expect(try String(contentsOf: original, encoding: .utf8) == "a")
        #expect(try String(contentsOf: collision, encoding: .utf8) == "b")
    }
    @Test func testSHA256UsesActualFileBytes() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("abc".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(try FileTools.sha256(file) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}
