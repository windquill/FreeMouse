import Foundation
import Testing
@testable import FreeMouse

struct StartupManagerTests {
    @Test func scriptLiteralEscapesQuotesBackslashesAndNewlines() {
        #expect(StartupScripts.literal("A\"\\\nB") == "\"A\\\"\\\\\\nB\"")
        let source = StartupScripts.setLoginItem(path: "/Applications/A\"; $(touch nope).app", enabled: true)
        #expect(source.contains("make login item"))
        #expect(!source.contains("do shell script"))
        #expect(!source.contains("delete anItem"))
        #expect(source.contains("if not alreadyPresent"))
        #expect(StartupScripts.setLoginItem(path: "/Applications/Example.app", enabled: false).contains("delete anItem"))
    }

    @Test func disabledOverridesAreParsedWithoutGuessing() throws {
        let result = try StartupLaunchService.parseDisabled("disabled services = {\n \"org.test.one\" => true\n \"org.test.two\" => false\n}")
        #expect(result["org.test.one"] == true)
        #expect(result["org.test.two"] == false)
        #expect(throws: (any Error).self) { try StartupLaunchService.parseDisabled("permission denied") }
        #expect(throws: (any Error).self) { try StartupLaunchService.parseDisabled("disabled services = {\n unknown syntax\n}") }
    }

    @Test func launchServiceMapsBundleWithoutDisplayingArguments() {
        let plist: [String: Any] = ["ProgramArguments": ["/Applications/Example.app/Contents/MacOS/Example", "secret-token"]]
        #expect(StartupLaunchService.applicationPath(in: plist) == "/Applications/Example.app")
        #expect(StartupLaunchService.applicationPath(in: ["ProgramArguments": ["/usr/bin/open", "-a", "/Applications/Other.app"]]) == "/Applications/Other.app")
        #expect(!StartupLaunchService.validLabel("../../anything"))
        #expect(!StartupLaunchService.validLabel("a; touch /tmp/test"))
        #expect(StartupLaunchService.validLabel("org.example.background"))
    }

    @Test func embeddedManifestWithoutExplicitOverrideDoesNotImplyRegistration() throws {
        let (root, _, app) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = app.appendingPathComponent("Contents/Library/LaunchAgents")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: ["Label": "org.test.embedded", "Program": "Contents/MacOS/Fixture"], format: .xml, options: 0)
        try data.write(to: directory.appendingPathComponent("helper.plist"))
        var errors: [String] = []
        let parents = [directory.path: app.path]
        let unknown = StartupLaunchService.read(directories: [(directory, "gui/123")], disabled: ["gui/123": [:]], embeddedParents: parents, errors: &errors)
        #expect(unknown.first?.enabled == nil)
        #expect(unknown.first?.applicationPath == app.path)
        #expect(unknown.first?.canModify == false)
        let explicit = StartupLaunchService.read(directories: [(directory, "gui/123"), (directory, "gui/123")], disabled: ["gui/123": ["org.test.embedded": true]], embeddedParents: parents, errors: &errors)
        #expect(explicit.count == 1)
        #expect(explicit.first?.enabled == false)
        #expect(explicit.first?.canModify == false)
        let allowed = StartupLaunchService.read(directories: [(directory, "gui/123")], disabled: ["gui/123": ["org.test.embedded": false]], embeddedParents: parents, errors: &errors)
        #expect(allowed.first?.enabled == true)
        let helper = app.appendingPathComponent("Contents/Library/LoginItems/Helper.app")
        try FileManager.default.createDirectory(at: helper, withIntermediateDirectories: true)
        let discovered = StartupLaunchService.embedded(in: [.init(path: app.path, name: "Fixture", loginEnabled: false)], userDomain: "gui/123", disabled: ["gui/123": [:]], errors: &errors)
        #expect(discovered.count == 2)
        #expect(discovered.allSatisfy { $0.applicationPath == app.path && $0.enabled == nil && !$0.canModify })
    }
    private func fixture() throws -> (URL, StartupStore, URL) {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = project.appendingPathComponent(".build/tmp/startup-\(UUID().uuidString)")
        let app = root.appendingPathComponent("A ; $(test).app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundlePackageType": "APPL", "CFBundleIdentifier": "test.fixture", "CFBundleExecutable": "Fixture"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: app.appendingPathComponent("Contents/MacOS/Fixture").path, contents: Data())
        return (root, StartupStore(stateDirectory: root.appendingPathComponent("state"), launchAgentsDirectory: root.appendingPathComponent("agents")), app)
    }

    @Test func applicationArgumentsRemainLiteralAndStable() throws {
        let (root, store, app) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let entry = try store.add(application: app)
        #expect(try store.entries().count == 1)
        #expect(try store.entries().first?.id == entry.id)
        #expect(StartupStore.agentPropertyList(for: entry)["ProgramArguments"] as? [String] == ["/usr/bin/open", "-a", app.path])
        #expect(!FileManager.default.fileExists(atPath: store.agentURL(for: entry).path))
    }

    @Test func enableDisableAndRemovalTouchOnlyManagedFile() throws {
        let (root, store, app) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let entry = try store.add(application: app)
        try store.setEnabled(true, entry: entry)
        #expect(try store.isEnabled(entry))
        try store.setEnabled(false, entry: entry)
        #expect(try !store.isEnabled(entry))
        #expect(try store.entries().count == 1)
        try store.remove(entry)
        #expect(try store.entries().isEmpty)
    }

    @Test func foreignFileAndSymlinkAreNeverOverwrittenOrDeleted() throws {
        let (root, store, app) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let entry = try store.add(application: app)
        try FileManager.default.createDirectory(at: store.launchAgentsDirectory, withIntermediateDirectories: true)
        let url = store.agentURL(for: entry)
        let foreign = Data("foreign file".utf8)
        try foreign.write(to: url)
        #expect(throws: (any Error).self) { try store.setEnabled(true, entry: entry) }
        #expect(throws: (any Error).self) { try store.remove(entry) }
        #expect(try Data(contentsOf: url) == foreign)
        try FileManager.default.removeItem(at: url)
        let target = root.appendingPathComponent("target")
        try foreign.write(to: target)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        #expect(throws: (any Error).self) { try store.setEnabled(true, entry: entry) }
        #expect(throws: (any Error).self) { try store.setEnabled(false, entry: entry) }
        #expect(try Data(contentsOf: target) == foreign)
    }

    @Test func invalidAppAndForgedEntryAreRejected() throws {
        let (root, store, app) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: (any Error).self) { try store.add(application: root) }
        let forged = StartupEntry(id: "../../foreign", applicationPath: app.path)
        #expect(throws: (any Error).self) { try store.setEnabled(true, entry: forged) }
    }
}
