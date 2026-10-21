import Foundation
import Darwin

/// Runs the vendored extractor in a mandatory filesystem sandbox.
enum SevenZipService {
    enum Failure: LocalizedError, Equatable {
        case passwordRequired, unavailable, firstVolumeRequired, unsafeOutput, resourceLimit, extractionFailed, timedOut
        var errorDescription: String? {
            switch self {
            case .passwordRequired: return "压缩包需要密码，或密码不正确。"
            case .unavailable: return "安全解压工具不可用。"
            case .firstVolumeRequired: return "请选择分卷压缩包的第一个分卷。"
            case .unsafeOutput: return "压缩包包含不安全的文件路径或链接。"
            case .resourceLimit: return "解压内容超过安全限制。"
            case .extractionFailed: return "压缩包解压失败，文件可能损坏或格式不受支持。"
            case .timedOut: return "解压超时。"
            }
        }
    }

    static func extract(_ archive: URL, into directory: URL, password: String? = nil) throws {
        let fm = FileManager.default
        if let password, password.utf8.count > 4096 || password.contains("\n") || password.contains("\r") { throw Failure.passwordRequired }
        var archive = archive.standardizedFileURL.resolvingSymlinksInPath()
        if archive.lastPathComponent.range(of: #"(?i)\.z[0-9]{2,3}$"#, options: .regularExpression) != nil {
            let main = archive.deletingPathExtension().appendingPathExtension("zip")
            guard FileManager.default.fileExists(atPath: main.path) else { throw Failure.firstVolumeRequired }
            archive = main.resolvingSymlinksInPath()
        }
        let directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        guard (try fm.contentsOfDirectory(atPath: directory.path)).isEmpty else { throw Failure.unsafeOutput }
        let helper = helperURL
        guard fm.isExecutableFile(atPath: helper.path), fm.isExecutableFile(atPath: "/usr/bin/sandbox-exec") else { throw Failure.unavailable }
        let volumes = try volumeURLs(for: archive)
        // With this 7-Zip CLI a bare -p selects an empty password. Omitting it
        // triggers the automatic prompt, which consumes our private stdin pipe.
        let profile = sandboxProfile(reading: [helper, archive] + volumes, into: directory)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        task.arguments = ["-p", profile, helper.path, "x", "-y", "-bd", "-bb0", "-o" + directory.path] + ["--", archive.path]
        task.currentDirectoryURL = directory
        task.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "HOME": directory.path, "TMPDIR": directory.path]
        let input = Pipe(), output = Pipe()
        task.standardInput = input
        task.standardOutput = output
        task.standardError = output
        let diagnostic = Diagnostic()
        do { try task.run() } catch { throw Failure.unavailable }
        let readerDone = DispatchGroup()
        readerDone.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { readerDone.leave() }
            while true {
                let data = output.fileHandleForReading.availableData
                if data.isEmpty { break }
                diagnostic.append(data)
            }
        }
        defer { try? output.fileHandleForReading.close() }
        if let password { try? input.fileHandleForWriting.write(contentsOf: Data((password + "\n").utf8)) }
        try? input.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(300)
        var limitFailure: Error?
        var nextCheck = Date()
        while task.isRunning {
            if Date() > deadline { limitFailure = Failure.timedOut; break }
            if Date() >= nextCheck {
                do { try validate(directory, checkLinks: false) } catch { limitFailure = error; break }
                nextCheck = Date().addingTimeInterval(0.5)
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        if let limitFailure {
            task.terminate()
            Thread.sleep(forTimeInterval: 0.1)
            if task.isRunning { Darwin.kill(task.processIdentifier, SIGKILL) }
            task.waitUntilExit()
            throw limitFailure
        }
        task.waitUntilExit()
        guard readerDone.wait(timeout: .now() + 2) == .success else { throw Failure.extractionFailed }
        if task.terminationStatus != 0 {
            if diagnostic.needsPassword { throw Failure.passwordRequired }
            throw Failure.extractionFailed
        }
        try validate(directory)
    }

    static func sandboxProfile(reading urls: [URL], into directory: URL) -> String {
        var ancestors = Set<URL>()
        for url in urls + [directory] {
            var parent = url.deletingLastPathComponent()
            while ancestors.insert(parent).inserted && parent.path != "/" { parent.deleteLastPathComponent() }
        }
        let reads = (urls + Array(ancestors)).map { "(literal \(quote($0.path)))" }.joined(separator: " ")
        return """
        (version 1)
        (allow default)
        (deny network*)
        (deny file-read-data (require-not (require-any (subpath "/System") (subpath "/usr") (subpath "/Library/Apple") (subpath "/dev") (subpath "/private/var/db/dyld") (subpath "/private/var/db/timezone") (literal "/private/etc/localtime") \(reads) (subpath \(quote(directory.path))))))
        (deny file-write* (require-not (require-any (subpath \(quote(directory.path))) (literal "/dev/null"))))
        """
    }

    static var helperURL: URL {
        if let bundled = Bundle.main.url(forResource: "7zz", withExtension: nil, subdirectory: "ArchiveTools") { return bundled }
        // An installed app must never execute a helper from a developer checkout.
        if Bundle.main.bundleURL.pathExtension == "app" {
            return Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/ArchiveTools/7zz")
        }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("ThirdParty/7zip/7zz")
    }

    private static func quote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r") + "\""
    }

    static func volumeURLs(for archive: URL) throws -> [URL] {
        let name = archive.lastPathComponent
        let lower = name.lowercased()
        if lower.range(of: #"\.r[0-9]{2,3}$"#, options: .regularExpression) != nil { throw Failure.firstVolumeRequired }
        if lower.hasSuffix(".rar") || lower.hasSuffix(".zip") {
            let base = archive.deletingPathExtension().lastPathComponent
            let ext = lower.hasSuffix(".rar") ? "r" : "z"
            let pattern = "^" + NSRegularExpression.escapedPattern(for: base) + #"\."# + ext + "[0-9]{2,3}$"
            let matcher = try NSRegularExpression(pattern: pattern, options: .caseInsensitive)
            let siblings = try FileManager.default.contentsOfDirectory(at: archive.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            let matches = siblings.filter { candidate in
                let value = candidate.lastPathComponent
                guard matcher.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil else { return false }
                var info = stat()
                return lstat(candidate.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
            }
            guard matches.count <= 1000 else { throw Failure.resourceLimit }
            return matches
        }
        let patterns = [#"^(.*\.(?:7z|zip))\.(\d{3})$"#, #"^(.*)\.part(\d+)\.rar$"#, #"^(.*)\.z(\d{2})$"#]
        for (index, pattern) in patterns.enumerated() {
            let regex = try NSRegularExpression(pattern: pattern, options: .caseInsensitive)
            let range = NSRange(name.startIndex..., in: name)
            guard let match = regex.firstMatch(in: name, range: range), let baseRange = Range(match.range(at: 1), in: name), let numberRange = Range(match.range(at: 2), in: name) else { continue }
            guard Int(name[numberRange]) == 1 else { throw Failure.firstVolumeRequired }
            let base = String(name[baseRange])
            let siblings = try FileManager.default.contentsOfDirectory(at: archive.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            let matching = siblings.filter { candidate in
                let n = candidate.lastPathComponent
                let m = regex.firstMatch(in: n, range: NSRange(n.startIndex..., in: n))
                let sameBase = m.flatMap { Range($0.range(at: 1), in: n) }.map { String(n[$0]) == base } ?? false
                guard sameBase || (index == 2 && n == base + ".zip") else { return false }
                var st = stat()
                return lstat(candidate.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG
            }
            guard matching.count <= 1000 else { throw Failure.resourceLimit }
            return matching
        }
        return []
    }

    static func validate(_ directory: URL, checkLinks: Bool = true) throws {
        let root = directory.resolvingSymlinksInPath().path
        var enumerationFailed = false
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil, options: [], errorHandler: { _, _ in enumerationFailed = true; return false }) else { throw Failure.unsafeOutput }
        var count = 0, bytes: Int64 = 0
        while let url = walker.nextObject() as? URL {
            count += 1
            if count > 100_000 || walker.level > 256 { throw Failure.resourceLimit }
            var st = stat()
            guard lstat(url.path, &st) == 0 else { if checkLinks { throw Failure.unsafeOutput }; continue } // An in-progress extractor can rename a file.
            let kind = st.st_mode & S_IFMT
            if kind == S_IFLNK {
                if !checkLinks { continue }
                var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
                guard realpath(url.path, &resolved) != nil else { throw Failure.unsafeOutput }
                let target = String(cString: resolved)
                guard target == root || target.hasPrefix(root + "/") else { throw Failure.unsafeOutput }
            } else if kind == S_IFREG {
                guard st.st_nlink == 1 else { throw Failure.unsafeOutput }
                bytes += Int64(st.st_size)
                if bytes > 20 * 1024 * 1024 * 1024 { throw Failure.resourceLimit }
            } else if kind != S_IFDIR { throw Failure.unsafeOutput }
            if checkLinks && kind != S_IFLNK && (st.st_mode & 0o6000) != 0 {
                guard chmod(url.path, st.st_mode & 0o777) == 0 else { throw Failure.unsafeOutput }
            }
        }
        if checkLinks && enumerationFailed { throw Failure.unsafeOutput }
    }

    private final class Diagnostic: @unchecked Sendable {
        private let lock = NSLock()
        private var tail = Data()
        private var detected = false
        func append(_ data: Data) {
            lock.lock(); defer { lock.unlock() }
            tail.append(data)
            let text = String(decoding: tail, as: UTF8.self).lowercased()
            detected = detected || text.contains("password") || text.contains("encrypted")
            if tail.count > 256 { tail = Data(tail.suffix(256)) }
        }
        var needsPassword: Bool { lock.lock(); defer { lock.unlock() }; return detected }
    }
}
