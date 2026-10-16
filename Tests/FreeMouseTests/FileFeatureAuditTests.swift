import AppKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import FreeMouse

/// Functional checks use only owned, disposable directories; no preferences or user files.
@MainActor
struct FileFeatureAuditTests {
    @Test func newFoldersAreDirectoriesAndCollisionsPreserveExistingChildren() throws {
        try temporary { root in
            let first = try FileTools.createFolder(in: root, name: "项目.v1")
            let child = try file(first, "保留.txt", "keep")
            let second = try FileTools.createFolder(in: root, name: "项目.v1")
            #expect(first != second)
            #expect(ExtendedFileTools.isDirectory(first) && ExtendedFileTools.isDirectory(second))
            #expect(try String(contentsOf: child, encoding: .utf8) == "keep")
        }
    }

    @Test func batchRenameChangesActualFilesAndPreservesDirectoryDotsAndExtensions() throws {
        try temporary { root in
            let source = try file(root, "报告.final.txt", "payload")
            let folder = try FileTools.createFolder(in: root, name: "目录.v2")
            let nested = try file(folder, "nested", "nested payload")
            let plan = try FileTools.renamePlan([source, folder], prefix: "P_", suffix: "_S")
            #expect(plan.map { $0.1.lastPathComponent } == ["P_报告.final_S.txt", "P_目录.v2_S"])
            try FileTools.executeRename(plan)
            #expect(!exists(source) && !exists(folder))
            #expect(try String(contentsOf: plan[0].1, encoding: .utf8) == "payload")
            #expect(try String(contentsOf: plan[1].1.appendingPathComponent(nested.lastPathComponent), encoding: .utf8) == "nested payload")
        }
    }

    @Test func renameRejectsAChangedDestinationBeforeMovingAnySource() throws {
        try temporary { root in
            let first = try file(root, "a.txt", "first"), second = try file(root, "b.txt", "second")
            let plan = try FileTools.renamePlan([first, second], prefix: "x_", suffix: "")
            _ = try file(root, "x_b.txt", "new occupant")
            #expect(throws: (any Error).self) { try FileTools.executeRename(plan) }
            #expect(try String(contentsOf: first, encoding: .utf8) == "first")
            #expect(try String(contentsOf: second, encoding: .utf8) == "second")
            #expect(!exists(root.appendingPathComponent("x_a.txt")))
            #expect(try String(contentsOf: root.appendingPathComponent("x_b.txt"), encoding: .utf8) == "new occupant")
        }
    }

    @Test func directoryCopyPreservesNestedBytesAndSymbolicLinksWithoutMovingSource() throws {
        try temporary { root in
            let source = try FileTools.createFolder(in: root, name: "source")
            let nested = try FileTools.createFolder(in: source, name: "nested")
            _ = try file(nested, "data.bin", "nested bytes")
            let link = source.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "nested/data.bin")
            let destination = try FileTools.createFolder(in: root, name: "out")
            let copied = try #require(ExtendedFileTools.copy([source], to: destination).first)
            #expect(try String(contentsOf: copied.appendingPathComponent("nested/data.bin"), encoding: .utf8) == "nested bytes")
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: copied.appendingPathComponent("link").path) == "nested/data.bin")
            #expect(exists(source.appendingPathComponent("nested/data.bin")))
        }
    }

    @Test func folderFromNameSupportsExtensionlessFilesAndDirectories() throws {
        try temporary { root in
            let source = try file(root, "README", "readme")
            let folder = try FileTools.createFolder(in: root, name: "Photos.v1")
            _ = try file(folder, "photo", "image bytes")
            let outputs = try ExtendedFileTools.folderFromName([source, folder])
            #expect(outputs.map(\.path) == [root.appendingPathComponent("README 文件夹/README").path, root.appendingPathComponent("Photos.v1 文件夹/Photos.v1").path])
            #expect(try String(contentsOf: outputs[0], encoding: .utf8) == "readme")
            #expect(try String(contentsOf: outputs[1].appendingPathComponent("photo"), encoding: .utf8) == "image bytes")
        }
    }

    @Test func selectedHideAndUnhideReallyChangeFlagsAndPreserveFileContents() throws {
        try temporary { root in
            let source = try file(root, "visible", "same bytes")
            let folder = try FileTools.createFolder(in: root, name: "folder")
            try ExtendedFileTools.setHidden([source, folder], hidden: true)
            #expect(try ExtendedFileTools.hiddenStates([source, folder]) == [true, true])
            try ExtendedFileTools.setHidden([source, folder], hidden: false)
            #expect(try ExtendedFileTools.hiddenStates([source, folder]) == [false, false])
            #expect(try String(contentsOf: source, encoding: .utf8) == "same bytes")
        }
    }

    @Test func hideAllAndUnhideAllChangeOnlyImmediateNonDotChildren() throws {
        try temporary { root in
            let immediate = try file(root, "visible", "data")
            let dot = try file(root, ".dot", "dot data")
            let folder = try FileTools.createFolder(in: root, name: "folder")
            let nested = try file(folder, "nested", "nested")
            try ExtendedFileTools.setHidden(ExtendedFileTools.directoryItems([root], unhiding: false), hidden: true)
            #expect(try ExtendedFileTools.hiddenStates([immediate, folder]) == [true, true])
            #expect(try ExtendedFileTools.hiddenStates([nested]) == [false])
            try ExtendedFileTools.setHidden(ExtendedFileTools.directoryItems([root], unhiding: true), hidden: false)
            #expect(try ExtendedFileTools.hiddenStates([immediate, folder]) == [false, false])
            #expect(try String(contentsOf: dot, encoding: .utf8) == "dot data")
            #expect(try ExtendedFileTools.hiddenStates([dot]) == [true])
        }
    }

    @Test func cutPasteMovesActualBytesAndRestoresEachOriginalHiddenFlag() throws {
        try temporary { root in
            let visible = try file(root, "visible", "one"), hidden = try file(root, "hidden", "two")
            try ExtendedFileTools.setHidden([hidden], hidden: true)
            let journal = root.appendingPathComponent("cut-journal.json")
            let cut = try ExtendedCutSession(urls: [visible, hidden], hide: true, journalURL: journal)
            #expect(try ExtendedFileTools.hiddenStates([visible, hidden]) == [true, true])
            let destination = try FileTools.createFolder(in: root, name: "out")
            try cut.validateOriginals()
            try cut.restore() // Same order as the pasteCut UI handler.
            let result = try cut.move(to: destination)
            #expect(!exists(visible) && !exists(hidden) && !exists(journal))
            #expect(try result.map { try String(contentsOf: $0, encoding: .utf8) } == ["one", "two"])
            #expect(try ExtendedFileTools.hiddenStates(result) == [false, true])
        }
    }

    @Test func cancelCutRestoresFlagsAndKeepsOriginalBytesAtTheirPaths() throws {
        try temporary { root in
            let source = try file(root, "visible", "untouched")
            let journal = root.appendingPathComponent("cut-journal.json")
            let cut = try ExtendedCutSession(urls: [source], hide: true, journalURL: journal)
            try cut.restore()
            #expect(!cut.hasHiddenChanges && !exists(journal))
            #expect(try ExtendedFileTools.hiddenStates([source]) == [false])
            #expect(try String(contentsOf: source, encoding: .utf8) == "untouched")
        }
    }

    @Test func permanentDeletionOfFixtureSymlinkPreservesItsTargetAndDeletesOwnedFolder() throws {
        try temporary { root in
            let target = try file(root, "target", "keep")
            let link = root.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            let folder = try FileTools.createFolder(in: root, name: "disposable")
            _ = try file(folder, "nested", "delete")
            try ExtendedFileTools.deletePermanently([link, folder])
            #expect(!exists(link) && !exists(folder))
            #expect(try String(contentsOf: target, encoding: .utf8) == "keep")
        }
    }

    @Test func allSeventeenTemplateKindsCreateCorrectExtensionsAndTheirActualPayloads() throws {
        try temporary { root in
            #expect(TemplateImageTools.TemplateKind.allCases.count == 17)
            for kind in TemplateImageTools.TemplateKind.allCases {
                let output = try TemplateImageTools.createTemplate(kind, name: "文稿-" + kind.rawValue, in: root)
                #expect(output.pathExtension == kind.rawValue)
                #expect(try Data(contentsOf: output) == TemplateImageTools.templateData(kind))
                if kind == .json { #expect(try JSONSerialization.jsonObject(with: Data(contentsOf: output)) is [String: Any]) }
                if kind == .xml || kind == .svg { #expect(XMLParser(contentsOf: output)?.parse() == true) }
                let second = try TemplateImageTools.createTemplate(kind, name: output.lastPathComponent, in: root)
                #expect(second != output && second.pathExtension == kind.rawValue)
                #expect(!second.lastPathComponent.hasSuffix("." + kind.rawValue + "." + kind.rawValue))
            }
        }
    }

    @Test func customTemplateRejectsDirectoriesAndSymlinksWithoutCreatingOutput() throws {
        try temporary { root in
            let source = try file(root, "source.txt", "source")
            let directory = try FileTools.createFolder(in: root, name: "plain-folder")
            let link = root.appendingPathComponent("link.txt")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
            let out = try FileTools.createFolder(in: root, name: "out")
            #expect(throws: (any Error).self) { try TemplateImageTools.copyTemplate(directory, name: "copy", in: out) }
            #expect(throws: (any Error).self) { try TemplateImageTools.copyTemplate(link, name: "copy", in: out) }
            #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).isEmpty)
            #expect(try String(contentsOf: source, encoding: .utf8) == "source")
        }
    }

    @Test(arguments: [32, 128, 512], [false, true]) func heicExportProducesAnActualDecodableHEICWithOriginalDimensions(width: Int, opaque: Bool) throws {
        try temporary { root in
            let output = try TemplateImageTools.exportImage(image(width: width, height: width / 2, red: 0.2, green: 0.6, blue: 0.9, opaque: opaque), format: .heic, in: root, name: "HEIC")
            let source = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
            let type = try #require(CGImageSourceGetType(source))
            #expect(UTType(type as String)?.conforms(to: .heic) == true)
            let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            #expect(decoded.width == width && decoded.height == width / 2)
        }
    }

    @Test func legacyImageExportCreatesDecodablePNGAndJPEGWithoutReplacingExistingOutput() throws {
        try temporary { root in
            let original = try image(width: 20, height: 10, red: 1, green: 0, blue: 0)
            for jpeg in [false, true] {
                let output = try FileTools.exportImage(original, in: root, name: "result", jpeg: jpeg)
                let saved = try Data(contentsOf: output)
                let duplicate = try FileTools.exportImage(original, in: root, name: "result", jpeg: jpeg)
                #expect(output != duplicate)
                #expect(try Data(contentsOf: output) == saved)
                let decoded = try FileTools.loadImage(duplicate)
                #expect(decoded.width == 20 && decoded.height == 10)
            }
        }
    }

    @Test func imageLoadingAppliesEXIFOrientationAndStackingUsesOrientedDimensions() throws {
        try temporary { root in
            let source = root.appendingPathComponent("oriented.jpg")
            let destination = try #require(CGImageDestinationCreateWithURL(source as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, try image(width: 12, height: 6, red: 1, green: 0, blue: 0), [kCGImagePropertyOrientation: 6] as CFDictionary)
            #expect(CGImageDestinationFinalize(destination))
            let loaded = try FileTools.loadImage(source)
            #expect(loaded.width == 6 && loaded.height == 12)
            let stacked = try FileTools.stackImageFiles([source, source])
            #expect(stacked.width == 6 && stacked.height == 24)
        }
    }

    @Test func stackedImageFilesAndInMemoryStackKeepFirstInputAtTop() throws {
        try temporary { root in
            let red = try image(width: 8, height: 4, red: 1, green: 0, blue: 0)
            let blue = try image(width: 4, height: 4, red: 0, green: 0, blue: 1)
            let redURL = try FileTools.exportImage(red, in: root, name: "01", jpeg: false)
            let blueURL = try FileTools.exportImage(blue, in: root, name: "02", jpeg: false)
            for stacked in [try FileTools.stackImages([red, blue]), try FileTools.stackImageFiles([redURL, blueURL])] {
                #expect(stacked.width == 8 && stacked.height == 12)
                let top = try sample(stacked, x: 4, y: 1)
                let bottom = try sample(stacked, x: 4, y: 10)
                #expect(top.0 > 240 && top.2 < 10)
                #expect(bottom.2 > 240 && bottom.0 < 10)
            }
        }
    }

    @Test func iconSetMetadataReferencesExactPixelDimensionsAndOpaqueMobileImages() throws {
        try temporary { root in
            let input = try image(width: 32, height: 16, red: 1, green: 0, blue: 0)
            for platform in [TemplateImageTools.IconPlatform.iOS, .watchOS] {
                let output = try TemplateImageTools.exportIconSet(input, platform: platform, in: root, name: "App")
                let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("Contents.json"))) as? [String: Any])
                let entries = try #require(json["images"] as? [[String: String]])
                #expect(!entries.isEmpty)
                for entry in entries {
                    let filename = try #require(entry["filename"])
                    let size = try #require(entry["size"]?.split(separator: "x").first.flatMap { Double($0) })
                    let scale = try #require(entry["scale"].flatMap { Double($0.dropLast()) })
                    let decoded = try FileTools.loadImage(output.appendingPathComponent(filename))
                    let expected = Int((size * scale).rounded())
                    #expect(decoded.width == expected && decoded.height == expected)
                    #expect(try sample(decoded, x: 0, y: 0).3 == 255)
                }
            }
        }
    }

    @Test func corruptImagesFailWithoutChangingSourceFiles() throws {
        try temporary { root in
            let source = try file(root, "corrupt.png", "not an image")
            #expect(throws: (any Error).self) { try FileTools.loadImage(source) }
            #expect(throws: (any Error).self) { try FileTools.stackImageFiles([source]) }
            #expect(try String(contentsOf: source, encoding: .utf8) == "not an image")
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["corrupt.png"])
        }
    }

    private func temporary(_ action: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FreeMouse-FileAudit118-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try action(root)
    }
    private func file(_ directory: URL, _ name: String, _ contents: String) throws -> URL {
        try FileTools.createFile(in: directory, name: name, contents: contents)
    }
    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path) || (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }
    private func image(width: Int, height: Int, red: CGFloat, green: CGFloat, blue: CGFloat, opaque: Bool = false) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: (opaque ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast).rawValue))
        context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }
    private func sample(_ image: CGImage, x: Int, y: Int) throws -> (UInt8, UInt8, UInt8, UInt8) {
        let cropped = try #require(image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes { storage in
            let context = try #require(CGContext(data: storage.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return (bytes[0], bytes[1], bytes[2], bytes[3])
    }
}
