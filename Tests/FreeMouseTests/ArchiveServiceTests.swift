import Testing
import Foundation
@testable import FreeMouse

@Suite struct ArchiveServiceTests {
    private func workspace(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    @Test func testFormatsHaveStableOrder() {
        #expect(ArchiveFormat.all.map(\.id) == ["zip", "7z", "tar", "tar.gz", "tar.bz2", "tar.xz", "tar.lzma", "tar.zst", "tar.lz4", "tar.Z", "cpio", "cpio.gz", "xar", "gz", "bz2", "xz", "lzma", "zst", "lz4"])
        #expect(ArchiveFormat.available.contains { $0.id == "zip" })
    }

    @Test func testEveryAvailableFormatRoundTripsUnicodeEmptyDirectoriesAndFiltersMetadata() throws {
        try workspace { root in
            let source = root.appendingPathComponent("中文 文件夹")
            try FileManager.default.createDirectory(at: source.appendingPathComponent("空目录"), withIntermediateDirectories: true)
            for name in ["正文.txt", ".env", ".DS_Store", "._正文.txt"] {
                try Data("hello 世界".utf8).write(to: source.appendingPathComponent(name))
            }
            for name in ["__MACOSX", "__MACOS", ".AppleDouble", ".git"] {
                try FileManager.default.createDirectory(at: source.appendingPathComponent(name), withIntermediateDirectories: true)
            }
            for format in ArchiveFormat.available.filter({ !["gz", "bz2", "xz", "lzma", "zst", "lz4"].contains($0.id) }) {
                let archive = root.appendingPathComponent("test.\(format.fileExtension)")
                let destination = root.appendingPathComponent("out-\(format.id)")
                try ArchiveService.compress([source], format: format, destination: archive)
                try ArchiveService.extract(archive, destination: destination)
                let restored = destination.appendingPathComponent(source.lastPathComponent)
                #expect(try Data(contentsOf: restored.appendingPathComponent("正文.txt")) == Data("hello 世界".utf8))
                #expect(FileManager.default.fileExists(atPath: restored.appendingPathComponent("空目录").path))
                #expect(FileManager.default.fileExists(atPath: restored.appendingPathComponent(".env").path))
                #expect(FileManager.default.fileExists(atPath: restored.appendingPathComponent(".git").path))
                for name in [".DS_Store", "._正文.txt", "__MACOSX", "__MACOS", ".AppleDouble"] {
                    #expect(!(FileManager.default.fileExists(atPath: restored.appendingPathComponent(name).path)))
                }
            }
        }
    }

    @Test func testMultipleSourcesAndExclusivePublication() throws {
        try workspace { root in
            let a = root.appendingPathComponent("a.txt"), b = root.appendingPathComponent("b.txt")
            try Data("a".utf8).write(to: a)
            try Data("b".utf8).write(to: b)
            let archive = root.appendingPathComponent("test.zip")
            let format = try #require(ArchiveFormat.available.first { $0.id == "zip" })
            try ArchiveService.compress([a,b], format: format, destination: archive)
            let original = try Data(contentsOf: archive)
            #expect(throws: (any Error).self) { try ArchiveService.compress([a], format: format, destination: archive) }
            #expect(try Data(contentsOf: archive) == original)
            let output = root.appendingPathComponent("out")
            try ArchiveService.extract(archive, destination: output)
            #expect(try Data(contentsOf: output.appendingPathComponent("a.txt")) == Data("a".utf8))
            #expect(try Data(contentsOf: output.appendingPathComponent("b.txt")) == Data("b".utf8))
            #expect(throws: (any Error).self) { try ArchiveService.extract(archive, destination: output) }
        }
    }

    @Test func testMalformedArchiveLeavesNoDestination() throws {
        try workspace { root in
            let archive = root.appendingPathComponent("bad.zip"), output = root.appendingPathComponent("out")
            try Data("not an archive".utf8).write(to: archive)
            #expect(throws: (any Error).self) { try ArchiveService.extract(archive, destination: output) }
            #expect(!(FileManager.default.fileExists(atPath: output.path)))
        }
    }

    private func tarEntry(name: String, type: UInt8 = 48, link: String = "", size: Int = 0) -> Data {
        var header = [UInt8](repeating: 0, count: 512)
        func field(_ value: String, _ offset: Int, _ count: Int) {
            for (index, byte) in value.utf8.prefix(count).enumerated() { header[offset + index] = byte }
        }
        field(name, 0, 100)
        field("0000644", 100, 7)
        field("0000000", 108, 7)
        field("0000000", 116, 7)
        if size > 0o77777777777 {
            var remaining = UInt64(size)
            for index in stride(from: 135, through: 125, by: -1) {
                header[index] = UInt8(remaining & 255)
                remaining >>= 8
            }
            header[124] = 0x80
        } else {
            field(String(format: "%011llo", size), 124, 11)
        }
        field("00000000000", 136, 11)
        for i in 148..<156 { header[i] = 32 }
        header[156] = type
        field(link, 157, 100)
        field("ustar", 257, 5)
        field("00", 263, 2)
        let checksum = header.reduce(0) { $0 + Int($1) }
        field(String(format: "%06o", checksum), 148, 6)
        header[154] = 0
        header[155] = 32
        return Data(header)
    }

    @Test func testRejectsTraversalAbsoluteLinksDuplicateAndOversizedEntries() throws {
        let fixtures = [
            tarEntry(name: "../escaped.txt"),
            tarEntry(name: "/tmp/escaped.txt"),
            tarEntry(name: "link", type: 50, link: "../outside"),
            tarEntry(name: "hardlink", type: 49, link: "../outside"),
            tarEntry(name: "duplicate") + tarEntry(name: "duplicate"),
            tarEntry(name: "huge", size: 21 * 1024 * 1024 * 1024)
        ]
        try workspace { root in
            for (index, fixture) in fixtures.enumerated() {
                let archive = root.appendingPathComponent("malicious-\(index).tar")
                let output = root.appendingPathComponent("out-\(index)")
                try (fixture + Data(repeating: 0, count: 1024)).write(to: archive)
                #expect(throws: (any Error).self) { try ArchiveService.extract(archive, destination: output) }
                #expect(!(FileManager.default.fileExists(atPath: output.path)))
                #expect(!(FileManager.default.fileExists(atPath: root.appendingPathComponent("escaped.txt").path)))
            }
        }
    }

    @Test func testExtractsConventionalDotRelativeTarPaths() throws {
        try workspace { root in
            let archive = root.appendingPathComponent("relative.tar")
            let output = root.appendingPathComponent("out")
            let fixture = tarEntry(name: "./", type: 53) + tarEntry(name: "./folder//", type: 53) + tarEntry(name: "./folder/./empty.txt") + Data(repeating: 0, count: 1024)
            try fixture.write(to: archive)
            try ArchiveService.extract(archive, destination: output)
            #expect(FileManager.default.fileExists(atPath: output.appendingPathComponent("folder/empty.txt").path))
        }
    }

    @Test func testRejectsMtreeManifestAndSourceSymlinks() throws {
        try workspace { root in
            let manifest = root.appendingPathComponent("manifest.mtree")
            try Data("#mtree\nfile type=file contents=/etc/passwd\n".utf8).write(to: manifest)
            #expect(throws: (any Error).self) { try ArchiveService.extract(manifest, destination: root.appendingPathComponent("out")) }
            let source = root.appendingPathComponent("source.txt")
            try Data("ordinary".utf8).write(to: source)
            let link = root.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
            let zip = try #require(ArchiveFormat.available.first { $0.id == "zip" })
            #expect(throws: (any Error).self) { try ArchiveService.compress([link], format: zip, destination: root.appendingPathComponent("link.zip")) }
        }
    }
}
