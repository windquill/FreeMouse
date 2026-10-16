import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Local, independently generated documents and image exports. No source file is overwritten.
enum TemplateImageTools {
    enum TemplateKind: String, CaseIterable {
        case txt, rtf, md, xml, docx, xlsx, pptx, json, html, css, js, py, sh, cpp, svg, csv, yaml
        var title: String {
            switch self {
            case .docx: return "Word 文档 (.docx)"
            case .xlsx: return "Excel 工作簿 (.xlsx)"
            case .pptx: return "PowerPoint 演示 (.pptx)"
            case .txt: return "纯文本 (.txt)"
            case .rtf: return "富文本 (.rtf)"
            case .md: return "Markdown (.md)"
            default: return rawValue.uppercased() + " (." + rawValue + ")"
            }
        }
    }
    enum ImageFormat: String, CaseIterable {
        case png, jpeg, tiff, bmp, gif, heic, icns
        var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
        var type: UTType {
            switch self {
            case .png: return .png
            case .jpeg: return .jpeg
            case .tiff: return .tiff
            case .bmp: return .bmp
            case .gif: return .gif
            case .heic: return .heic
            case .icns: return .icns
            }
        }
    }
    enum IconPlatform: String, CaseIterable { case macOS, iOS, watchOS }

    static func templateData(_ kind: TemplateKind) throws -> Data {
        switch kind {
        case .docx, .xlsx, .pptx: return try storedZIP(officeParts(kind))
        case .txt: return Data()
        case .rtf: return Data(#"{\rtf1\ansi\deff0{\fonttbl{\f0 Helvetica;}}\f0\fs24\par}"#.utf8)
        case .md: return Data("# 新建文稿\n\n".utf8)
        case .xml: return Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<document/>\n".utf8)
        case .json: return Data("{}\n".utf8)
        case .html: return Data("<!doctype html>\n<html lang=\"zh-CN\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><title>新建页面</title></head><body>\n</body></html>\n".utf8)
        case .css: return Data("/* 样式 */\n".utf8)
        case .js: return Data("\"use strict\";\n".utf8)
        case .py: return Data("# Python 3\n".utf8)
        case .sh: return Data("#!/bin/sh\n# 在此编写命令；新建文件不会自动执行。\n".utf8)
        case .cpp: return Data("int main() {\n    return 0;\n}\n".utf8)
        case .svg: return Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"512\" height=\"512\" viewBox=\"0 0 512 512\"></svg>\n".utf8)
        case .csv: return Data("名称,内容\n".utf8)
        case .yaml: return Data("---\n{}\n".utf8)
        }
    }

    static func createTemplate(_ kind: TemplateKind, name: String, in directory: URL) throws -> URL {
        let output = try FileTools.uniqueURL(in: directory, name: filename(name, extension: kind.rawValue))
        try templateData(kind).write(to: output, options: .withoutOverwriting)
        return output
    }

    static func copyTemplate(_ source: URL, name: String, in directory: URL) throws -> URL {
        let properties = try source.resourceValues(forKeys: [.isRegularFileKey, .isPackageKey, .isSymbolicLinkKey])
        guard properties.isSymbolicLink != true, properties.isRegularFile == true || properties.isPackage == true else {
            throw FileToolError.message("请选择一个模板文件或 Pages 等文稿包，不能使用普通文件夹或符号链接。")
        }
        let output = try FileTools.uniqueURL(in: directory, name: filename(name, extension: source.pathExtension))
        // copyItem refuses an existing destination, including a race after uniqueURL.
        try FileManager.default.copyItem(at: source, to: output)
        return output
    }

    private static func filename(_ name: String, extension ext: String) throws -> String {
        try FileTools.validateName(name)
        guard !ext.isEmpty else { return name }
        let result = (name as NSString).pathExtension.lowercased() == ext.lowercased() ? name : name + "." + ext
        try FileTools.validateName(result)
        return result
    }

    static func validateImageDimensions(width: Int, height: Int) throws {
        guard width > 0, height > 0, width <= 40_000_000, height <= 40_000_000,
              width <= 40_000_000 / height else {
            throw FileToolError.message("图片超过 4000 万像素或尺寸无效。")
        }
    }

    static func exportImage(_ image: CGImage, format: ImageFormat, in directory: URL, name: String) throws -> URL {
        try validateImageDimensions(width: image.width, height: image.height)
        let data = format == .icns ? try icnsData(image) : try encoded(image, format: format)
        let output = try FileTools.uniqueURL(in: directory, name: filename(name, extension: format.fileExtension))
        try data.write(to: output, options: .withoutOverwriting)
        return output
    }

    private static func encoded(_ image: CGImage, format: ImageFormat) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, format.type.identifier as CFString, 1, nil) else {
            throw FileToolError.message("本机不支持 \(format.rawValue.uppercased()) 编码，请选择其他格式。")
        }
        let actual: CGImage
        if format == .jpeg || format == .bmp { actual = try resized(image, width: image.width, height: image.height, opaque: true) }
        else { actual = image }
        CGImageDestinationAddImage(destination, actual, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw FileToolError.message("\(format.rawValue.uppercased()) 编码失败；原图未修改。") }
        return output as Data
    }

    /// Fits the source into a square without cropping; iOS/watchOS exports use an opaque white background.
    private static func resized(_ image: CGImage, width: Int, height: Int, opaque: Bool = false) throws -> CGImage {
        try validateImageDimensions(width: width, height: height)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: (opaque ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast).rawValue) else {
            throw FileToolError.message("无法创建图片画布。")
        }
        if opaque { context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height)) }
        context.interpolationQuality = .high
        let ratio = min(Double(width) / Double(image.width), Double(height) / Double(image.height))
        let w = Double(image.width) * ratio, h = Double(image.height) * ratio
        context.draw(image, in: CGRect(x: (Double(width) - w) / 2, y: (Double(height) - h) / 2, width: w, height: h))
        guard let result = context.makeImage() else { throw FileToolError.message("图片缩放失败。") }
        return result
    }

    static func icnsData(_ image: CGImage) throws -> Data {
        try validateImageDimensions(width: image.width, height: image.height)
        let representations: [(String, Int)] = [("icp4", 16), ("icp5", 32), ("icp6", 64), ("ic07", 128), ("ic08", 256), ("ic09", 512), ("ic10", 1024)]
        var chunks = Data()
        for (tag, size) in representations {
            let png = try encoded(resized(image, width: size, height: size), format: .png)
            chunks.append(Data(tag.utf8)); chunks.appendBE(UInt32(png.count + 8)); chunks.append(png)
        }
        var data = Data("icns".utf8)
        data.appendBE(UInt32(chunks.count + 8)); data.append(chunks)
        return data
    }

    private struct IconEntry {
        let name: String
        let pixels: Int
        let metadata: [String: String]
    }
    static func exportIconSet(_ image: CGImage, platform: IconPlatform, in directory: URL, name: String) throws -> URL {
        try validateImageDimensions(width: image.width, height: image.height)
        try FileTools.validateName(name)
        let ext = platform == .macOS ? "iconset" : "appiconset"
        let output = try FileTools.uniqueURL(in: directory, name: filename(name + "-" + platform.rawValue, extension: ext))
        let staging = directory.appendingPathComponent(".freemouse-icons-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: staging) }
        let entries = iconEntries(platform)
        for entry in entries {
            let data = try encoded(resized(image, width: entry.pixels, height: entry.pixels, opaque: platform != .macOS), format: .png)
            try data.write(to: staging.appendingPathComponent(entry.name), options: .withoutOverwriting)
        }
        if platform != .macOS {
            let images: [[String: String]] = entries.map { entry in var item = entry.metadata; item["filename"] = entry.name; return item }
            let metadata: [String: Any] = ["images": images, "info": ["version": 1, "author": "FreeMouse"]]
            try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]).write(to: staging.appendingPathComponent("Contents.json"), options: .withoutOverwriting)
        }
        try FileManager.default.moveItem(at: staging, to: output)
        return output
    }

    private static func iconEntries(_ platform: IconPlatform) -> [IconEntry] {
        if platform == .macOS {
            return [16, 32, 128, 256, 512].flatMap { point in
                [1, 2].map { scale in IconEntry(name: "icon_\(point)x\(point)" + (scale == 2 ? "@2x" : "") + ".png", pixels: point * scale, metadata: [:]) }
            }
        }
        var entries: [IconEntry] = []
        func add(_ idiom: String, _ size: String, _ scales: [Int], role: String? = nil, subtype: String? = nil) {
            for scale in scales {
                var metadata = ["idiom": idiom, "size": size + "x" + size, "scale": "\(scale)x"]
                if let role { metadata["role"] = role }
                if let subtype { metadata["subtype"] = subtype }
                let name = ([idiom, role, subtype, size + "@\(scale)x"].compactMap { $0 }).joined(separator: "-") + ".png"
                entries.append(IconEntry(name: name, pixels: Int((Double(size)! * Double(scale)).rounded()), metadata: metadata))
            }
        }
        if platform == .iOS {
            for size in ["20", "29", "40", "60"] { add("iphone", size, [2, 3]) }
            for size in ["20", "29", "40", "76"] { add("ipad", size, [1, 2]) }
            add("ipad", "83.5", [2]); add("ios-marketing", "1024", [1])
        } else {
            add("watch", "24", [2], role: "notificationCenter", subtype: "38mm")
            add("watch", "27.5", [2], role: "notificationCenter", subtype: "42mm")
            add("watch", "29", [2, 3], role: "companionSettings")
            for (size, subtype) in [("40", "38mm"), ("44", "40mm"), ("46", "41mm"), ("50", "44mm"), ("51", "45mm"), ("54", "49mm")] {
                add("watch", size, [2], role: "appLauncher", subtype: subtype)
            }
            for (size, subtype) in [("86", "38mm"), ("98", "42mm"), ("108", "44mm"), ("117", "45mm"), ("129", "49mm")] {
                add("watch", size, [2], role: "quickLook", subtype: subtype)
            }
            add("watch-marketing", "1024", [1])
        }
        return entries
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in data { crc = (crc >> 8) ^ crcTable[Int((crc ^ UInt32(byte)) & 0xff)] }
        return crc ^ 0xffffffff
    }
    private static let crcTable: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 { crc = (crc & 1) == 1 ? 0xedb88320 ^ (crc >> 1) : crc >> 1 }
        return crc
    }

    private static func storedZIP(_ parts: [String: String]) throws -> Data {
        var zip = Data(), central = Data()
        for name in parts.keys.sorted() {
            let payload = Data(parts[name]!.utf8), path = Data(name.utf8)
            guard payload.count <= Int(UInt32.max), path.count <= Int(UInt16.max), zip.count <= Int(UInt32.max) else { throw FileToolError.message("模板过大。") }
            let checksum = crc32(payload), length = UInt32(payload.count), offset = UInt32(zip.count)
            zip.appendLE(UInt32(0x04034b50)); zip.appendLE(UInt16(20)); zip.appendLE(UInt16(0x0800)); zip.appendLE(UInt16(0))
            zip.appendLE(UInt16(0)); zip.appendLE(UInt16(0x0021)); zip.appendLE(checksum); zip.appendLE(length); zip.appendLE(length)
            zip.appendLE(UInt16(path.count)); zip.appendLE(UInt16(0)); zip.append(path); zip.append(payload)
            central.appendLE(UInt32(0x02014b50)); central.appendLE(UInt16(20)); central.appendLE(UInt16(20)); central.appendLE(UInt16(0x0800)); central.appendLE(UInt16(0))
            central.appendLE(UInt16(0)); central.appendLE(UInt16(0x0021)); central.appendLE(checksum); central.appendLE(length); central.appendLE(length)
            central.appendLE(UInt16(path.count)); central.appendLE(UInt16(0)); central.appendLE(UInt16(0)); central.appendLE(UInt16(0)); central.appendLE(UInt16(0)); central.appendLE(UInt32(0)); central.appendLE(offset); central.append(path)
        }
        let centralOffset = UInt32(zip.count)
        zip.append(central); zip.appendLE(UInt32(0x06054b50)); zip.appendLE(UInt16(0)); zip.appendLE(UInt16(0))
        zip.appendLE(UInt16(parts.count)); zip.appendLE(UInt16(parts.count)); zip.appendLE(UInt32(central.count)); zip.appendLE(centralOffset); zip.appendLE(UInt16(0))
        return zip
    }

    private static let xmlDeclaration = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
    private static let relationshipNS = "http://schemas.openxmlformats.org/package/2006/relationships"
    private static let officeRelationshipNS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    private static func relationships(_ values: [(String, String, String)]) -> String {
        xmlDeclaration + "<Relationships xmlns=\"\(relationshipNS)\">" + values.map { "<Relationship Id=\"\($0.0)\" Type=\"\(officeRelationshipNS)/\($0.1)\" Target=\"\($0.2)\"/>" }.joined() + "</Relationships>"
    }
    private static func officeParts(_ kind: TemplateKind) -> [String: String] {
        var parts: [String: String] = [:]
        var overrides: [(String, String)] = []
        func add(_ name: String, _ type: String, _ body: String) { parts[name] = xmlDeclaration + body; overrides.append((name, type)) }
        let main: String
        if kind == .docx {
            main = "word/document.xml"
            add(main, "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml", "<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body><w:p/><w:sectPr><w:pgSz w:w=\"11906\" w:h=\"16838\"/><w:pgMar w:top=\"1440\" w:right=\"1440\" w:bottom=\"1440\" w:left=\"1440\" w:header=\"720\" w:footer=\"720\" w:gutter=\"0\"/></w:sectPr></w:body></w:document>")
        } else if kind == .xlsx {
            main = "xl/workbook.xml"
            add(main, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml", "<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"\(officeRelationshipNS)\"><sheets><sheet name=\"Sheet1\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>")
            add("xl/worksheets/sheet1.xml", "application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml", "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><dimension ref=\"A1\"/><sheetViews><sheetView workbookViewId=\"0\"/></sheetViews><sheetFormatPr defaultRowHeight=\"15\"/><sheetData/></worksheet>")
            parts["xl/_rels/workbook.xml.rels"] = relationships([("rId1", "worksheet", "worksheets/sheet1.xml")])
        } else {
            main = "ppt/presentation.xml"
            let ns = "xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:r=\"\(officeRelationshipNS)\" xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\""
            let tree = "<p:spTree><p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"0\" cy=\"0\"/><a:chOff x=\"0\" y=\"0\"/><a:chExt cx=\"0\" cy=\"0\"/></a:xfrm></p:grpSpPr></p:spTree>"
            let map = "<p:clrMap accent1=\"accent1\" accent2=\"accent2\" accent3=\"accent3\" accent4=\"accent4\" accent5=\"accent5\" accent6=\"accent6\" bg1=\"lt1\" bg2=\"lt2\" folHlink=\"folHlink\" hlink=\"hlink\" tx1=\"dk1\" tx2=\"dk2\"/>"
            add(main, "application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml", "<p:presentation \(ns)><p:sldMasterIdLst><p:sldMasterId id=\"2147483648\" r:id=\"rId1\"/></p:sldMasterIdLst><p:sldIdLst><p:sldId id=\"256\" r:id=\"rId2\"/></p:sldIdLst><p:sldSz cx=\"12192000\" cy=\"6858000\"/><p:notesSz cx=\"6858000\" cy=\"9144000\"/></p:presentation>")
            add("ppt/slides/slide1.xml", "application/vnd.openxmlformats-officedocument.presentationml.slide+xml", "<p:sld \(ns)><p:cSld>\(tree)</p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>")
            add("ppt/slideMasters/slideMaster1.xml", "application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml", "<p:sldMaster \(ns)><p:cSld>\(tree)</p:cSld>\(map)<p:sldLayoutIdLst><p:sldLayoutId id=\"2147483649\" r:id=\"rId1\"/></p:sldLayoutIdLst><p:txStyles><p:titleStyle/><p:bodyStyle/><p:otherStyle/></p:txStyles></p:sldMaster>")
            add("ppt/slideLayouts/slideLayout1.xml", "application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml", "<p:sldLayout \(ns) type=\"blank\" preserve=\"1\"><p:cSld name=\"空白\">\(tree)</p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>")
            add("ppt/theme/theme1.xml", "application/vnd.openxmlformats-officedocument.theme+xml", presentationTheme())
            parts["ppt/_rels/presentation.xml.rels"] = relationships([("rId1", "slideMaster", "slideMasters/slideMaster1.xml"), ("rId2", "slide", "slides/slide1.xml")])
            parts["ppt/slides/_rels/slide1.xml.rels"] = relationships([("rId1", "slideLayout", "../slideLayouts/slideLayout1.xml")])
            parts["ppt/slideMasters/_rels/slideMaster1.xml.rels"] = relationships([("rId1", "slideLayout", "../slideLayouts/slideLayout1.xml"), ("rId2", "theme", "../theme/theme1.xml")])
            parts["ppt/slideLayouts/_rels/slideLayout1.xml.rels"] = relationships([("rId1", "slideMaster", "../slideMasters/slideMaster1.xml")])
        }
        parts["_rels/.rels"] = relationships([("rId1", "officeDocument", main)])
        parts["[Content_Types].xml"] = xmlDeclaration + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/>" + overrides.map { "<Override PartName=\"/\($0.0)\" ContentType=\"\($0.1)\"/>" }.joined() + "</Types>"
        return parts
    }

    private static func presentationTheme() -> String {
        let colors = [("dk1", "000000"), ("lt1", "FFFFFF"), ("dk2", "1E293B"), ("lt2", "F1F5F9"), ("accent1", "2563EB"), ("accent2", "0D9488"), ("accent3", "F59E0B"), ("accent4", "7C3AED"), ("accent5", "E11D48"), ("accent6", "0284C7"), ("hlink", "0000FF"), ("folHlink", "800080")]
        let scheme = colors.map { "<a:\($0.0)><a:srgbClr val=\"\($0.1)\"/></a:\($0.0)>" }.joined()
        let font = "<a:latin typeface=\"Arial\"/><a:ea typeface=\"\"/><a:cs typeface=\"\"/>"
        let fill = "<a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill>"
        let line = "<a:ln w=\"9525\" cap=\"flat\" cmpd=\"sng\" algn=\"ctr\">\(fill)<a:prstDash val=\"solid\"/><a:miter lim=\"800000\"/><a:headEnd type=\"none\" w=\"med\" len=\"med\"/><a:tailEnd type=\"none\" w=\"med\" len=\"med\"/></a:ln>"
        let effect = "<a:effectStyle><a:effectLst/></a:effectStyle>"
        return "<a:theme xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" name=\"自在\"><a:themeElements><a:clrScheme name=\"自在\">\(scheme)</a:clrScheme><a:fontScheme name=\"Arial\"><a:majorFont>\(font)</a:majorFont><a:minorFont>\(font)</a:minorFont></a:fontScheme><a:fmtScheme name=\"自在\"><a:fillStyleLst>\(String(repeating: fill, count: 3))</a:fillStyleLst><a:lnStyleLst>\(String(repeating: line, count: 3))</a:lnStyleLst><a:effectStyleLst>\(String(repeating: effect, count: 3))</a:effectStyleLst><a:bgFillStyleLst>\(String(repeating: fill, count: 3))</a:bgFillStyleLst></a:fmtScheme></a:themeElements><a:objectDefaults/><a:extraClrSchemeLst/></a:theme>"
    }
}

/// Stores copies made by an explicit import action, so moving the original never breaks a template.
final class TemplateLibrary {
    struct Record: Codable, Equatable, Identifiable {
        let id: UUID
        var title: String
        let filename: String
        var enabled: Bool
    }
    let directory: URL
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("local.freemouse.toolbox/Templates", isDirectory: true)
    }
    private var metadataURL: URL { directory.appendingPathComponent("templates.json") }
    func records() throws -> [Record] {
        guard FileManager.default.fileExists(atPath: metadataURL.path) else { return [] }
        let records = try JSONDecoder().decode([Record].self, from: Data(contentsOf: metadataURL))
        for record in records { try FileTools.validateName(record.filename) }
        return records
    }
    func sourceURL(for record: Record) throws -> URL {
        try FileTools.validateName(record.filename)
        return directory.appendingPathComponent(record.filename)
    }
    @discardableResult func importTemplate(_ source: URL, title: String) throws -> Record {
        try FileTools.validateName(title)
        var saved = try records()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID()
        let copied = try TemplateImageTools.copyTemplate(source, name: id.uuidString, in: directory)
        let record = Record(id: id, title: title, filename: copied.lastPathComponent, enabled: true)
        saved.append(record)
        do { try persist(saved) }
        catch { try? FileManager.default.removeItem(at: copied); throw error }
        return record
    }
    func update(id: UUID, title: String, enabled: Bool) throws {
        try FileTools.validateName(title)
        var saved = try records()
        guard let index = saved.firstIndex(where: { $0.id == id }) else { throw FileToolError.message("模板已不存在，请重新打开模板列表。") }
        saved[index].title = title; saved[index].enabled = enabled
        try persist(saved)
    }
    private func persist(_ records: [Record]) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(records).write(to: metadataURL, options: .atomic)
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        for shift in stride(from: 0, to: T.bitWidth, by: 8) { append(UInt8(truncatingIfNeeded: value >> shift)) }
    }
    mutating func appendBE(_ value: UInt32) {
        for shift in stride(from: 24, through: 0, by: -8) { append(UInt8(truncatingIfNeeded: value >> shift)) }
    }
}

@MainActor
extension AppModel {
    @discardableResult func templateImageAction(_ action: String) -> Bool {
        let quickKind = action.hasPrefix("newTemplate.") ? TemplateImageTools.TemplateKind(rawValue: String(action.dropFirst("newTemplate.".count))) : nil
        guard quickKind != nil || ["newTemplate", "customTemplate", "convertImage", "iconSetExport"].contains(action) else { return false }
        guard !busy else { return true }
        do {
            switch quickKind == nil ? action : "newTemplate" {
            case "newTemplate":
                guard let directory = templateDestination("选择新文稿的保存文件夹") else { return true }
                let alert = NSAlert(); alert.messageText = quickKind.map { "新建" + $0.title } ?? "新建模板文稿"
                alert.informativeText = "保存到：\(directory.path)" + (quickKind == nil ? "\nPages、Numbers、Keynote、WPS、Ai、PSD 可通过“自定义模板”复制已有的有效文稿。" : "")
                let box = NSView(frame: CGRect(x: 0, y: 0, width: 390, height: quickKind == nil ? 74 : 34))
                let picker = NSPopUpButton(frame: CGRect(x: 0, y: 42, width: 390, height: 28))
                picker.addItems(withTitles: TemplateImageTools.TemplateKind.allCases.map(\.title))
                if quickKind == nil { box.addSubview(picker) }
                let field = NSTextField(string: "新建文稿"); field.frame = CGRect(x: 0, y: 4, width: 390, height: 26); box.addSubview(field)
                alert.accessoryView = box; alert.addButton(withTitle: "创建"); alert.addButton(withTitle: "取消")
                guard alert.runModal() == .alertFirstButtonReturn else { return true }
                let kind = quickKind ?? TemplateImageTools.TemplateKind.allCases[picker.indexOfSelectedItem]
                let url = try TemplateImageTools.createTemplate(kind, name: field.stringValue, in: directory)
                remember(url); status = "已创建：\(url.lastPathComponent)"; NSWorkspace.shared.activateFileViewerSelecting([url])
                if UserDefaults.standard.bool(forKey: "creationSound") { NSSound.beep() }
            case "customTemplate":
                try customTemplateLibraryAction()
            default:
                let images = selectedFiles.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
                let sources: [URL]
                if images.isEmpty {
                    let open = NSOpenPanel(); open.allowedContentTypes = [.image]; open.allowsMultipleSelection = action == "convertImage"
                    guard open.runModal() == .OK else { return true }; sources = open.urls
                } else { sources = action == "iconSetExport" ? Array(images.prefix(1)) : images }
                let alert = NSAlert(); alert.messageText = action == "convertImage" ? "转换图片格式" : "导出图标集"
                alert.informativeText = action == "convertImage" ? "保留原图；转换静态首帧。JPEG、BMP 使用白色背景；已有同名文件自动编号。" : "导出第一个选中图片；按比例居中，保持原图。iOS/watchOS 使用白色背景。"
                let picker = NSPopUpButton(frame: CGRect(x: 0, y: 0, width: 320, height: 28))
                picker.addItems(withTitles: action == "convertImage" ? TemplateImageTools.ImageFormat.allCases.map { $0.rawValue.uppercased() } : TemplateImageTools.IconPlatform.allCases.map(\.rawValue))
                alert.accessoryView = picker; alert.addButton(withTitle: "选择保存位置"); alert.addButton(withTitle: "取消")
                guard alert.runModal() == .alertFirstButtonReturn,
                      let directory = templateDestination("选择导出文件夹", useSelectedDirectory: false) else { return true }
                busy = true; status = "正在导出图片…"
                let format = TemplateImageTools.ImageFormat.allCases[min(picker.indexOfSelectedItem, TemplateImageTools.ImageFormat.allCases.count - 1)]
                let platform = TemplateImageTools.IconPlatform.allCases[min(picker.indexOfSelectedItem, TemplateImageTools.IconPlatform.allCases.count - 1)]
                Task { @MainActor in
                    do {
                        let outputs = try await Task.detached(priority: .userInitiated) {
                            try sources.map { source in
                                try autoreleasepool {
                                    let image = try FileTools.loadImage(source)
                                    let name = source.deletingPathExtension().lastPathComponent
                                    return action == "convertImage" ? try TemplateImageTools.exportImage(image, format: format, in: directory, name: name) : try TemplateImageTools.exportIconSet(image, platform: platform, in: directory, name: name)
                                }
                            }
                        }.value
                        busy = false; outputs.forEach { remember($0) }; status = "已导出 \(outputs.count) 项；原文件保留"
                        NSWorkspace.shared.activateFileViewerSelecting(outputs)
                    } catch { fail(error.localizedDescription) }
                }
            }
        } catch { fail(error.localizedDescription) }
        return true
    }

    private func templateDestination(_ message: String, useSelectedDirectory: Bool = true) -> URL? {
        let selectedDirectory = selectedFiles.first(where: { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true })
        if useSelectedDirectory, let selectedDirectory { return selectedDirectory }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.message = message
        panel.directoryURL = selectedDirectory ?? selectedFiles.first?.deletingLastPathComponent()
        guard panel.runModal() == .OK else { return nil }; return panel.url
    }

    private func customTemplateLibraryAction() throws {
        let library = TemplateLibrary()
        while true {
            let enabled = try library.records().filter(\.enabled)
            let alert = NSAlert(); alert.messageText = "自定义模板"
            alert.informativeText = "导入会保存一份独立副本。支持 Pages、Numbers、Keynote、WPS、Ai、PSD 等有效文稿；可管理名称和启用状态。"
            let picker = NSPopUpButton(frame: CGRect(x: 0, y: 0, width: 390, height: 28))
            picker.addItems(withTitles: enabled.isEmpty ? ["尚无启用的模板，请先导入"] : enabled.map(\.title))
            alert.accessoryView = picker
            alert.addButton(withTitle: "从模板新建").isEnabled = !enabled.isEmpty
            alert.addButton(withTitle: "导入模板")
            alert.addButton(withTitle: "管理模板")
            alert.addButton(withTitle: "关闭")
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                guard !enabled.isEmpty, let directory = templateDestination("选择新文稿的保存文件夹") else { return }
                let record = enabled[picker.indexOfSelectedItem]
                let nameAlert = NSAlert(); nameAlert.messageText = "从“\(record.title)”新建"
                nameAlert.informativeText = "保存到：\(directory.path)\n模板和已有同名文件都会保留。"
                let field = NSTextField(string: record.title); field.frame = CGRect(x: 0, y: 0, width: 390, height: 26)
                nameAlert.accessoryView = field; nameAlert.addButton(withTitle: "创建"); nameAlert.addButton(withTitle: "取消")
                guard nameAlert.runModal() == .alertFirstButtonReturn else { continue }
                let url = try TemplateImageTools.copyTemplate(library.sourceURL(for: record), name: field.stringValue, in: directory)
                remember(url); status = "已从模板创建：\(url.lastPathComponent)"
                if UserDefaults.standard.bool(forKey: "creationSound") { NSSound.beep() }
                NSWorkspace.shared.activateFileViewerSelecting([url]); return
            } else if response == .alertSecondButtonReturn {
                let open = NSOpenPanel(); open.title = "导入模板文稿"; open.canChooseDirectories = false; open.treatsFilePackagesAsDirectories = false
                guard open.runModal() == .OK, let source = open.url else { continue }
                try library.importTemplate(source, title: source.deletingPathExtension().lastPathComponent)
                status = "已导入模板：\(source.lastPathComponent)"
            } else if response == .alertThirdButtonReturn {
                let records = try library.records()
                guard !records.isEmpty else { status = "请先导入模板"; continue }
                let choose = NSAlert(); choose.messageText = "选择要管理的模板"
                let list = NSPopUpButton(frame: CGRect(x: 0, y: 0, width: 390, height: 28))
                list.addItems(withTitles: records.map { $0.title + ($0.enabled ? " · 已启用" : " · 已停用") })
                choose.accessoryView = list; choose.addButton(withTitle: "编辑"); choose.addButton(withTitle: "返回")
                guard choose.runModal() == .alertFirstButtonReturn else { continue }
                let record = records[list.indexOfSelectedItem]
                let edit = NSAlert(); edit.messageText = "模板名称与状态"
                let box = NSView(frame: CGRect(x: 0, y: 0, width: 390, height: 66))
                let name = NSTextField(string: record.title); name.frame = CGRect(x: 0, y: 36, width: 390, height: 26)
                let toggle = NSButton(checkboxWithTitle: "在模板新建列表中启用", target: nil, action: nil)
                toggle.state = record.enabled ? .on : .off; toggle.frame = CGRect(x: 0, y: 0, width: 390, height: 26)
                box.addSubview(name); box.addSubview(toggle); edit.accessoryView = box
                edit.addButton(withTitle: "保存"); edit.addButton(withTitle: "取消")
                if edit.runModal() == .alertFirstButtonReturn {
                    try library.update(id: record.id, title: name.stringValue, enabled: toggle.state == .on)
                    status = "模板设置已保存"
                }
            } else { return }
        }
    }
}
