import Foundation
import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

enum FileToolError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}
enum FileTools {
    static func stackDimensions(_ sizes: [CGSize]) throws -> (width: Int, heights: [Int]) {
        guard !sizes.isEmpty, sizes.count <= 200,
              sizes.allSatisfy({ $0.width.isFinite && $0.height.isFinite && $0.width >= 1 && $0.height >= 1 && $0.width * $0.height <= 40_000_000 }) else {
            throw FileToolError.message("图片数量或尺寸超出安全范围。")
        }
        let width = sizes.map(\.width).max()!
        let scaled = sizes.map { ($0.height * width / $0.width).rounded() }
        let total = scaled.reduce(0, +)
        guard total.isFinite, total >= 1, total < 65536, width * total <= 40_000_000 else {
            throw FileToolError.message("拼接结果过大，请减少图片数量（上限 4000 万像素）。")
        }
        return (Int(width), scaled.map(Int.init))
    }
    static func stackImageFiles(_ urls: [URL]) throws -> CGImage {
        let sizes: [CGSize] = try urls.map { url in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int else {
                throw FileToolError.message("无法读取图片尺寸：\(url.lastPathComponent)")
            }
            let rotated = (5...8).contains(p[kCGImagePropertyOrientation] as? Int ?? 1)
            return CGSize(width: rotated ? h : w, height: rotated ? w : h)
        }
        let plan = try stackDimensions(sizes)
        let height = plan.heights.reduce(0, +)
        guard let context = CGContext(data: nil, width: plan.width, height: height, bitsPerComponent: 8, bytesPerRow: plan.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw FileToolError.message("无法分配图片内存。") }
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: plan.width, height: height))
        var y = height
        for (url, h) in zip(urls, plan.heights) {
            y -= h
            try autoreleasepool {
                let image = try loadImage(url)
                context.draw(image, in: CGRect(x: 0, y: y, width: plan.width, height: h))
            }
        }
        guard let image = context.makeImage() else { throw FileToolError.message("无法合成图片。") }
        return image
    }
    static func validateName(_ name: String) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains(":"), !name.contains("\0"), name.utf8.count <= 240 else { throw FileToolError.message("文件名不能为空、包含路径分隔符，或过长。") }
    }
    static func uniqueURL(in directory: URL, name: String) throws -> URL {
        try validateName(name)
        let initial = directory.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: initial.path) { return initial }
        let ext = initial.pathExtension, stem = initial.deletingPathExtension().lastPathComponent
        for i in 2...10000 {
            let candidate = directory.appendingPathComponent(stem + " \(i)" + (ext.isEmpty ? "" : "." + ext))
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        throw FileToolError.message("同名文件过多，请更换名称。")
    }
    static func createFile(in directory: URL, name: String, contents: String) throws -> URL {
        let url = try uniqueURL(in: directory, name: name)
        try Data(contents.utf8).write(to: url, options: [.withoutOverwriting])
        return url
    }
    static func createFolder(in directory: URL, name: String) throws -> URL {
        let url = try uniqueURL(in: directory, name: name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
    static func renamePlan(_ urls: [URL], prefix: String, suffix: String) throws -> [(URL, URL)] {
        var used = Set<String>(); var result: [(URL, URL)] = []
        for url in urls {
            let resource = try url.resourceValues(forKeys: [.isDirectoryKey])
            let ext = resource.isDirectory == true ? "" : url.pathExtension
            let stem = ext.isEmpty ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
            let name = prefix + stem + suffix + (ext.isEmpty ? "" : "." + ext)
            try validateName(name)
            let target = url.deletingLastPathComponent().appendingPathComponent(name)
            if target.standardizedFileURL == url.standardizedFileURL { continue }
            guard used.insert(target.path.lowercased()).inserted, !FileManager.default.fileExists(atPath: target.path) else { throw FileToolError.message("目标名称已存在：\(name)。未修改任何文件。") }
            result.append((url, target))
        }
        return result
    }
    static func executeRename(_ plan: [(URL, URL)]) throws {
        for (source, target) in plan {
            guard FileManager.default.fileExists(atPath: source.path), !FileManager.default.fileExists(atPath: target.path) else { throw FileToolError.message("文件状态已改变，请重新预览；尚未开始重命名。") }
        }
        var completed: [(URL, URL)] = []
        do {
            for pair in plan { try FileManager.default.moveItem(at: pair.0, to: pair.1); completed.append(pair) }
        } catch {
            var rollbackFailures: [String] = []
            for pair in completed.reversed() {
                do { try FileManager.default.moveItem(at: pair.1, to: pair.0) } catch { rollbackFailures.append(pair.1.path) }
            }
            throw FileToolError.message("重命名失败：\(error.localizedDescription)" + (rollbackFailures.isEmpty ? "\n已还原已完成的变更。" : "\n以下文件未能还原：\n" + rollbackFailures.joined(separator: "\n")))
        }
    }
    static func sha256(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func loadImage(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0, w <= (Int.max / 4) / h else {
            throw FileToolError.message("图片无法打开，或尺寸超出可处理范围：\(url.lastPathComponent)")
        }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: max(w,h), kCGImageSourceCreateThumbnailWithTransform: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) else { throw FileToolError.message("图片解码失败。") }
        return image
    }
    static func stackImages(_ images: [CGImage]) throws -> CGImage {
        guard !images.isEmpty else { throw FileToolError.message("请选择至少一张图片。") }
        let width = images.map(\.width).max() ?? 1
        let heights = images.map { Int((Double($0.height) * Double(width) / Double($0.width)).rounded()) }
        let height = heights.reduce(0, +)
        guard height > 0, Double(width) * Double(height) <= 40_000_000, height < 65536 else { throw FileToolError.message("拼接结果过大，请减少图片数量（上限 4000 万像素）。") }
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw FileToolError.message("无法分配图片内存。") }
        context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        var y = height
        for (image, h) in zip(images, heights) { y -= h; context.draw(image, in: CGRect(x: 0, y: y, width: width, height: h)) }
        guard let result = context.makeImage() else { throw FileToolError.message("无法合成图片。") }
        return result
    }
    static func exportImage(_ image: CGImage, in directory: URL, name: String, jpeg: Bool) throws -> URL {
        let url = try uniqueURL(in: directory, name: name + (jpeg ? ".jpg" : ".png"))
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, (jpeg ? UTType.jpeg.identifier : UTType.png.identifier) as CFString, 1, nil) else { throw FileToolError.message("图片编码器不可用。") }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw FileToolError.message("图片编码失败。") }
        try (data as Data).write(to: url, options: .withoutOverwriting)
        return url
    }
}
