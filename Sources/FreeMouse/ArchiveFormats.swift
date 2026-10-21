import Foundation
import CArchiveBridge

struct ArchiveFormat: Identifiable, Sendable, Equatable {
    let id: String
    let title: String
    let fileExtension: String

    static let all: [ArchiveFormat] = [
        .init(id: "zip", title: "ZIP (.zip)", fileExtension: "zip"),
        .init(id: "7z", title: "7-Zip (.7z)", fileExtension: "7z"),
        .init(id: "tar", title: "TAR (.tar)", fileExtension: "tar"),
        .init(id: "tar.gz", title: "TAR + Gzip (.tar.gz)", fileExtension: "tar.gz"),
        .init(id: "tar.bz2", title: "TAR + Bzip2 (.tar.bz2)", fileExtension: "tar.bz2"),
        .init(id: "tar.xz", title: "TAR + XZ (.tar.xz)", fileExtension: "tar.xz"),
        .init(id: "tar.lzma", title: "TAR + LZMA (.tar.lzma)", fileExtension: "tar.lzma"),
        .init(id: "tar.zst", title: "TAR + Zstandard (.tar.zst)", fileExtension: "tar.zst"),
        .init(id: "tar.lz4", title: "TAR + LZ4 (.tar.lz4)", fileExtension: "tar.lz4"),
        .init(id: "tar.Z", title: "TAR + Compress (.tar.Z)", fileExtension: "tar.Z"),
        .init(id: "cpio", title: "CPIO (.cpio)", fileExtension: "cpio"),
        .init(id: "cpio.gz", title: "CPIO + Gzip (.cpio.gz)", fileExtension: "cpio.gz"),
        .init(id: "xar", title: "XAR (.xar)", fileExtension: "xar"),
        .init(id: "gz", title: "Gzip (.gz，单文件)", fileExtension: "gz"),
        .init(id: "bz2", title: "Bzip2 (.bz2，单文件)", fileExtension: "bz2"),
        .init(id: "xz", title: "XZ (.xz，单文件)", fileExtension: "xz"),
        .init(id: "lzma", title: "LZMA (.lzma，单文件)", fileExtension: "lzma"),
        .init(id: "zst", title: "Zstandard (.zst，单文件)", fileExtension: "zst"),
        .init(id: "lz4", title: "LZ4 (.lz4，单文件)", fileExtension: "lz4")
    ]

    static let available: [ArchiveFormat] = all.filter { format in
        format.id.withCString { fm_archive_available($0) != 0 }
            || (format.id.hasPrefix("tar.") ? String(format.id.dropFirst(4)) : format.id)
                .withCString { fm_stream_available($0) != 0 }
    }
}
