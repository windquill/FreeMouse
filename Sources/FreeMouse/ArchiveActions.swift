import AppKit
import Darwin

/// User-facing naming only. ArchiveService separately publishes with RENAME_EXCL.
enum ArchiveDestination {
    static func extractionName(_ filename: String) -> String {
        let suffixes = [".tar.bz2", ".tar.lzma", ".tar.zstd", ".tar.gz", ".tar.xz", ".tar.zst", ".tar.lz4", ".tar.lz", ".cpio.gz", ".tar.z", ".tbz2", ".tgz", ".tbz", ".txz", ".tlz", ".tzst", ".zip", ".7z", ".rar", ".tar", ".cpio", ".xar", ".iso", ".cab", ".lzh", ".lha", ".gz", ".bz2", ".xz", ".lzma", ".zst", ".lz4", ".z", ".zipx", ".dmg", ".pkg", ".msi", ".exe", ".wim", ".esd", ".rpm", ".deb", ".arj", ".chm", ".vhd", ".vhdx", ".vmdk"]
        var candidate = filename
        if let range = candidate.range(of: #"(?i)\.part[0-9]+\.rar$"#, options: .regularExpression) {
            candidate = String(candidate[..<range.lowerBound])
        } else if candidate.range(of: #"\.[0-9]{3}$"#, options: .regularExpression) != nil {
            candidate = String(candidate.dropLast(4))
        }
        let lower = candidate.lowercased()
        let suffix = suffixes.first { lower.hasSuffix($0) }
        let stem = suffix.map { String(candidate.dropLast($0.count)) } ?? candidate
        return stem.isEmpty || stem == "." || stem == ".." ? "Archive" : stem
    }
    static func uniqueURL(in directory: URL, base: String, suffix: String = "") throws -> URL {
        guard !base.isEmpty, base != ".", base != "..", !base.contains("/") else {
            throw ArchiveService.Failure(message: "无法确定归档输出名称")
        }
        for number in 1...10_000 {
            let name = base + (number == 1 ? "" : " (\(number))") + (suffix.isEmpty ? "" : "." + suffix)
            let candidate = directory.appendingPathComponent(name)
            var info = stat()
            let exists = candidate.withUnsafeFileSystemRepresentation { pointer in
                guard let pointer else { return true }
                return lstat(pointer, &info) == 0 || errno != ENOENT
            }
            if !exists { return candidate }
        }
        throw ArchiveService.Failure(message: "同名归档过多，请更改输出文件名")
    }
}

@MainActor private final class ArchiveProgressWindow {
    private let panel: NSPanel
    init(_ title: String, detail: String) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 120),
                        styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "OmniDesk · " + title
        panel.isReleasedWhenClosed = false
        let spinner = NSProgressIndicator()
        spinner.style = .spinning; spinner.controlSize = .regular; spinner.startAnimation(nil)
        let heading = NSTextField(labelWithString: title)
        heading.font = .boldSystemFont(ofSize: 14)
        let label = NSTextField(wrappingLabelWithString: detail)
        label.font = .systemFont(ofSize: 12); label.textColor = .secondaryLabelColor
        let text = NSStackView(views: [heading, label]); text.orientation = .vertical; text.alignment = .leading
        let stack = NSStackView(views: [spinner, text]); stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -24),
            stack.centerYAnchor.constraint(equalTo: panel.contentView!.centerYAnchor)
        ])
        panel.center(); panel.makeKeyAndOrderFront(nil)
    }
    func close() { panel.close() }
}

@MainActor extension AppModel {
    private static func archivePassword(for name: String, retry: Bool) -> String? {
        let alert = NSAlert()
        alert.messageText = retry ? "密码不正确，请重试" : "压缩包需要密码"
        alert.informativeText = name + "\n密码仅用于本次解压，不会保存或放入命令行参数。"
        let input = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        input.placeholderString = "解压密码"
        alert.accessoryView = input
        alert.addButton(withTitle: "解压"); alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = input
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return input.stringValue
    }
    @discardableResult func archiveAction(_ action: String) -> Bool {
        let formatID = action.hasPrefix("compress.") ? String(action.dropFirst("compress.".count)) : nil
        guard action == "extract" || formatID != nil else { return false }
        guard !busy, !recorder.isBusy, !recorder.isRecording, !scroll.isActive else { return true }
        let format = formatID.flatMap { id in ArchiveFormat.available.first { $0.id == id } }
        if formatID != nil, format == nil { fail("此压缩格式在本机不可用"); return true }
        if selectedFiles.isEmpty { chooseFiles() }
        guard !selectedFiles.isEmpty else { return true }
        let sources = selectedFiles
        busy = true
        let title = format == nil ? "正在解压…" : "正在压缩…"
        status = title
        NSApp.activate(ignoringOtherApps: true)
        let progress = ArchiveProgressWindow(title, detail: "共 \(sources.count) 个选中项目。完成后会在 Finder 中显示结果；原文件保持不变。")
        Task { @MainActor [self] in
            let outcome = await Task.detached(priority: .userInitiated) {
                var outputs: [URL] = []
                var failures: [String] = []
                if let format {
                    do {
                        let parent = sources[0].deletingLastPathComponent()
                        let name = sources.count == 1 ? sources[0].lastPathComponent : "Archive"
                        let destination = try ArchiveDestination.uniqueURL(in: parent, base: name, suffix: format.fileExtension)
                        try ArchiveService.compress(sources, format: format, destination: destination)
                        outputs.append(destination)
                    } catch { failures.append(error.localizedDescription) }
                } else {
                    for source in sources {
                        do {
                            let destination = try ArchiveDestination.uniqueURL(in: source.deletingLastPathComponent(), base: ArchiveDestination.extractionName(source.lastPathComponent))
                            var password: String?
                            var completed = false
                            for attempt in 0..<4 {
                                do {
                                    try ArchiveService.extract(source, destination: destination, password: password)
                                    completed = true
                                    break
                                } catch SevenZipService.Failure.passwordRequired where attempt < 3 {
                                    password = await MainActor.run { Self.archivePassword(for: source.lastPathComponent, retry: attempt > 0) }
                                    guard password != nil else { throw ArchiveService.Failure(message: "已取消输入解压密码") }
                                }
                            }
                            if completed { outputs.append(destination) }
                        } catch { failures.append(source.lastPathComponent + "：" + error.localizedDescription) }
                    }
                }
                return (outputs, failures)
            }.value
            progress.close(); busy = false
            if !outcome.0.isEmpty {
                status = "归档处理完成，共生成 \(outcome.0.count) 项"
                NSWorkspace.shared.activateFileViewerSelecting(outcome.0)
            }
            if !outcome.1.isEmpty {
                let detail = outcome.1.prefix(5).joined(separator: "\n")
                fail((outcome.0.isEmpty ? "" : "已完成 \(outcome.0.count) 项，部分处理失败：\n") + detail)
            }
        }
        return true
    }
}
