import AppKit
import FinderSync
import Darwin

@objc(FinderExtension)
final class FinderExtension: FIFinderSync {
    override init() {
        super.init(); observeVolumes()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(volumesChanged), name: NSWorkspace.didMountNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(volumesChanged), name: NSWorkspace.didUnmountNotification, object: nil)
    }
    @objc private func volumesChanged() { observeVolumes() }
    private func observeVolumes() {
        var folders = Set<URL>()
        if let record = getpwuid(getuid()), let home = record.pointee.pw_dir {
            folders.insert(URL(fileURLWithPath: String(cString: home), isDirectory: true))
        }
        for volume in FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeIsInternalKey], options: []) ?? [] {
            if (try? volume.resourceValues(forKeys: [.volumeIsInternalKey]).volumeIsInternal) == false { folders.insert(volume) }
        }
        FIFinderSyncController.default().directoryURLs = folders
    }
    override func menu(for menuKind: FIMenuKind) -> NSMenu {
        FinderMenuBuilder.makeMenu(loadConfiguration: FinderMenuPreferences.shared.load,
                                   target: self, action: #selector(performTool(_:)))
    }
    @objc private func performTool(_ sender: NSMenuItem) {
        guard let action = FinderMenuActionRegistry.action(for: sender.tag) else { return }
        if action == FinderMenuActionRegistry.settingsAction {
            if let url = URL(string: "freemouse://settings?section=finder") { NSWorkspace.shared.open(url) }
            return
        }
        let controller = FIFinderSyncController.default()
        var urls = controller.selectedItemURLs() ?? []
        let backgroundActions: Set<String> = ["newTemplate", "customTemplate", "newFolder", "pasteCut", "paths", "terminal", "openWith", "hideAll", "unhideAll"]
        if urls.isEmpty, (backgroundActions.contains(action) || action.hasPrefix("newTemplate.")), let target = controller.targetedURL() { urls = [target] }
        let noFileActions: Set<String> = ["capture", "captureFull", "captureScroll", "record", "favorites", "qr", "translateGoogle", "translateBaidu", "cancelCut"]
        guard !urls.isEmpty || noFileActions.contains(action) else { return }
        var components = URLComponents(); components.scheme = "freemouse"; components.host = "files"
        components.queryItems = [URLQueryItem(name: "action", value: action)] + urls.prefix(100).map { URLQueryItem(name: "path", value: $0.path) }
        if let url = components.url { NSWorkspace.shared.open(url) }
    }
}
