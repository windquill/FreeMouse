// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "FreeMouse", platforms: [.macOS("15.0")],
    products: [.executable(name: "FreeMouse", targets: ["FreeMouse"])],
    targets: [
        .target(name: "CZstd", path: "ThirdParty/zstd/lib", sources: ["common", "compress", "decompress"], publicHeadersPath: ".",
                cSettings: [.define("ZSTD_DISABLE_ASM"), .headerSearchPath("common")]),
        .target(name: "CLZ4", path: "ThirdParty/lz4/lib", sources: ["lz4.c", "lz4hc.c", "lz4frame.c", "xxhash.c"], publicHeadersPath: "."),
        .target(name: "CArchiveBridge", dependencies: ["CZstd", "CLZ4"], path: "Sources/CArchiveBridge", publicHeadersPath: "include",
                cSettings: [.headerSearchPath("../../ThirdParty/libarchive")],
                linkerSettings: [.linkedLibrary("archive.2")]),
        .executableTarget(name: "FreeMouse", dependencies: ["CArchiveBridge"]),
        .testTarget(name: "FreeMouseTests", dependencies: ["FreeMouse"], resources: [.copy("Fixtures/ScrollNative121"), .copy("Fixtures/ArchiveStreams")])
    ])
