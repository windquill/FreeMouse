import AppKit
import Foundation
import ImageIO
import Testing
@testable import FreeMouse

struct TemplateImageToolsTests {
    @Test func importedTemplatesPersistIndependentCopiesAndEnabledNames() throws {
        try temporaryDirectory { dir in
            let source = try TemplateImageTools.createTemplate(.md, name: "源模板", in: dir)
            let library = TemplateLibrary(directory: dir.appendingPathComponent("library"))
            let record = try library.importTemplate(source, title: "日报")
            try Data("source changed".utf8).write(to: source)
            try library.update(id: record.id, title: "每日报告", enabled: false)
            let reopened = TemplateLibrary(directory: dir.appendingPathComponent("library"))
            let saved = try #require(reopened.records().first)
            #expect(saved.title == "每日报告")
            #expect(!saved.enabled)
            let copied = try TemplateImageTools.copyTemplate(reopened.sourceURL(for: saved), name: "输出", in: dir)
            #expect(try String(contentsOf: copied, encoding: .utf8) == "# 新建文稿\n\n")
            #expect(throws: (any Error).self) { try reopened.update(id: saved.id, title: " ", enabled: true) }
        }
    }

    @Test func officeTemplatesContainRealPackagesAndRequiredParts() throws {
        for kind in [TemplateImageTools.TemplateKind.docx, .xlsx, .pptx] {
            let data = try TemplateImageTools.templateData(kind)
            let entries = try readStoredZIP(data)
            #expect(entries["[Content_Types].xml"] != nil)
            #expect(entries["_rels/.rels"] != nil)
            let main = kind == .docx ? "word/document.xml" : (kind == .xlsx ? "xl/workbook.xml" : "ppt/presentation.xml")
            #expect(entries[main] != nil)
            for (name, part) in entries where name.hasSuffix(".xml") || name.hasSuffix(".rels") {
                let parser = XMLParser(data: part)
                #expect(parser.parse(), "Invalid XML: \(name)")
            }
        }
    }

    @Test func templateCreationAndCustomCopyDoNotOverwrite() throws {
        try temporaryDirectory { dir in
            let first = try TemplateImageTools.createTemplate(.docx, name: "项目", in: dir)
            let data = try Data(contentsOf: first)
            let second = try TemplateImageTools.createTemplate(.docx, name: "项目", in: dir)
            #expect(first != second)
            #expect(first.pathExtension == "docx")
            let copied = try TemplateImageTools.copyTemplate(first, name: "项目", in: dir)
            #expect(copied != first && copied != second)
            #expect(try Data(contentsOf: copied) == data)
            #expect(try Data(contentsOf: first) == data)
            #expect(throws: (any Error).self) { try TemplateImageTools.createTemplate(.txt, name: "../逃出", in: dir) }
        }
    }

    @Test func crc32MatchesPublishedCheckValue() {
        #expect(TemplateImageTools.crc32(Data("123456789".utf8)) == 0xcbf43926)
    }

    @Test func imageBudgetRejectsOversizedAndInvalidDimensions() throws {
        try TemplateImageTools.validateImageDimensions(width: 4000, height: 3000)
        #expect(throws: (any Error).self) { try TemplateImageTools.validateImageDimensions(width: 10000, height: 10000) }
        #expect(throws: (any Error).self) { try TemplateImageTools.validateImageDimensions(width: 0, height: 100) }
        #expect(throws: (any Error).self) { try TemplateImageTools.validateImageDimensions(width: Int.max, height: 100) }
    }

    @Test func imageConversionsProduceDecodableImagesAndPreserveExistingFiles() throws {
        try temporaryDirectory { dir in
            let original = fixture()
            for format in [TemplateImageTools.ImageFormat.png, .jpeg, .tiff, .bmp, .gif] {
                let first = try TemplateImageTools.exportImage(original, format: format, in: dir, name: "图像")
                let source = try #require(CGImageSourceCreateWithURL(first as CFURL, nil))
                let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
                #expect(decoded.width == 32 && decoded.height == 16)
                let originalData = try Data(contentsOf: first)
                let second = try TemplateImageTools.exportImage(original, format: format, in: dir, name: "图像")
                #expect(first != second)
                #expect(try Data(contentsOf: first) == originalData)
            }
        }
    }

    @Test func icnsChunksHaveCorrectLengthsAndPNGRepresentations() throws {
        let data = try TemplateImageTools.icnsData(fixture())
        #expect(String(data: data.prefix(4), encoding: .ascii) == "icns")
        #expect(big32(data, 4) == data.count)
        var position = 8
        var sizes: [Int] = []
        while position < data.count {
            let length = big32(data, position + 4)
            #expect(length > 8 && position + length <= data.count)
            let png = Data(data[(position + 8)..<(position + length)])
            let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            #expect(image.width == image.height)
            sizes.append(image.width)
            position += length
        }
        #expect(position == data.count)
        #expect(sizes == [16, 32, 64, 128, 256, 512, 1024])
    }

    @Test func iconSetExportsAllPlatformsAndKeepsInput() throws {
        try temporaryDirectory { dir in
            let image = fixture()
            for platform in TemplateImageTools.IconPlatform.allCases {
                let first = try TemplateImageTools.exportIconSet(image, platform: platform, in: dir, name: "App")
                let second = try TemplateImageTools.exportIconSet(image, platform: platform, in: dir, name: "App")
                #expect(first != second)
                let files = try FileManager.default.contentsOfDirectory(at: first, includingPropertiesForKeys: nil)
                #expect(files.contains { $0.pathExtension == "png" })
                if platform != .macOS { #expect(files.contains { $0.lastPathComponent == "Contents.json" }) }
                for file in files where file.pathExtension == "png" {
                    let source = try #require(CGImageSourceCreateWithURL(file as CFURL, nil))
                    #expect(CGImageSourceCreateImageAtIndex(source, 0, nil) != nil)
                }
            }
            #expect(image.width == 32 && image.height == 16)
        }
    }

    private func fixture() -> CGImage {
        let context = CGContext(data: nil, width: 32, height: 16, bitsPerComponent: 8, bytesPerRow: 128,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.3, green: 0.6, blue: 0.9, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 32, height: 16))
        return context.makeImage()!
    }
    private func temporaryDirectory(_ action: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        try action(dir)
    }
    private func big32(_ data: Data, _ offset: Int) -> Int {
        data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
    }
    private func little(_ data: Data, _ offset: Int, _ count: Int) -> Int {
        (0..<count).reduce(0) { $0 | (Int(data[offset + $1]) << ($1 * 8)) }
    }
    private func readStoredZIP(_ data: Data) throws -> [String: Data] {
        var result: [String: Data] = [:]
        var offset = 0
        while offset + 30 <= data.count && little(data, offset, 4) == 0x04034b50 {
            #expect(little(data, offset + 8, 2) == 0)
            let size = little(data, offset + 18, 4), nameLength = little(data, offset + 26, 2), extra = little(data, offset + 28, 2)
            let start = offset + 30 + nameLength + extra
            let name = try #require(String(data: data[(offset + 30)..<(offset + 30 + nameLength)], encoding: .utf8))
            let payload = Data(data[start..<(start + size)])
            #expect(UInt32(little(data, offset + 14, 4)) == TemplateImageTools.crc32(payload))
            result[name] = payload
            offset = start + size
        }
        #expect(little(data, offset, 4) == 0x02014b50)
        #expect(little(data, data.count - 22, 4) == 0x06054b50)
        #expect(little(data, data.count - 12, 2) == result.count)
        return result
    }
}
