import Foundation
import Testing
@testable import FreeMouse

@Suite(.serialized)
struct SevenZipServiceTests {
    private func fixture() throws -> URL {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = repo.appendingPathComponent(".build/tmp/7zip-tests/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func stage(_ root: URL) throws -> URL {
        let url = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func makeArchive(_ root: URL, extension suffix: String, options: [String] = []) throws -> URL {
        let source = root.appendingPathComponent("hello.txt")
        try Data("synthetic fixture".utf8).write(to: source)
        let archive = root.appendingPathComponent("fixture." + suffix)
        let task = Process()
        task.executableURL = SevenZipService.helperURL
        task.arguments = ["a", "-y"] + options + [archive.path, source.path]
        task.standardOutput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice
        try task.run(); task.waitUntilExit()
        #expect(task.terminationStatus == 0)
        return archive
    }

    @Test func encrypted7zAndZipPasswordsUseStdin() throws {
        for suffix in ["7z", "zip"] {
            let root = try fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let archive = try makeArchive(root, extension: suffix, options: ["-pKnownSyntheticPassword42"])
            #expect(throws: SevenZipService.Failure.passwordRequired) {
                try SevenZipService.extract(archive, into: stage(root))
            }
            #expect(throws: SevenZipService.Failure.passwordRequired) {
                try SevenZipService.extract(archive, into: stage(root), password: "WrongSyntheticPassword")
            }
            let target = try stage(root)
            try SevenZipService.extract(archive, into: target, password: "KnownSyntheticPassword42")
            #expect(try String(contentsOf: target.appendingPathComponent("hello.txt"), encoding: .utf8) == "synthetic fixture")
        }
    }

    @Test func split7zRequiresFirstVolumeAndExtracts() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = try makeArchive(root, extension: "7z", options: ["-v64b"])
        let first = URL(fileURLWithPath: archive.path + ".001")
        let second = URL(fileURLWithPath: archive.path + ".002")
        #expect(throws: SevenZipService.Failure.firstVolumeRequired) { try SevenZipService.volumeURLs(for: second) }
        let target = try stage(root)
        try SevenZipService.extract(first, into: target)
        #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("hello.txt").path))
    }

    @Test func classicRarAndZipVolumeDiscoveryIsScoped() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["data.rar", "data.r00", "data.r01", "other.r00", "data.zip", "data.z01", "data.z02", "other.z01"] {
            try Data().write(to: root.appendingPathComponent(name))
        }
        #expect(Set(try SevenZipService.volumeURLs(for: root.appendingPathComponent("data.rar")).map(\.lastPathComponent)) == ["data.r00", "data.r01"])
        #expect(Set(try SevenZipService.volumeURLs(for: root.appendingPathComponent("data.zip")).map(\.lastPathComponent)) == ["data.z01", "data.z02"])
        #expect(throws: SevenZipService.Failure.firstVolumeRequired) {
            try SevenZipService.volumeURLs(for: root.appendingPathComponent("data.r00"))
        }
    }

    @Test func validatesLinksWithoutFollowingEscapesOrCycles() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = try stage(root)
        try Data("inside".utf8).write(to: target.appendingPathComponent("inside"))
        let link = target.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "inside")
        try SevenZipService.validate(target)
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../outside")
        #expect(throws: SevenZipService.Failure.unsafeOutput) { try SevenZipService.validate(target) }
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "link")
        #expect(throws: SevenZipService.Failure.unsafeOutput) { try SevenZipService.validate(target) }
    }

    @Test func rejectsNonemptyStage() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = try makeArchive(root, extension: "7z")
        #expect(throws: SevenZipService.Failure.unsafeOutput) { try SevenZipService.extract(archive, into: root) }
    }
    @Test func sandboxDeniesWritingOutsideStageAndReadingSiblingContents() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = try stage(root)
        let outside = root.appendingPathComponent("outside")
        let readTarget = root.appendingPathComponent("unrelated-synthetic.txt")
        try Data("synthetic private content".utf8).write(to: readTarget)
        let profile = SevenZipService.sandboxProfile(reading: [SevenZipService.helperURL], into: target)
        for arguments in [["/usr/bin/touch", outside.path], ["/usr/bin/head", readTarget.path]] {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
            task.arguments = ["-p", profile] + arguments
            task.currentDirectoryURL = target
            task.standardOutput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice
            try task.run(); task.waitUntilExit()
            #expect(task.terminationStatus != 0)
        }
        #expect(!FileManager.default.fileExists(atPath: outside.path))
    }

    @Test func hostileTarLinksAndTraversalCannotWriteOutsideStage() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        func tar(_ entries: [(String, String?, Data)]) -> Data {
            var result = Data()
            for (name, link, contents) in entries {
                var header = [UInt8](repeating: 0, count: 512)
                func field(_ value: String, _ offset: Int, _ length: Int) {
                    for (index, byte) in value.utf8.prefix(length).enumerated() { header[offset + index] = byte }
                }
                field(name, 0, 100); field("0000755", 100, 8)
                field("0000000", 108, 8); field("0000000", 116, 8)
                field(String(format: "%011o", contents.count), 124, 12)
                field("00000000000", 136, 12)
                for index in 148..<156 { header[index] = 32 }
                header[156] = link == nil ? 48 : 50
                if let link { field(link, 157, 100) }
                field("ustar", 257, 6); field("00", 263, 2)
                field(String(format: "%06o", header.reduce(0) { $0 + Int($1) }), 148, 6)
                header[154] = 0; header[155] = 32
                result.append(contentsOf: header); result.append(contents)
                result.append(Data(repeating: 0, count: (512 - contents.count % 512) % 512))
            }
            result.append(Data(repeating: 0, count: 1024))
            return result
        }
        let archive = root.appendingPathComponent("hostile.tar")
        try tar([("escape", "../outside", Data()), ("escape/payload", nil, Data("attack".utf8)), ("../outside-traversal", nil, Data("attack".utf8))]).write(to: archive)
        do { try SevenZipService.extract(archive, into: stage(root)) } catch { }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("outside").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("outside-traversal").path))
    }

}
