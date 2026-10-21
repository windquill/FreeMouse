import Foundation
import Darwin
import CArchiveBridge

enum ArchiveService {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func compress(_ sources: [URL], format: ArchiveFormat, destination: URL) throws {
        guard !sources.isEmpty else { throw Failure(message: "请选择需要压缩的文件") }
        guard ArchiveFormat.available.contains(format) else { throw Failure(message: "本机不支持创建此归档格式") }
        let normalized = sources.map { $0.standardizedFileURL }
        guard normalized.allSatisfy(\.isFileURL), destination.isFileURL else { throw Failure(message: "归档操作仅支持本地文件") }
        let names = normalized.map(\.lastPathComponent)
        guard Set(names).count == names.count else { throw Failure(message: "所选文件存在同名项目，请分别压缩") }
        let final = destination.standardizedFileURL
        // A staging file inside an input directory would recursively archive itself.
        guard !normalized.contains(where: { final.path == $0.path || final.path.hasPrefix($0.path + "/") }) else {
            throw Failure(message: "归档目标不能位于所选源目录内")
        }
        try transaction(destination: final, directory: false) { temporary in
            if ArchiveStreamService.handles(formatID: format.id) {
                try ArchiveStreamService.compress(normalized, format: format, destination: temporary)
                return
            }
            let pointers = normalized.map { strdup($0.path) }
            defer { pointers.forEach { free($0) } }
            guard pointers.allSatisfy({ $0 != nil }) else { throw Failure(message: "归档内存分配失败") }
            let immutable = pointers.map { UnsafePointer<CChar>($0!) as UnsafePointer<CChar>? }
            var error = [CChar](repeating: 0, count: 2048)
            let result = immutable.withUnsafeBufferPointer { paths in
                format.id.withCString { identifier in
                    temporary.path.withCString { output in
                        fm_archive_compress(paths.baseAddress, paths.count, identifier, output, &error, error.count)
                    }
                }
            }
            guard result == 0 else { throw bridgeFailure(error, fallback: "压缩失败") }
        }
    }

    static func extract(_ archive: URL, destination: URL, password: String? = nil) throws {
        guard archive.isFileURL, destination.isFileURL else { throw Failure(message: "归档操作仅支持本地文件") }
        try transaction(destination: destination.standardizedFileURL, directory: true) { temporary in
            if try ArchiveStreamService.extract(archive, destination: temporary) { return }
            let name = archive.lastPathComponent.lowercased()
            let multipart = name.hasSuffix(".001") || name.range(of: #"\.part[0-9]+\.rar$"#, options: .regularExpression) != nil
            if password == nil && !multipart {
                do {
                    try nativeExtract(archive, into: temporary)
                    return
                } catch {
                    if let failure = error as? Failure,
                       ["不安全", "越界", "超过", "超出", "重名", "冲突", "内存", "层级过深"].contains(where: { failure.message.contains($0) }) {
                        throw failure
                    }
                    try FileManager.default.removeItem(at: temporary)
                    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                }
            }
            try SevenZipService.extract(archive, into: temporary, password: password)
        }
    }

    static func nativeExtract(_ archive: URL, into directory: URL) throws {
        var error = [CChar](repeating: 0, count: 2048)
        let result = archive.path.withCString { input in
            directory.path.withCString { output in
                fm_archive_extract(input, output, &error, error.count)
            }
        }
        guard result == 0 else { throw bridgeFailure(error, fallback: "解压失败") }
    }

    private static func bridgeFailure(_ buffer: [CChar], fallback: String) -> Failure {
        let detail = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        return Failure(message: detail.isEmpty ? fallback : "\(fallback)：\(detail)")
    }

    private static func transaction(destination: URL, directory: Bool, operation: (URL) throws -> Void) throws {
        let manager = FileManager.default
        let parent = destination.deletingLastPathComponent()
        let staging = parent.appendingPathComponent(".omnidesk-archive-\(UUID().uuidString)", isDirectory: true)
        do {
            try manager.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } catch { throw Failure(message: "无法在目标目录创建归档暂存空间：\(error.localizedDescription)") }
        defer { try? manager.removeItem(at: staging) }
        let temporary = staging.appendingPathComponent("payload", isDirectory: directory)
        if directory { try manager.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        try operation(temporary)
        // RENAME_EXCL is atomic for both files and directories and refuses symlinks too.
        let result = temporary.path.withCString { source in
            destination.path.withCString { target in renamex_np(source, target, UInt32(RENAME_EXCL)) }
        }
        guard result == 0 else {
            if errno == EEXIST { throw Failure(message: "目标已存在，未覆盖任何文件：\(destination.lastPathComponent)") }
            throw Failure(message: "无法发布归档结果：\(String(cString: strerror(errno)))")
        }
    }
}
