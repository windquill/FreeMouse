import Foundation
import Testing
@testable import FreeMouse

struct ArchiveDestinationTests {
    @Test func compoundSuffixesHaveUsefulOutputDirectoryNames() {
        #expect(ArchiveDestination.extractionName("项目.tar.gz") == "项目")
        #expect(ArchiveDestination.extractionName("package.TAR.BZ2") == "package")
        #expect(ArchiveDestination.extractionName("backup.tgz") == "backup")
        #expect(ArchiveDestination.extractionName("data.7z") == "data")
        #expect(ArchiveDestination.extractionName(".zip") == "Archive")
        #expect(ArchiveDestination.extractionName("data.7z.001") == "data")
        #expect(ArchiveDestination.extractionName("data.part01.rar") == "data")
    }
    @Test func existingOutputGetsNumberedAndNeverOverwritten() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("original".utf8).write(to: folder.appendingPathComponent("sample.tar.gz"))
        let next = try ArchiveDestination.uniqueURL(in: folder, base: "sample", suffix: "tar.gz")
        #expect(next.lastPathComponent == "sample (2).tar.gz")
        #expect(try String(contentsOf: folder.appendingPathComponent("sample.tar.gz"), encoding: .utf8) == "original")
    }
}
