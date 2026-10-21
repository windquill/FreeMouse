import AppKit
import Foundation

struct StartupServiceError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct StartupLoginRecord: Equatable {
    let name: String
    let path: String
}

struct StartupApplication: Identifiable {
    var id: String { path }
    let path: String
    let name: String
    let loginEnabled: Bool?
}

/// All interpolated application data remains an AppleScript string, never executable source.
enum StartupScripts {
    static func literal(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }
    static let readLoginItems = """
    tell application "System Events"
        set resultItems to {}
        repeat with anItem in login items
            set itemPath to ""
            try
                set itemPath to path of anItem
            end try
            set end of resultItems to {name of anItem, itemPath}
        end repeat
        return resultItems
    end tell
    """
    static func setLoginItem(path: String, enabled: Bool) -> String {
        let pathValue = literal(path)
        if enabled {
            // Preserve the existing item and its Hidden preference. A failed make cannot remove it.
            return """
            tell application "System Events"
                set targetPath to \(pathValue)
                set alreadyPresent to false
                repeat with anItem in login items
                    set existingPath to ""
                    try
                        set existingPath to path of anItem
                    end try
                    if existingPath is targetPath then set alreadyPresent to true
                end repeat
                if not alreadyPresent then make login item at end with properties {path:targetPath, hidden:false}
            end tell
            """
        }
        // Reverse traversal handles duplicate entries without shifting later indexes.
        return """
        tell application "System Events"
            set targetPath to \(pathValue)
            repeat with itemIndex from (count login items) to 1 by -1
                set anItem to login item itemIndex
                set existingPath to ""
                try
                    set existingPath to path of anItem
                end try
                if existingPath is targetPath then delete anItem
            end repeat
        end tell
        """
    }
}

@MainActor enum StartupSystemAccess {
    static func execute(_ source: String) throws -> NSAppleEventDescriptor {
        guard let script = NSAppleScript(source: source) else { throw StartupServiceError(message: "无法创建系统登录项脚本。") }
        var failure: NSDictionary?
        let result = script.executeAndReturnError(&failure)
        if let failure {
            let code = (failure[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0
            if code == -1743 {
                throw StartupServiceError(message: "无法读取或设置登录项：请在系统设置 → 隐私与安全性 → 自动化中允许 OmniDesk 控制 System Events，然后刷新。")
            }
            if code == -128 { throw StartupServiceError(message: "操作已取消。") }
            // Do not expose the AppleScript error dictionary: it can contain source/application paths.
            throw StartupServiceError(message: "系统登录项操作失败（错误 \(code)）。请检查自动化授权后刷新；受保护项目可能需要在系统登录项设置中更改。")
        }
        return result
    }
    static func loginItems() throws -> [StartupLoginRecord] {
        let result = try execute(StartupScripts.readLoginItems)
        guard result.descriptorType == typeAEList else { throw StartupServiceError(message: "系统返回的登录项列表格式无法识别。") }
        return try (0..<result.numberOfItems).map { offset in
            guard let row = result.atIndex(offset + 1), row.numberOfItems == 2,
                  let name = row.atIndex(1)?.stringValue, let path = row.atIndex(2)?.stringValue else {
                throw StartupServiceError(message: "系统登录项记录不完整，未推断其开关状态。")
            }
            return StartupLoginRecord(name: name, path: path)
        }
    }
    static func setLoginItem(path: String, enabled: Bool) throws {
        guard path.hasPrefix("/"), !path.utf8.contains(0), URL(fileURLWithPath: path).standardizedFileURL.path == path else {
            throw StartupServiceError(message: "登录项路径无效。")
        }
        if enabled {
            guard path.lowercased().hasSuffix(".app"), Bundle(path: path)?.executableURL != nil else {
                throw StartupServiceError(message: "该登录项不是有效应用，无法重新启用；可先停用旧记录，再选择有效应用。")
            }
        }
        _ = try execute(StartupScripts.setLoginItem(path: path, enabled: enabled))
        let actual = try loginItems().contains { $0.path == path }
        guard actual == enabled else { throw StartupServiceError(message: "系统未保留所请求的登录项状态，请刷新并检查系统登录项设置。") }
    }
}

enum StartupInstalledApplications {
    static func scan(roots: [URL], loginItems: [StartupLoginRecord]?) -> [StartupApplication] {
        var applications: [String: String] = [:]
        let fm = FileManager.default
        for root in roots {
            guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            var visited = 0
            while let url = enumerator.nextObject() as? URL {
                visited += 1
                if visited > 20_000 { break }
                if enumerator.level > 5 { enumerator.skipDescendants(); continue }
                let info = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if info?.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                if url.pathExtension.lowercased() == "app", info?.isDirectory == true {
                    enumerator.skipDescendants()
                    applications[url.standardizedFileURL.path] = url.deletingPathExtension().lastPathComponent
                }
            }
        }
        for record in loginItems ?? [] where record.path.hasPrefix("/") {
            applications[record.path] = record.name
        }
        return applications.map { path, name in
            StartupApplication(path: path, name: name,
                               loginEnabled: loginItems.map { $0.contains { $0.path == path } })
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

struct StartupLaunchService: Identifiable {
    let path: String
    let label: String
    let domain: String
    let applicationPath: String?
    let defaultDisabled: Bool
    let enabled: Bool?
    let reason: String?
    var id: String { domain + "/" + path }
    var canModify: Bool { reason == nil && enabled != nil }
    var requiresAdministrator: Bool { domain == "system" }

    static func validLabel(_ label: String) -> Bool {
        !label.isEmpty && label.utf8.count <= 240 && label.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil
    }
    static func applicationPath(in plist: [String: Any]) -> String? {
        let arguments = plist["ProgramArguments"] as? [String] ?? []
        // Only inspect executable/open target paths. Never render arbitrary arguments or environment.
        var candidates = [plist["Program"] as? String, arguments.first].compactMap { $0 }
        if arguments.first == "/usr/bin/open", let index = arguments.firstIndex(of: "-a"), arguments.indices.contains(index + 1) {
            candidates.append(arguments[index + 1])
        }
        for candidate in candidates where candidate.hasPrefix("/") {
            let components = URL(fileURLWithPath: candidate).standardizedFileURL.pathComponents
            if let index = components.firstIndex(where: { $0.lowercased().hasSuffix(".app") }) {
                return NSString.path(withComponents: Array(components.prefix(index + 1)))
            }
        }
        return nil
    }
    static func parseDisabled(_ output: String) throws -> [String: Bool] {
        let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard lines.first == "disabled services = {", lines.last == "}" else {
            throw StartupServiceError(message: "无法识别 launchctl 的禁用状态，未将未知状态视为关闭。")
        }
        let regex = try NSRegularExpression(pattern: "^\"([^\"]+)\"\\s*=>\\s*(true|false)[,;]?$" )
        var disabled: [String: Bool] = [:]
        for line in lines.dropFirst().dropLast() {
            let range = NSRange(line.startIndex..., in: line)
            guard let match = regex.firstMatch(in: line, range: range),
                  let keyRange = Range(match.range(at: 1), in: line), let valueRange = Range(match.range(at: 2), in: line) else {
                throw StartupServiceError(message: "启动服务状态记录格式变化，无法可靠显示开关。")
            }
            disabled[String(line[keyRange])] = line[valueRange] == "true"
        }
        return disabled
    }
    static func read(directories: [(URL, String)], disabled: [String: [String: Bool]], embeddedParents: [String: String] = [:], errors: inout [String]) -> [StartupLaunchService] {
        var result: [StartupLaunchService] = []
        var seenPaths: Set<String> = []
        for (directory, domain) in directories {
            let files: [URL]
            do { files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) }
            catch let error as NSError where error.code == NSFileReadNoSuchFileError { continue }
            catch { errors.append("无法读取启动目录：\(directory.path)"); continue }
            for file in files.filter({ $0.pathExtension == "plist" }) {
                guard seenPaths.insert(domain + "/" + file.standardizedFileURL.path).inserted else { continue }
                let parent = embeddedParents[directory.standardizedFileURL.path]
                let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values?.isRegularFile == true, values?.isSymbolicLink == false, (values?.fileSize ?? Int.max) <= 1_048_576,
                      let data = try? Data(contentsOf: file),
                      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                      let label = plist["Label"] as? String else {
                    result.append(.init(path: file.path, label: file.lastPathComponent, domain: domain, applicationPath: nil,
                                        defaultDisabled: false, enabled: nil, reason: "文件不可读取、格式无效或为符号链接")); continue
                }
                let defaultDisabled = plist["Disabled"] as? Bool ?? false
                let override = disabled[domain]
                // An embedded manifest is only a capability. Its existence does not prove
                // registration. Even a persisted override does not prove it is registered now.
                let enabled = parent == nil ? override.map { !($0[label] ?? defaultDisabled) } : override?[label].map { !$0 }
                let protected = file.path.hasPrefix("/System/") || label.hasPrefix("com.apple.")
                let embeddedReason = enabled == nil ? "应用内嵌配置；注册状态未知，请由所属应用或系统登录项设置管理" : "仅确认持久化允许/禁用覆盖值；当前注册状态未知，请由所属应用管理"
                let reason: String? = protected ? "Apple 系统保护项" : (parent != nil ? embeddedReason : (!validLabel(label) ? "服务标签不符合安全规则" : (override == nil ? "无法读取该域状态，请刷新或检查权限" : nil)))
                result.append(.init(path: file.path, label: label, domain: domain, applicationPath: parent ?? applicationPath(in: plist),
                                    defaultDisabled: defaultDisabled, enabled: enabled, reason: reason))
            }
        }
        let duplicates = Dictionary(grouping: result, by: { $0.domain + "/" + $0.label }).filter { $0.value.count > 1 }
        return result.map { item in
            guard duplicates[item.domain + "/" + item.label] != nil else { return item }
            return .init(path: item.path, label: item.label, domain: item.domain, applicationPath: item.applicationPath,
                         defaultDisabled: item.defaultDisabled, enabled: item.enabled, reason: "同一域存在重复标签，无法安全修改")
        }.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    /// Lists embedded SMAppService declarations and login helper bundles without registering them.
    static func embedded(in applications: [StartupApplication], userDomain: String, disabled: [String: [String: Bool]], errors: inout [String]) -> [StartupLaunchService] {
        var directories: [(URL, String)] = []
        var parents: [String: String] = [:]
        var helpers: [StartupLaunchService] = []
        var seenApplications: Set<String> = []
        for app in applications where app.path.lowercased().hasSuffix(".app") && seenApplications.insert(app.path).inserted {
            let library = URL(fileURLWithPath: app.path).appendingPathComponent("Contents/Library")
            for (name, domain) in [("LaunchAgents", userDomain), ("LaunchDaemons", "system")] {
                let directory = library.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: directory.path) else { continue }
                let values = try? directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
                guard values?.isSymbolicLink == false, values?.isDirectory == true else { continue }
                directories.append((directory, domain))
                parents[directory.standardizedFileURL.path] = app.path
            }
            let loginDirectory = library.appendingPathComponent("LoginItems")
            let values = try? loginDirectory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard values?.isSymbolicLink == false, values?.isDirectory == true,
                  let files = try? FileManager.default.contentsOfDirectory(at: loginDirectory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { continue }
            for file in files.prefix(1_000) where file.pathExtension.lowercased() == "app" {
                let values = try? file.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values?.isDirectory == true, values?.isSymbolicLink == false else { continue }
                let name = Bundle(url: file)?.bundleIdentifier ?? file.deletingPathExtension().lastPathComponent
                helpers.append(.init(path: file.path, label: name, domain: userDomain, applicationPath: app.path,
                                     defaultDisabled: false, enabled: nil, reason: "应用内置登录辅助程序；注册状态未知，请由所属应用或系统登录项设置管理"))
            }
        }
        return read(directories: directories, disabled: disabled, embeddedParents: parents, errors: &errors) + helpers
    }
}

@MainActor enum StartupLaunchControl {
    static var userDomain: String { "gui/\(getuid())" }
    private static func run(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        // launchctl errors can include service descriptions. Keep raw output out of UI/logs.
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw StartupServiceError(message: "launchctl 操作失败（状态 \(process.terminationStatus)）。请检查权限后刷新。")
        }
        return String(decoding: data, as: UTF8.self)
    }
    static func disabled(in domain: String) throws -> [String: Bool] {
        guard domain == "system" || domain == userDomain else { throw StartupServiceError(message: "不允许操作其他用户的启动域。") }
        return try StartupLaunchService.parseDisabled(run(["print-disabled", domain]))
    }
    static func setEnabled(_ enabled: Bool, service: StartupLaunchService) throws {
        guard service.canModify, StartupLaunchService.validLabel(service.label),
              service.domain == "system" || service.domain == userDomain,
              !service.label.hasPrefix("com.apple."), !service.path.hasPrefix("/System/") else {
            throw StartupServiceError(message: service.reason ?? "此启动项受保护，无法修改。")
        }
        // Re-read the exact file and require the same identity before affecting its domain override.
        let url = URL(fileURLWithPath: service.path)
        let allowed = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents").path,
                       "/Library/LaunchAgents", "/Library/LaunchDaemons"]
        guard allowed.contains(url.deletingLastPathComponent().path),
              (try url.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == false,
              let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any],
              plist["Label"] as? String == service.label,
              (service.domain == "system") == (url.deletingLastPathComponent().path == "/Library/LaunchDaemons") else {
            throw StartupServiceError(message: "启动配置已改变，请刷新后重试。")
        }
        let action = enabled ? "enable" : "disable"
        if service.requiresAdministrator {
            // Domain is fixed and label is restricted to ASCII identifiers; no arbitrary command/path is accepted.
            let command = "/bin/launchctl \(action) 'system/\(service.label)'"
            _ = try StartupSystemAccess.execute("do shell script \(StartupScripts.literal(command)) with administrator privileges")
        } else {
            _ = try run([action, service.domain + "/" + service.label])
        }
        let actual = try disabled(in: service.domain)[service.label]
        guard actual == !enabled else { throw StartupServiceError(message: "启动服务变更尚未确认，请刷新。") }
    }
}
