import Testing
import Foundation
@testable import FreeMouse

@Suite struct ArchiveStreamTests {
    private func workspace(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    @Test func externalLZ4FourMiBBlockDrainsBufferedOutput() throws {
        try workspace { root in
            // Generated with official LZ4F_compressFrame, max4MB block size,
            // content size and content checksum enabled; payload is 4 MiB of A.
            let fixture = try #require(Bundle.module.url(forResource: "block4m", withExtension: "lz4", subdirectory: "ArchiveStreams"))
            let archive = root.appendingPathComponent("large-block.lz4")
            try FileManager.default.copyItem(at: fixture, to: archive)
            let destination = root.appendingPathComponent("out")
            try ArchiveService.extract(archive, destination: destination)
            #expect(try Data(contentsOf: destination.appendingPathComponent("large-block")) == Data(repeating: 65, count: 4 * 1024 * 1024))
        }
    }

    @Test func rawStreamsRoundTripEmptyAndLargeFilesAndRefuseOverwrite() throws {
        try workspace { root in
            for format in ArchiveFormat.available.filter({ ArchiveStreamService.identifiers.contains($0.id) }) {
                for payload in [Data(), Data((0..<300_000).map { UInt8($0 % 251) }), Data(repeating: 65, count: 2_000_000)] {
                    let token = UUID().uuidString
                    let source = root.appendingPathComponent(token)
                    try payload.write(to: source)
                    let archive = root.appendingPathComponent(token + "." + format.fileExtension)
                    try ArchiveService.compress([source], format: format, destination: archive)
                    let original = try Data(contentsOf: archive)
                    #expect(throws: (any Error).self) { try ArchiveService.compress([source], format: format, destination: archive) }
                    #expect(try Data(contentsOf: archive) == original)
                    let output = root.appendingPathComponent("out-" + token)
                    try ArchiveService.extract(archive, destination: output)
                    #expect(try Data(contentsOf: output.appendingPathComponent(token)) == payload)
                    #expect(throws: (any Error).self) { try ArchiveService.extract(archive, destination: output) }
                    try original.prefix(original.count / 2).write(to: archive)
                    let damagedOutput = root.appendingPathComponent("damaged-" + token)
                    #expect(throws: (any Error).self) { try ArchiveService.extract(archive, destination: damagedOutput) }
                    #expect(!FileManager.default.fileExists(atPath: damagedOutput.path))
                }
            }
        }
    }

    @Test func rawStreamsRejectDirectoriesMultipleSourcesAndTruncation() throws {
        try workspace { root in
            let source = root.appendingPathComponent("source")
            try Data(repeating: 65, count: 100_000).write(to: source)
            for format in ArchiveFormat.available.filter({ ArchiveStreamService.identifiers.contains($0.id) }) {
                let archive = root.appendingPathComponent("data." + format.fileExtension)
                #expect(throws: (any Error).self) { try ArchiveService.compress([source, source], format: format, destination: archive) }
                #expect(throws: (any Error).self) { try ArchiveService.compress([root], format: format, destination: archive) }
                try ArchiveService.compress([source], format: format, destination: archive)
                let contents = try Data(contentsOf: archive)
                try contents.prefix(contents.count / 2).write(to: archive)
                let output = root.appendingPathComponent("bad-" + format.id)
                #expect(throws: (any Error).self) { try ArchiveService.extract(archive, destination: output) }
                #expect(!FileManager.default.fileExists(atPath: output.path))
            }
        }
    }

    @Test func tarModernStreamsPreserveDirectoriesAndFilterMetadata() throws {
        try workspace { root in
            let source = root.appendingPathComponent("资料")
            try FileManager.default.createDirectory(at: source.appendingPathComponent("空目录"), withIntermediateDirectories: true)
            for name in ["正文.txt", ".DS_Store", "._正文.txt"] {
                try Data("hello".utf8).write(to: source.appendingPathComponent(name))
            }
            for id in ["tar.zst", "tar.lz4"] {
                let format = try #require(ArchiveFormat.available.first { $0.id == id })
                let archive = root.appendingPathComponent("data." + id)
                try ArchiveService.compress([source], format: format, destination: archive)
                let output = root.appendingPathComponent("out-" + id)
                try ArchiveService.extract(archive, destination: output)
                let restored = output.appendingPathComponent("资料")
                #expect(try Data(contentsOf: restored.appendingPathComponent("正文.txt")) == Data("hello".utf8))
                #expect(FileManager.default.fileExists(atPath: restored.appendingPathComponent("空目录").path))
                #expect(!FileManager.default.fileExists(atPath: restored.appendingPathComponent(".DS_Store").path))
                #expect(!FileManager.default.fileExists(atPath: restored.appendingPathComponent("._正文.txt").path))
            }
        }
    }
}
