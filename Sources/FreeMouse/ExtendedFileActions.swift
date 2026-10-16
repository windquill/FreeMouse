import Foundation
import AppKit
import CryptoKit
import UniformTypeIdentifiers
import ObjectiveC

enum ExtendedFileTools {
    enum HashAlgorithm: String { case md5, sha1, sha256, sha512 }
    fileprivate struct Identity: Equatable { let device: UInt64; let inode: UInt64 }
    private struct Transfer { let source: URL; let target: URL; let identity: Identity }
    private static let fm = FileManager.default
    static var cutJournalURL: URL {
        fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FreeMouse/cut-hidden-journal.json")
    }
    static var hasCutJournal: Bool { exists(cutJournalURL) }
    private struct HiddenRecord: Codable {
        let path: String
        let hidden: Bool
        let device: UInt64
        let inode: UInt64
    }
    fileprivate static func writeCutJournal(_ urls: [URL], states: [Bool], identities: [Identity], at url: URL) throws -> Identity {
        guard !exists(url), !urls.isEmpty, urls.count <= 10_000, urls.count == states.count, urls.count == identities.count else {
            throw FileToolError.message("存在未恢复的剪切记录，请先恢复后再剪切。")
        }
        let records = urls.indices.map { HiddenRecord(path: urls[$0].path, hidden: states[$0], device: identities[$0].device, inode: identities[$0].inode) }
        let data = try JSONEncoder().encode(records)
        guard data.count <= 4_194_304 else { throw FileToolError.message("剪切恢复记录过大，请减少选择数量。") }
        let directory = url.deletingLastPathComponent()
        if !exists(directory) { try fm.createDirectory(at: directory, withIntermediateDirectories: true) }
        try data.write(to: url, options: .withoutOverwriting)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
        return try identity(url)
    }
    static func recoverCutJournal(at url: URL) throws -> Int {
        guard exists(url) else { return 0 }
        let attributes = try fm.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue <= 4_194_304 else {
            throw FileToolError.message("剪切恢复记录不是安全的普通文件，已保留待检查：\(url.path)")
        }
        let journalIdentity = try identity(url)
        let records = try JSONDecoder().decode([HiddenRecord].self, from: Data(contentsOf: url))
        guard !records.isEmpty, records.count <= 10_000,
              Set(records.map(\.path)).count == records.count,
              records.allSatisfy({ $0.path.hasPrefix("/") && !$0.path.contains("\0") }) else {
            throw FileToolError.message("剪切恢复记录无效，已保留待检查：\(url.path)")
        }
        var failures: [String] = []
        for record in records {
            let source = URL(fileURLWithPath: record.path)
            do {
                guard try identity(source) == Identity(device: record.device, inode: record.inode) else {
                    throw FileToolError.message("原文件已被替换")
                }
                try writeHidden(source, hidden: record.hidden)
            } catch { failures.append(record.path) }
        }
        guard failures.isEmpty else {
            throw FileToolError.message("以下剪切文件未能恢复；记录已保留，未修改同路径的替代文件：\n" + failures.joined(separator: "\n"))
        }
        try removeCutJournal(at: url, identity: journalIdentity)
        return records.count
    }
    fileprivate static func removeCutJournal(at url: URL, identity expected: Identity) throws {
        guard exists(url) else { return }
        guard try identity(url) == expected else { throw FileToolError.message("剪切恢复记录已被替换，未删除该记录。") }
        try fm.removeItem(at: url)
    }

    static func hash(_ url: URL, algorithm: HashAlgorithm) throws -> String {
        guard url.isFileURL,
              try fm.attributesOfItem(atPath: url.resolvingSymlinksInPath().path)[.type] as? FileAttributeType == .typeRegular else {
            throw FileToolError.message("校验值只支持普通文件：\(url.lastPathComponent)")
        }
        switch algorithm {
        case .md5: return try digest(url, using: Insecure.MD5())
        case .sha1: return try digest(url, using: Insecure.SHA1())
        case .sha256: return try digest(url, using: SHA256())
        case .sha512: return try digest(url, using: SHA512())
        }
    }
    private static func digest<H: HashFunction>(_ url: URL, using initial: H) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = initial
        while let bytes = try file.read(upToCount: 1_048_576), !bytes.isEmpty {
            try Task.checkCancellation()
            hash.update(data: bytes)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func copy(_ urls: [URL], to directory: URL) throws -> [URL] {
        try transfer(urls, to: directory, moving: false)
    }
    static func move(_ urls: [URL], to directory: URL) throws -> [URL] {
        try transfer(urls, to: directory, moving: true)
    }
    fileprivate static func move(_ urls: [URL], to directory: URL, originalIdentities: [Identity]) throws -> [URL] {
        try transfer(urls, to: directory, moving: true, originalIdentities: originalIdentities)
    }
    static func validateSources(_ urls: [URL]) throws {
        guard !urls.isEmpty else { throw FileToolError.message("请先选择文件或文件夹。") }
        var used = Set<String>()
        let normalized = urls.map(canonicalLeaf)
        for (index, url) in urls.enumerated() {
            guard url.isFileURL, exists(url), used.insert(normalized[index].path).inserted else {
                throw FileToolError.message("文件不存在、重复选择或不是本地文件：\(url.path)")
            }
            let type = try fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
            guard type == .typeRegular || type == .typeDirectory || type == .typeSymbolicLink else {
                throw FileToolError.message("不支持此特殊文件类型：\(url.path)")
            }
            if type == .typeDirectory {
                for (other, path) in normalized.enumerated() where other != index {
                    guard !isInside(path, normalized[index]) else {
                        throw FileToolError.message("不要同时选择文件夹和它的子项：\(url.path)")
                    }
                }
            }
        }
    }
    static func isDirectory(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        return (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
    private static func transfer(_ urls: [URL], to directory: URL, moving: Bool, originalIdentities: [Identity]? = nil) throws -> [URL] {
        try validateSources(urls)
        if let originalIdentities, originalIdentities.count != urls.count { throw FileToolError.message("剪切文件身份记录无效。") }
        guard isDirectory(directory) else { throw FileToolError.message("目标不是可用文件夹：\(directory.path)") }
        let destination = directory.resolvingSymlinksInPath().standardizedFileURL
        var targets = Set<String>()
        let plan = try urls.enumerated().map { index, source -> Transfer in
            let currentIdentity = try identity(source)
            let expected = originalIdentities?[index] ?? currentIdentity
            guard currentIdentity == expected else { throw FileToolError.message("原剪切文件已被替换，未移动替代文件：\(source.path)") }
            let target = destination.appendingPathComponent(source.lastPathComponent)
            guard !exists(target), targets.insert(target.path.lowercased()).inserted else {
                throw FileToolError.message("目标已存在或批量名称冲突：\(target.path)。未开始操作。")
            }
            if try fm.attributesOfItem(atPath: source.path)[.type] as? FileAttributeType == .typeDirectory {
                let origin = source.resolvingSymlinksInPath().standardizedFileURL
                guard destination != origin, !isInside(destination, origin) else {
                    throw FileToolError.message("不能把文件夹复制或移动到自己或子文件夹：\(source.path)")
                }
            }
            return Transfer(source: source, target: target, identity: expected)
        }
        try execute(plan, moving: moving)
        return plan.map(\.target)
    }
    private static func execute(_ plan: [Transfer], moving: Bool) throws {
        for item in plan {
            guard try identity(item.source) == item.identity, !exists(item.target) else {
                throw FileToolError.message("文件状态已改变，请重新操作：\(item.source.path)")
            }
        }
        var completed: [(Transfer, Identity)] = []
        var current: Transfer?
        do {
            for item in plan {
                current = item
                guard try identity(item.source) == item.identity, !exists(item.target) else {
                    throw FileToolError.message("文件状态已改变：\(item.source.path)")
                }
                if moving { try fm.moveItem(at: item.source, to: item.target) }
                else { try fm.copyItem(at: item.source, to: item.target) }
                completed.append((item, try identity(item.target)))
                current = nil
            }
        } catch {
            var leftovers: [String] = []
            for (item, ownIdentity) in completed.reversed() {
                do {
                    guard try identity(item.target) == ownIdentity else { throw FileToolError.message("目标已被其他操作替换") }
                    if moving { try fm.moveItem(at: item.target, to: item.source) }
                    else { try fm.removeItem(at: item.target) }
                } catch { leftovers.append(item.target.path) }
            }
            // An incomplete cross-volume operation may leave a target whose ownership
            // cannot be established. Preserve it and report it instead of deleting it.
            if let current, exists(current.target) { leftovers.append(current.target.path) }
            throw FileToolError.message("\(moving ? "移动" : "复制")失败：\(error.localizedDescription)" +
                (leftovers.isEmpty ? "\n已还原已完成的操作。" : "\n以下目标需要检查，未继续处理：\n" + leftovers.joined(separator: "\n")))
        }
    }
    static func folderFromName(_ urls: [URL]) throws -> [URL] {
        try validateSources(urls)
        var used = Set<String>()
        let plans = try urls.map { source -> (folder: URL, item: Transfer) in
            let stem = isDirectory(source) ? source.lastPathComponent : source.deletingPathExtension().lastPathComponent
            let name = stem == source.lastPathComponent ? stem + " 文件夹" : stem
            try FileTools.validateName(name)
            let folder = source.deletingLastPathComponent().appendingPathComponent(name)
            guard !exists(folder), used.insert(canonicalLeaf(folder).path.lowercased()).inserted else {
                throw FileToolError.message("按名称创建的文件夹已存在或重复：\(folder.path)。未修改任何文件。")
            }
            return (folder, Transfer(source: source, target: folder.appendingPathComponent(source.lastPathComponent), identity: try identity(source)))
        }
        var created: [URL] = []
        do {
            for plan in plans {
                guard !exists(plan.folder) else { throw FileToolError.message("目标状态已改变：\(plan.folder.path)") }
                try fm.createDirectory(at: plan.folder, withIntermediateDirectories: false)
                created.append(plan.folder)
            }
            try execute(plans.map(\.item), moving: true)
            return plans.map { $0.item.target }
        } catch {
            var retained: [String] = []
            for folder in created.reversed() {
                do {
                    guard try fm.contentsOfDirectory(atPath: folder.path).isEmpty else { retained.append(folder.path); continue }
                    try fm.removeItem(at: folder)
                } catch { retained.append(folder.path) }
            }
            throw FileToolError.message(error.localizedDescription + (retained.isEmpty ? "" : "\n保留需检查的文件夹：\n" + retained.joined(separator: "\n")))
        }
    }
    static func createAliases(_ urls: [URL], in directory: URL) throws -> [URL] {
        try validateSources(urls)
        guard isDirectory(directory) else { throw FileToolError.message("替身目标文件夹不可用。") }
        var used = Set<String>()
        let targets = try urls.map { source -> URL in
            let name = source.lastPathComponent + " 替身"
            try FileTools.validateName(name)
            let target = directory.appendingPathComponent(name)
            guard !exists(target), used.insert(target.path.lowercased()).inserted else {
                throw FileToolError.message("替身已存在或名称重复：\(target.path)")
            }
            return target
        }
        // Bookmark-file writing has no no-overwrite flag. Stage in an owned folder,
        // then use moveItem's refusal to replace an existing final target.
        let staging = directory.appendingPathComponent(".freemouse-alias-" + UUID().uuidString)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        var completed: [(URL, Identity)] = []
        do {
            for (index, source) in urls.enumerated() {
                let data = try source.bookmarkData(options: [.suitableForBookmarkFile, .withoutImplicitSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
                let temporary = staging.appendingPathComponent(String(index))
                try URL.writeBookmarkData(data, to: temporary)
                try fm.moveItem(at: temporary, to: targets[index])
                completed.append((targets[index], try identity(targets[index])))
            }
            return targets
        } catch {
            var retained: [String] = []
            for (url, ownIdentity) in completed.reversed() {
                do {
                    guard try identity(url) == ownIdentity else { throw FileToolError.message("替身已被替换") }
                    try fm.removeItem(at: url)
                } catch { retained.append(url.path) }
            }
            throw FileToolError.message("创建替身失败：\(error.localizedDescription)" + (retained.isEmpty ? "" : "\n未能还原：\n" + retained.joined(separator: "\n")))
        }
    }
    static func hiddenStates(_ urls: [URL]) throws -> [Bool] {
        try validateSources(urls)
        return try urls.map {
            // URL caches resource flags; recovery may have changed them through another URL.
            var fresh = $0
            fresh.removeAllCachedResourceValues()
            return try fresh.resourceValues(forKeys: [.isHiddenKey]).isHidden ?? false
        }
    }
    static func setHidden(_ urls: [URL], hidden: Bool) throws {
        let original = try hiddenStates(urls)
        var completed: [Int] = []
        do {
            for (index, url) in urls.enumerated() {
                try writeHidden(url, hidden: hidden)
                completed.append(index)
            }
        } catch {
            var retained: [String] = []
            for index in completed.reversed() {
                do { try writeHidden(urls[index], hidden: original[index]) }
                catch { retained.append(urls[index].path) }
            }
            throw FileToolError.message("更新隐藏状态失败：\(error.localizedDescription)" + (retained.isEmpty ? "" : "\n未能还原：\n" + retained.joined(separator: "\n")))
        }
    }
    static func restoreHidden(_ urls: [URL], states: [Bool]) throws {
        guard urls.count == states.count else { throw FileToolError.message("隐藏状态记录无效。") }
        var failures: [String] = []
        for (url, hidden) in zip(urls, states) {
            do { try writeHidden(url, hidden: hidden) }
            catch { failures.append(url.path) }
        }
        if !failures.isEmpty { throw FileToolError.message("以下文件未能恢复隐藏状态：\n" + failures.joined(separator: "\n")) }
    }
    private static func writeHidden(_ url: URL, hidden: Bool) throws {
        var value = URLResourceValues()
        value.isHidden = hidden
        var mutable = url
        try mutable.setResourceValues(value)
    }
    static func directoryItems(_ directories: [URL], unhiding: Bool) throws -> [URL] {
        try validateSources(directories)
        var result: [URL] = []
        for directory in directories {
            guard isDirectory(directory) else { throw FileToolError.message("请选择文件夹：\(directory.path)") }
            result += try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isHiddenKey], options: [])
                .filter { !unhiding || !$0.lastPathComponent.hasPrefix(".") }
        }
        return result
    }
    static func validatePermanentDeletion(_ urls: [URL]) throws {
        try validateSources(urls)
        let home = fm.homeDirectoryForCurrentUser.resolvingSymlinksInPath().standardizedFileURL
        let protected = ["/", "/Users", "/Volumes", "/private", "/var", "/System", "/Library", "/Applications", "/usr", "/bin", "/sbin", "/etc"]
            .map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path }
        let systemTrees = ["/System", "/Library", "/Applications", "/usr", "/bin", "/sbin", "/etc"]
            .map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path }
        for url in urls {
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            let path = resolved.path
            let mountedRoot = resolved.pathComponents.count == 3 && resolved.pathComponents[1] == "Volumes"
            guard !protected.contains(path), resolved != home, !isInside(home, resolved), !mountedRoot,
                  !systemTrees.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else {
                throw FileToolError.message("为避免破坏系统，拒绝永久删除系统目录、磁盘根目录或用户主目录：\(url.path)")
            }
        }
    }
    static func deletePermanently(_ urls: [URL]) throws {
        try validatePermanentDeletion(urls)
        let identities = try urls.map(identity)
        var completed: [String] = []
        do {
            for (url, expected) in zip(urls, identities) {
                guard try identity(url) == expected else { throw FileToolError.message("文件状态已改变：\(url.path)") }
                try fm.removeItem(at: url)
                completed.append(url.path)
            }
        } catch {
            throw FileToolError.message("永久删除未全部完成：\(error.localizedDescription)" +
                (completed.isEmpty ? "\n尚未删除任何目标。" : "\n以下目标已删除，无法由应用撤销：\n" + completed.joined(separator: "\n")))
        }
    }
    private static func exists(_ url: URL) -> Bool {
        fm.fileExists(atPath: url.path) || (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil
    }
    private static func canonicalLeaf(_ url: URL) -> URL {
        url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent).standardizedFileURL
    }
    private static func isInside(_ child: URL, _ parent: URL) -> Bool {
        let prefix = parent.path == "/" ? "/" : parent.path + "/"
        return child.path != parent.path && child.path.hasPrefix(prefix)
    }
    fileprivate static func identity(_ url: URL) throws -> Identity {
        let attributes = try fm.attributesOfItem(atPath: url.path)
        guard let device = attributes[.systemNumber] as? NSNumber, let inode = attributes[.systemFileNumber] as? NSNumber else {
            throw FileToolError.message("无法核对文件身份：\(url.path)")
        }
        return Identity(device: device.uint64Value, inode: inode.uint64Value)
    }
}

final class ExtendedCutSession {
    let urls: [URL]
    private var originalHidden: [Bool]?
    private let identities: [ExtendedFileTools.Identity]
    private let journalURL: URL
    private var journalIdentity: ExtendedFileTools.Identity?
    private var terminationObserver: NSObjectProtocol?
    var hasHiddenChanges: Bool { originalHidden != nil }

    init(urls: [URL], hide: Bool, journalURL: URL = ExtendedFileTools.cutJournalURL) throws {
        self.urls = urls
        self.journalURL = journalURL
        try ExtendedFileTools.validateSources(urls)
        identities = try urls.map(ExtendedFileTools.identity)
        if hide {
            originalHidden = try ExtendedFileTools.hiddenStates(urls)
            journalIdentity = try ExtendedFileTools.writeCutJournal(urls, states: originalHidden!, identities: identities, at: journalURL)
            do { try ExtendedFileTools.setHidden(urls, hidden: true) }
            catch { try? restore(); throw error }
        }
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
            try? self?.restore()
        }
    }
    func restore() throws {
        guard let originalHidden else { return }
        var failures: [String] = []
        for (index, url) in urls.enumerated() {
            do {
                guard try ExtendedFileTools.identity(url) == identities[index] else { throw FileToolError.message("原文件已被替换") }
                try ExtendedFileTools.restoreHidden([url], states: [originalHidden[index]])
            } catch { failures.append(url.path) }
        }
        if !failures.isEmpty { throw FileToolError.message("以下剪切文件未能恢复隐藏状态：\n" + failures.joined(separator: "\n")) }
        if let journalIdentity { try ExtendedFileTools.removeCutJournal(at: journalURL, identity: journalIdentity) }
        self.originalHidden = nil
    }
    func validateOriginals() throws {
        for (url, expected) in zip(urls, identities) {
            guard try ExtendedFileTools.identity(url) == expected else {
                throw FileToolError.message("原剪切文件已被替换，未移动替代文件：\(url.path)")
            }
        }
    }
    func move(to directory: URL) throws -> [URL] {
        try validateOriginals()
        return try ExtendedFileTools.move(urls, to: directory, originalIdentities: identities)
    }
    deinit {
        try? restore()
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
    }
}

private final class ExtendedActionState {
    var cut: ExtendedCutSession?
    var sharing: NSSharingService?
}
private var extendedActionStateKey: UInt8 = 0

@MainActor
extension AppModel {
    var hasPendingCutRecovery: Bool { ExtendedFileTools.hasCutJournal || extendedActionState.cut?.hasHiddenChanges == true }
    func restoreInterruptedCut() {
        do {
            let count = try ExtendedFileTools.recoverCutJournal(at: ExtendedFileTools.cutJournalURL)
            if count > 0 { status = "已恢复上次中断剪切的 \(count) 项隐藏状态。" }
        } catch { fail(error.localizedDescription) }
    }
    private var extendedActionState: ExtendedActionState {
        if let value = objc_getAssociatedObject(self, &extendedActionStateKey) as? ExtendedActionState { return value }
        let value = ExtendedActionState()
        objc_setAssociatedObject(self, &extendedActionStateKey, value, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return value
    }

    func extendedFileAction(_ action: String) -> Bool {
        let actions: Set<String> = ["copyTo", "moveTo", "folderFromName", "desktopAlias", "hide", "unhide", "hideAll", "unhideAll", "iconSet", "iconClear", "airdrop", "deletePermanent", "cut", "pasteCut", "cancelCut", "hashMD5", "hashSHA1", "hashSHA256", "hashSHA512"]
        guard actions.contains(action) else { return false }
        if action == "cancelCut", extendedActionState.cut == nil { return true }
        guard !busy else { status = "正在处理文件，请等待当前操作完成。"; return true }
        do {
            if action == "cancelCut" {
                try extendedActionState.cut?.restore()
                extendedActionState.cut = nil
                status = "已取消剪切，文件保留在原位置。"
                return true
            }
            if action == "pasteCut" {
                guard let cut = extendedActionState.cut else { status = "没有待粘贴的剪切文件。"; return true }
                let selectedDestination = selectedFiles.count == 1 && ExtendedFileTools.isDirectory(selectedFiles[0]) && !cut.urls.contains(selectedFiles[0]) ? selectedFiles[0] : nil
                guard let destination = selectedDestination ?? extendedDirectory("选择剪切文件的粘贴位置") else { return true }
                try cut.validateOriginals()
                try cut.restore()
                runExtended("移动剪切文件", operation: { try cut.move(to: destination) }) { [self] result in
                    extendedActionState.cut = nil
                    selectedFiles = result
                    result.forEach(remember)
                }
                return true
            }
            guard let urls = extendedSources(directoriesOnly: action == "hideAll" || action == "unhideAll") else { return true }
            try ExtendedFileTools.validateSources(urls)
            switch action {
            case "cut":
                try extendedActionState.cut?.restore()
                extendedActionState.cut = nil
                extendedActionState.cut = try ExtendedCutSession(urls: urls, hide: UserDefaults.standard.bool(forKey: "cutHidesFiles"))
                status = "已剪切 \(urls.count) 项；粘贴时移动，可随时取消剪切。"
            case "copyTo", "moveTo":
                guard let directory = extendedDirectory(action == "copyTo" ? "选择复制目标文件夹" : "选择移动目标文件夹") else { return true }
                let moving = action == "moveTo"
                runExtended(moving ? "移动文件" : "复制文件", operation: {
                    try moving ? ExtendedFileTools.move(urls, to: directory) : ExtendedFileTools.copy(urls, to: directory)
                }) { [self] result in selectedFiles = result; result.forEach(remember) }
            case "folderFromName":
                runExtended("按文件名创建文件夹", operation: { try ExtendedFileTools.folderFromName(urls) }) { [self] result in
                    selectedFiles = result; result.map { $0.deletingLastPathComponent() }.forEach(remember)
                }
            case "desktopAlias":
                guard let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first else { throw FileToolError.message("桌面目录不可用。") }
                runExtended("创建桌面替身", operation: { try ExtendedFileTools.createAliases(urls, in: desktop) }) { [self] result in result.forEach(remember) }
            case "hide", "unhide", "hideAll", "unhideAll":
                let hidden = action == "hide" || action == "hideAll"
                let all = action == "hideAll" || action == "unhideAll"
                runExtended(hidden ? "隐藏文件" : "显示文件", operation: {
                    let items = try all ? ExtendedFileTools.directoryItems(urls, unhiding: !hidden) : urls
                    if !items.isEmpty { try ExtendedFileTools.setHidden(items, hidden: hidden) }
                    return items
                }) { _ in }
            case "hashMD5", "hashSHA1", "hashSHA256", "hashSHA512":
                let algorithm: ExtendedFileTools.HashAlgorithm = action == "hashMD5" ? .md5 : action == "hashSHA1" ? .sha1 : action == "hashSHA512" ? .sha512 : .sha256
                busy = true; status = "正在计算 \(algorithm.rawValue.uppercased())…"
                Task { [self] in
                    do {
                        let text = try await Task.detached(priority: .userInitiated) {
                            try urls.map { $0.path + "\n" + (try ExtendedFileTools.hash($0, algorithm: algorithm)) }.joined(separator: "\n\n")
                        }.value
                        busy = false; status = "校验值计算完成"
                        showText(algorithm.rawValue.uppercased(), text: text)
                    } catch { fail(error.localizedDescription) }
                }
            case "iconSet", "iconClear":
                var icon: NSImage?
                if action == "iconSet" {
                    guard let chosen = try extendedIcon() else { return true }
                    icon = chosen
                }
                var failures: [String] = []
                for url in urls {
                    if !NSWorkspace.shared.setIcon(icon, forFile: url.path, options: []) { failures.append(url.path) }
                }
                guard failures.isEmpty else { throw FileToolError.message("以下文件图标未能更新；其他目标可能已更新：\n" + failures.joined(separator: "\n")) }
                status = action == "iconSet" ? "已设置 \(urls.count) 项文件图标" : "已恢复 \(urls.count) 项默认图标"
            case "airdrop":
                guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else { throw FileToolError.message("当前文件或设备不支持 AirDrop。") }
                extendedActionState.sharing = service
                service.perform(withItems: urls)
                status = "已打开 AirDrop，请在系统窗口中选择接收方。"
            case "deletePermanent":
                try ExtendedFileTools.validatePermanentDeletion(urls)
                if !UserDefaults.standard.bool(forKey: "deleteWithoutConfirmation"), !confirmExtendedDeletion(urls) { return true }
                runExtended("永久删除文件", operation: {
                    try ExtendedFileTools.deletePermanently(urls)
                    return urls
                }) { [self] deleted in selectedFiles.removeAll { deleted.contains($0) } }
            default: break
            }
        } catch { fail(error.localizedDescription) }
        return true
    }

    private func extendedSources(directoriesOnly: Bool) -> [URL]? {
        if !selectedFiles.isEmpty { return selectedFiles }
        let panel = NSOpenPanel(); panel.title = directoriesOnly ? "选择文件夹" : "选择文件或文件夹"
        panel.canChooseFiles = !directoriesOnly; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { status = "已取消文件操作"; return nil }
        selectedFiles = panel.urls
        return panel.urls.isEmpty ? nil : panel.urls
    }
    private func extendedIcon() throws -> NSImage? {
        let designs: [(String, String)] = [
            ("文件夹", "folder.fill"), ("星标", "star.fill"), ("收藏", "heart.fill"),
            ("文档", "doc.text.fill"), ("照片", "photo.fill"), ("音乐", "music.note"),
            ("视频", "film.fill"), ("归档", "archivebox.fill"), ("工作", "briefcase.fill"),
            ("阅读", "book.fill"), ("设计", "paintpalette.fill"), ("工具", "hammer.fill"),
            ("代码", "terminal"), ("游戏", "gamecontroller.fill"), ("学习", "graduationcap.fill"),
            ("网络", "globe"), ("私密", "lock.fill"), ("完成", "checkmark.seal.fill"),
            ("快捷", "bolt.fill"), ("自然", "leaf.fill")
        ]
        let alert = NSAlert(); alert.messageText = "选择文件图标"
        alert.informativeText = "选择内置彩色图标，或使用自己的 PNG。恢复图标会移除自定义图标。"
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        for (index, design) in designs.enumerated() {
            picker.addItem(withTitle: design.0)
            picker.lastItem?.image = NSImage(systemSymbolName: design.1, accessibilityDescription: design.0)?
                .withSymbolConfiguration(.init(paletteColors: [NSColor(calibratedHue: CGFloat(index) / 20, saturation: 0.65, brightness: 0.8, alpha: 1)]))
        }
        picker.addItem(withTitle: "自定义 PNG…")
        alert.accessoryView = picker
        alert.addButton(withTitle: "设置图标"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let index = picker.indexOfSelectedItem
        if index == designs.count {
            let panel = NSOpenPanel(); panel.title = "选择自定义图标 PNG"; panel.allowedContentTypes = [.png]
            panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
            guard panel.runModal() == .OK, let url = panel.url else { return nil }
            return NSImage(cgImage: try FileTools.loadImage(url), size: .zero)
        }
        guard designs.indices.contains(index),
              let symbol = NSImage(systemSymbolName: designs[index].1, accessibilityDescription: designs[index].0)?
                .withSymbolConfiguration(.init(pointSize: 132, weight: .medium).applying(.init(paletteColors: [.white]))),
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 256, pixelsHigh: 256,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw FileToolError.message("内置图标无法绘制，请选择 PNG。")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor(calibratedHue: CGFloat(index) / 20, saturation: 0.65, brightness: 0.8, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 12, y: 12, width: 232, height: 232), xRadius: 48, yRadius: 48).fill()
        symbol.draw(in: NSRect(x: 60, y: 60, width: 136, height: 136))
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: 256, height: 256))
        image.addRepresentation(bitmap)
        return image
    }
    private func extendedDirectory(_ message: String) -> URL? {
        let favorites = (UserDefaults.standard.stringArray(forKey: "favoriteDirectories") ?? [])
            .map { URL(fileURLWithPath: $0, isDirectory: true) }.filter(ExtendedFileTools.isDirectory)
        if !favorites.isEmpty {
            let alert = NSAlert(); alert.messageText = message
            let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 520, height: 28))
            favorites.forEach { picker.addItem(withTitle: $0.path) }
            picker.addItem(withTitle: "其他目录…")
            alert.accessoryView = picker
            alert.addButton(withTitle: "选择"); alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            if picker.indexOfSelectedItem < favorites.count { return favorites[picker.indexOfSelectedItem] }
        }
        let panel = NSOpenPanel(); panel.title = message; panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false; panel.canCreateDirectories = true
        guard panel.runModal() == .OK else { status = "已取消文件操作"; return nil }
        return panel.url
    }
    private func runExtended(_ label: String, operation: @escaping @Sendable () throws -> [URL], completion: @escaping ([URL]) -> Void) {
        busy = true; status = "正在\(label)…"
        Task { [self] in
            do {
                let result = try await Task.detached(priority: .userInitiated, operation: operation).value
                completion(result)
                busy = false; status = "\(label)完成：\(result.count) 项"
            } catch { fail(error.localizedDescription) }
        }
    }
    private func confirmExtendedDeletion(_ urls: [URL]) -> Bool {
        let alert = NSAlert(); alert.alertStyle = .critical
        alert.messageText = "永久删除 \(urls.count) 个目标？"
        alert.informativeText = "以下目标及所选文件夹内的内容将直接删除，不进入废纸篓，应用无法撤销。"
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 580, height: 240))
        scroll.hasVerticalScroller = true
        let text = NSTextView(frame: scroll.bounds)
        text.string = urls.map(\.path).joined(separator: "\n"); text.isEditable = false
        text.font = .systemFont(ofSize: 12); scroll.documentView = text; alert.accessoryView = scroll
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "永久删除").keyEquivalent = ""
        return alert.runModal() == .alertSecondButtonReturn
    }
}
