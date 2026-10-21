import Foundation
import CArchiveBridge

enum ArchiveStreamService {
    static let identifiers: Set<String> = ["gz", "bz2", "xz", "lzma", "zst", "lz4"]
    static func supports(formatID: String) -> Bool {
        let codec = formatID.hasPrefix("tar.") ? String(formatID.dropFirst(4)) : formatID
        return identifiers.contains(codec) && codec.withCString { fm_stream_available($0) != 0 }
    }
    static func handles(formatID: String) -> Bool {
        identifiers.contains(formatID) || formatID == "tar.zst" || formatID == "tar.lz4"
    }
    static func compress(_ sources: [URL], format: ArchiveFormat, destination: URL) throws {
        if format.id.hasPrefix("tar.") {
            let intermediate = destination.deletingLastPathComponent().appendingPathComponent("intermediate-\(UUID().uuidString).tar")
            defer { try? FileManager.default.removeItem(at: intermediate) }
            guard let tar = ArchiveFormat.available.first(where: { $0.id == "tar" }) else {
                throw ArchiveService.Failure(message: "TAR 引擎不可用")
            }
            try ArchiveService.compress(sources, format: tar, destination: intermediate)
            try convert(String(format.id.dropFirst(4)), source: intermediate, destination: destination, decode: false)
        } else {
            guard sources.count == 1 else { throw ArchiveService.Failure(message: "单文件压缩流只支持一个普通文件，请选择 TAR 组合格式以压缩多个文件") }
            let values = try sources[0].resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true && values.isSymbolicLink != true else {
                throw ArchiveService.Failure(message: "单文件压缩流不支持目录或符号链接，请选择 TAR 组合格式")
            }
            try convert(format.id, source: sources[0], destination: destination, decode: false)
        }
    }
    static func extract(_ source: URL, destination: URL) throws -> Bool {
        let name = source.lastPathComponent.lowercased()
        guard let codec = identifiers.first(where: { name.hasSuffix("." + $0) }) else { return false }
        let isArchive = name.hasSuffix(".tar." + codec) || name.hasSuffix(".cpio." + codec)
        // Existing libarchive handles ordinary TAR filters and preserves all metadata.
        if isArchive && codec != "zst" && codec != "lz4" { return false }
        let intermediate = destination.deletingLastPathComponent().appendingPathComponent("decoded-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: intermediate) }
        if isArchive {
            try convert(codec, source: source, destination: intermediate, decode: true)
            try ArchiveService.nativeExtract(intermediate, into: destination)
        } else {
            let basename = source.deletingPathExtension().lastPathComponent
            guard !basename.isEmpty, basename != ".", basename != ".." else { throw ArchiveService.Failure(message: "压缩流文件名无效") }
            try convert(codec, source: source, destination: destination.appendingPathComponent(basename), decode: true)
        }
        return true
    }
    private static func convert(_ codec: String, source: URL, destination: URL, decode: Bool) throws {
        var error = [CChar](repeating: 0, count: 2048)
        let result = codec.withCString { id in
            source.path.withCString { input in
                destination.path.withCString { output in
                    if decode { return fm_stream_decompress(id, input, output, &error, error.count) }
                    return fm_stream_compress(id, input, output, &error, error.count)
                }
            }
        }
        guard result == 0 else {
            let detail = error.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            throw ArchiveService.Failure(message: detail)
        }
    }
}
