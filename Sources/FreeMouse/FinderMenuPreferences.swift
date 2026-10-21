import Foundation
import CoreFoundation

enum FinderMenuPreferenceError: LocalizedError, Equatable {
    case invalidSnapshot, readFailed, writeFailed, stateUnconfirmed

    var errorDescription: String? {
        switch self {
        case .invalidSnapshot: return "Finder 菜单配置格式无效，未覆盖已有配置。"
        case .readFailed: return "无法读取 Finder 菜单配置，请重新打开设置。"
        case .writeFailed: return "Finder 菜单配置未保存，请重试。"
        case .stateUnconfirmed: return "菜单配置保存和恢复均未确认。请重新打开设置后检查，暂时不要继续修改。"
        }
    }
}

struct FinderMenuSnapshot: Codable {
    let schema: Int
    let order: [String]
    let hidden: [String]

    static func encode(_ configuration: ToolMenuConfiguration) throws -> Data {
        let snapshot = FinderMenuSnapshot(schema: 1, order: configuration.order, hidden: configuration.hidden.sorted())
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(snapshot)
    }

    static func decode(_ value: Any) throws -> ToolMenuConfiguration {
        guard let data = value as? Data,
              let snapshot = try? PropertyListDecoder().decode(FinderMenuSnapshot.self, from: data),
              snapshot.schema == 1 else { throw FinderMenuPreferenceError.invalidSnapshot }
        return ToolMenuConfiguration(order: snapshot.order, hidden: snapshot.hidden)
    }
}

struct FinderMenuStore {
    let readValue: () throws -> Any?
    let writeValue: (Data) throws -> Void

    func load() throws -> ToolMenuConfiguration? {
        guard let value = try readValue() else { return nil }
        return try FinderMenuSnapshot.decode(value)
    }

    func save(_ configuration: ToolMenuConfiguration) throws {
        try writeValue(FinderMenuSnapshot.encode(configuration))
    }

    func migrateIfNeeded(legacy: () -> ToolMenuConfiguration) throws -> ToolMenuConfiguration {
        if let existing = try load() { return existing }
        let configuration = legacy()
        try save(configuration)
        return configuration
    }
}

enum FinderMenuPreferences {
    static let domain = "local.freemouse.toolbox.finder-menu"
    static let snapshotKey = "configuration"

    // Only the main application calls save/migrate. The Finder extension has
    // read-only access to this dedicated domain, never to general app settings.
    static let shared = FinderMenuStore(readValue: {
        guard CFPreferencesSynchronize(domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
            throw FinderMenuPreferenceError.readFailed
        }
        return CFPreferencesCopyValue(snapshotKey as CFString, domain as CFString,
                                      kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }, writeValue: { data in
        guard CFPreferencesSynchronize(domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
            throw FinderMenuPreferenceError.readFailed
        }
        let previous = CFPreferencesCopyValue(snapshotKey as CFString, domain as CFString,
                                               kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSetValue(snapshotKey as CFString, data as CFData, domain as CFString,
                              kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard CFPreferencesSynchronize(domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
            // Clear the uncommitted process cache as well as restoring the old
            // value. A failed write must not appear saved in this process.
            CFPreferencesSetValue(snapshotKey as CFString, previous, domain as CFString,
                                  kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            guard CFPreferencesSynchronize(domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
                throw FinderMenuPreferenceError.stateUnconfirmed
            }
            throw FinderMenuPreferenceError.writeFailed
        }
    })
}

enum FinderMenuActionRegistry {
    static let settingsAction = "settings.finder"

    // Persisted action identities. Never derive tags from visible/sorted rows.
    private static let actions: [(Int, String)] = [
        (1001, "newTemplate"), (1002, "customTemplate"), (1003, "newFolder"),
        (1004, "folderFromName"), (1005, "copyTo"), (1006, "moveTo"),
        (1007, "cut"), (1008, "pasteCut"), (1009, "cancelCut"), (1010, "paths"),
        (1011, "names"), (1012, "rename"), (1013, "desktopAlias"), (1014, "airdrop"),
        (1015, "deletePermanent"), (1016, "favorites"), (1017, "terminal"),
        (1018, "openWith"), (1019, "hide"), (1020, "unhide"), (1021, "hideAll"),
        (1022, "unhideAll"), (1023, "iconSet"), (1024, "iconClear"),
        (1025, "convertImage"), (1026, "iconSetExport"), (1027, "edit"),
        (1028, "pin"), (1029, "hashMD5"), (1030, "hashSHA1"),
        (1031, "hashSHA256"), (1032, "hashSHA512"), (1033, "capture"),
        (1034, "captureFull"), (1035, "captureScroll"), (1036, "record"),
        (1037, "qr"), (1038, "translateGoogle"), (1039, "translateBaidu"),
        (1040, "extract"), (1041, "compress"),
        (2001, "newTemplate.txt"), (2002, "newTemplate.rtf"), (2003, "newTemplate.md"),
        (2004, "newTemplate.xml"), (2005, "newTemplate.docx"), (2006, "newTemplate.xlsx"),
        (2007, "newTemplate.pptx"), (2008, "newTemplate.json"), (2009, "newTemplate.html"),
        (2010, "newTemplate.css"), (2011, "newTemplate.js"), (2012, "newTemplate.py"),
        (2013, "newTemplate.sh"), (2014, "newTemplate.cpp"), (2015, "newTemplate.svg"),
        (2016, "newTemplate.csv"), (2017, "newTemplate.yaml"),
        (3001, "compress.zip"), (3002, "compress.7z"), (3003, "compress.tar"),
        (3004, "compress.tar.gz"), (3005, "compress.tar.bz2"), (3006, "compress.tar.xz"),
        (3007, "compress.tar.lzma"), (3008, "compress.tar.zst"), (3009, "compress.tar.lz4"),
        (3010, "compress.tar.Z"), (3011, "compress.cpio"), (3012, "compress.cpio.gz"),
        (3013, "compress.xar"),
        (3014, "compress.gz"), (3015, "compress.bz2"), (3016, "compress.xz"),
        (3017, "compress.lzma"), (3018, "compress.zst"), (3019, "compress.lz4"), (9001, settingsAction)
    ]
    private static let byTag = Dictionary(uniqueKeysWithValues: actions)
    private static let byAction = Dictionary(uniqueKeysWithValues: actions.map { ($0.1, $0.0) })

    static func tag(for action: String) -> Int? { byAction[action] }
    static func action(for tag: Int) -> String? { byTag[tag] }
}
