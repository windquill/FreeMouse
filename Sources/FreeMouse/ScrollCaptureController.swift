import AppKit
import ApplicationServices
import Carbon
import CoreMedia

/// A single actor owns the mutable stitcher. No whole-image copy is made per frame.
private actor ScrollAssembly {
    struct Update {
        let appended: Bool
        let width: Int
        let height: Int
        let frameCount: Int
        let preview: CGImage?
        let hasDiagnostics: Bool
    }
    private let stitcher = ScrollStitcher()
    private let diagnostics = ScrollCaptureDiagnostics()
    func append(_ frame: ScrollVideoFrame, lastDeferredSequence: UInt64) throws -> Update {
        let result: ScrollStitcher.AppendResult
        do { result = try stitcher.append(frame.image) }
        catch CaptureError.noOverlap {
            diagnostics.recordNoOverlap(frame, totalHeight: stitcher.totalHeight,
                                        lastDeferredSequence: lastDeferredSequence, reason: "noOverlap")
            throw CaptureError.noOverlap
        }
        let appended: Bool
        switch result { case .appended: appended = true; case .duplicate: appended = false }
        diagnostics.recordAccepted(frame, appended: appended)
        return Update(appended: appended, width: stitcher.width, height: stitcher.totalHeight,
                      frameCount: stitcher.frameCount,
                      preview: appended ? stitcher.preview(maxWidth: 154, maxHeight: 400) : nil,
                      hasDiagnostics: diagnostics.snapshot != nil)
    }
    func output() -> CGImage? { stitcher.image }
    func matchesLastViewport(_ image: CGImage) throws -> Bool { try stitcher.matchesLastViewport(image) }
    func diagnosticSnapshot() -> ScrollCaptureDiagnosticSnapshot? { diagnostics.snapshot }
    func diagnosticAvailability() -> (available: Bool, reason: String?) {
        (diagnostics.snapshot != nil, diagnostics.unavailableReason)
    }
}

@MainActor
final class ScrollCaptureController: NSObject, NSWindowDelegate {
    var onActivityChange: ((Bool) -> Void)?
    var onOutput: ((CGImage, ScrollOutputAction) -> Void)?
    var isActive: Bool { panel != nil }
    private var source: ScrollFrameSource?
    private var engine: ScrollAssembly?
    private var region: CaptureRegion?
    private var selection = CGRect.zero
    private var screenFrame = CGRect.zero
    private var panel: NSPanel?
    private var previewPanel: NSPanel?
    private var borderPanel: NSPanel?
    private var status = NSTextField(labelWithString: "准备采集…")
    private var sizeLabel = NSTextField(labelWithString: "拼接预览 · 最新部分")
    private var preview = NSImageView()
    private var autoButton: NSButton?
    private var pauseButton: NSButton?
    private var diagnosticButton: NSButton?
    private var hasDiagnostics = false
    private var exportingDiagnostics = false
    private var outputButtons: [NSButton] = []
    private var speed: NSSegmentedControl?
    private var captureLoop: Task<Void, Never>?
    private var motionLoop: Task<Void, Never>?
    private var finishTask: Task<Void, Never>?
    private var generation = UUID()
    private var sequence: UInt64 = 0
    private var lastMatchedSequence: UInt64 = 0
    private var flow = ScrollCaptureFlow()
    private var pacer = ScrollAutomaticPacer()
    private var finishSettler: ScrollFinishSettler?
    private var processingFrame = false
    private var captureRevision: UInt64 = 0
    private var fatalFrameError: String?
    private var startedAt: TimeInterval = 0
    private var onComplete: ((CGImage) -> Void)?
    private var hotkeys: [EventHotKeyRef] = []
    private var eventHandler: EventHandlerRef?
    private var localKeys: Any?
    private var wheelMonitor: Any?
    private var localWheelMonitor: Any?
    private static let eventTag: Int64 = 0x46525343
    // SCStream presentation timestamps use the host clock too.
    private var now: TimeInterval { CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())) }

    func start(region: CaptureRegion, onComplete: @escaping (CGImage) -> Void) {
        guard !isActive else { bringForward(); return }
        self.region = region; self.onComplete = onComplete
        generation = UUID(); sequence = 0; lastMatchedSequence = 0; flow = ScrollCaptureFlow()
        hasDiagnostics = false; exportingDiagnostics = false
        pacer.reset(); finishSettler = nil; processingFrame = false; captureRevision = 0; fatalFrameError = nil
        let source = ScrollFrameSource(), engine = ScrollAssembly()
        self.source = source; self.engine = engine
        guard let screen = NSScreen.screens.first(where: { $0.captureDisplayID == region.displayID }) else { cancel(); return }
        screenFrame = screen.frame
        selection = CGRect(x: screen.frame.minX + region.rect.minX, y: screen.frame.maxY - region.rect.maxY,
                           width: region.rect.width, height: region.rect.height)
        buildPanels(screen: screen)
        installInput()
        onActivityChange?(true)
        let token = generation
        startedAt = now
        captureLoop = Task { [weak self] in
            do {
                try await source.start(region: region)
                guard let self, self.generation == token else { await source.stop(); return }
                self.flow.started(at: self.now)
                self.updateButtons()
                while !Task.isCancelled && self.generation == token {
                    if let failure = source.failure {
                        self.fatalFrameError = failure
                        self.flow.setAutomatic(false, at: self.now)
                        self.status.stringValue = "采集已停止：\(failure)。可保存已有截图或取消。"
                        self.updateButtons()
                        await source.stop()
                        break
                    }
                    var consumedFrame = false
                    if self.flow.phase == .running {
                        consumedFrame = await self.consumeNext(source: source, engine: engine, token: token)
                        guard self.generation == token, !Task.isCancelled else { break }
                        if self.fatalFrameError != nil {
                            await source.stop()
                            break
                        }
                        if !source.isBackpressured && self.flow.unchanged(at: self.now) {
                            self.status.stringValue = "画面未继续下移，自动滚动已暂停；可继续手动滚动或完成。"
                            self.updateButtons()
                        }
                        if !self.flow.hasImage && self.now - self.startedAt > 8 {
                            self.status.stringValue = "暂未收到屏幕画面，请检查屏幕录制权限，或取消后重试。"
                        }
                    } else if self.flow.phase == .paused && !self.exportingDiagnostics,
                              source.lastDeferredSequence > self.lastMatchedSequence {
                        self.status.stringValue = "已暂停 · 有画面尚未确认，点继续接回后再完成"
                    }
                    if !consumedFrame { try await Task.sleep(for: .milliseconds(16)) }
                }
            } catch is CancellationError { }
            catch {
                guard let self, self.generation == token else { return }
                self.fatalFrameError = error.localizedDescription
                self.status.stringValue = "无法开始采集：\(error.localizedDescription)"
                self.updateButtons()
            }
        }
        startMotionLoop(token: token)
    }

    func bringForward() { panel?.orderFrontRegardless() }

    private func consumeNext(source: ScrollFrameSource, engine: ScrollAssembly, token: UUID) async -> Bool {
        guard let frame = source.nextFrame(after: sequence) else { return false }
        return await consume(frame, source: source, engine: engine, token: token)
    }

    private func consume(_ frame: ScrollVideoFrame, source: ScrollFrameSource, engine: ScrollAssembly, token: UUID) async -> Bool {
        let wasBackpressured = source.isBackpressured
        let revision = captureRevision
        processingFrame = true
        defer { if generation == token { processingFrame = false } }
        sequence = frame.sequence
        do {
            let update = try await engine.append(frame, lastDeferredSequence: source.lastDeferredSequence)
            guard generation == token else { return false }
            // A pause/resume or a wheel event during pause invalidates an
            // in-flight frame's ability to confirm the current viewport.
            guard captureRevision == revision else { return true }
            hasDiagnostics = update.hasDiagnostics
            finishSettler?.observed(at: now, changed: update.appended)
            pacer.matched(frameTime: frame.timestamp, at: now, advanced: update.appended)
            if wasBackpressured || source.isBackpressured { flow.processingBacklog(at: now) }
            // Only a verified append/duplicate can close a rejected-sample
            // gap; dequeuing an old bridge or a noOverlap cannot do so.
            lastMatchedSequence = frame.sequence
            if !update.appended { flow.matchedWithoutAdvance() }
            if update.appended {
                flow.accepted(at: now)
                if let image = update.preview { preview.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)) }
                sizeLabel.stringValue = "\(update.width) × \(update.height) px · \(update.frameCount) 帧"
                if flow.phase != .paused {
                    status.stringValue = flow.phase == .finishing ? "正在完成最后一帧…" : (source.isBackpressured ? "正在处理积压画面 · 请暂缓滚动，处理追上后可继续" : (flow.mode == .automatic ? "正在自动滚动 · 手动滚轮可接管" : "直接在选区内向下滚动 · 停住时不会结束"))
                }
            } else if flow.phase == .running && !source.isBackpressured {
                status.stringValue = flow.mode == .automatic ? "正在自动滚动 · 手动滚轮可接管" : "直接在选区内向下滚动 · 停住时不会结束"
            }
            updateButtons()
        } catch CaptureError.noOverlap {
            guard generation == token else { return false }
            guard captureRevision == revision else { return true }
            finishSettler?.observed(at: now, changed: true)
            pacer.rejected()
            let diagnostic = await engine.diagnosticAvailability()
            guard generation == token else { return false }
            hasDiagnostics = diagnostic.available
            diagnosticButton?.toolTip = diagnostic.reason ?? "导出断开前后两张选区画面和技术信息；仅保存到您选择的本机文件夹。"
            if wasBackpressured || source.isBackpressured { flow.processingBacklog(at: now) }
            let stopped = flow.rejected(at: now)
            if flow.phase != .paused {
                status.stringValue = source.lastDeferredSequence > lastMatchedSequence ? "刚才滚动超过处理速度；请停住，再向上滚回预览位置后缓慢下滚。" : (stopped ? "自动滚动已暂停；请向上滚回预览位置，再缓慢向下。" : "这一段尚未接上，已保留前面的内容；请向上滚回预览位置，再缓慢向下。")
            }
            updateButtons()
        } catch {
            guard generation == token else { return false }
            fatalFrameError = error.localizedDescription
            flow.setAutomatic(false, at: now)
            if flow.phase == .running { flow.togglePause(at: now) }
            status.stringValue = error.localizedDescription + " 可完成已有截图。"
            updateButtons()
        }
        return true
    }

    private func startMotionLoop(token: UUID) {
        motionLoop = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(20)) } catch { break }
                guard let self, self.generation == token else { break }
                let time = self.now
                guard self.flow.shouldScroll, self.fatalFrameError == nil, let region = self.region else { continue }
                if self.source?.isBackpressured == true {
                    self.flow.processingBacklog(at: time)
                    self.status.stringValue = "正在处理积压画面 · 自动滚动稍后继续"
                    continue
                }
                // Never advance past queued or currently-processing bridge frames.
                guard !self.processingFrame, self.source?.hasPendingFrames == false else { continue }
                guard AXIsProcessTrusted() else {
                    self.flow.setAutomatic(false, at: time)
                    self.status.stringValue = "辅助功能权限不可用，可继续手动滚动。"; self.updateButtons(); continue
                }
                guard let point = ScrollOverlayLayout.exposedPoint(in: self.selection, avoiding: [self.panel?.frame ?? .zero]) else {
                    self.flow.setAutomatic(false, at: time)
                    self.status.stringValue = "请将控制条拖到选区外，再开启自动滚动。"; self.updateButtons(); continue
                }
                let pixels = self.pacer.nextStep(at: time, viewportHeight: region.rect.height,
                    scale: region.scale, speed: self.speed?.selectedSegment ?? 1)
                guard pixels > 0 else { continue }
                guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -pixels, wheel2: 0, wheel3: 0) else { continue }
                let display = CGDisplayBounds(region.displayID)
                event.location = CGPoint(x: display.minX + point.x - self.screenFrame.minX, y: display.minY + self.screenFrame.maxY - point.y)
                event.setIntegerValueField(.eventSourceUserData, value: Self.eventTag)
                self.pacer.posted(at: self.now)
                event.post(tap: .cghidEventTap)
            }
        }
    }

    @objc private func toggleAutomatic() {
        guard flow.hasImage, fatalFrameError == nil else { return }
        let enable = flow.mode != .automatic
        if enable && !AXIsProcessTrusted() {
            status.stringValue = "自动滚动需辅助功能权限；现在可直接使用滚轮或双指手动滚动。"
            return
        }
        if flow.phase == .paused { captureRevision &+= 1; source?.setPaused(false) }
        flow.setAutomatic(enable, at: now); pacer.reset()
        status.stringValue = enable ? "正在自动滚动 · 每步确认后继续" : "已切换手动滚动"
        updateButtons()
    }
    @objc private func togglePause() {
        guard fatalFrameError == nil else { return }
        flow.togglePause(at: now, hasInFlightFrame: processingFrame); pacer.reset(); captureRevision &+= 1
        source?.setPaused(flow.phase == .paused)
        status.stringValue = flow.phase == .paused ? "已暂停 · 保持页面位置，点继续后再滚动" : "继续采集 · 请缓慢向下滚动"
        updateButtons()
    }
    @objc private func editAction() { finish(.edit) }
    @objc private func copyAction() { finish(.copy) }
    @objc private func saveAction() { finish(.save) }
    @objc private func recognizeAction() { finish(.recognize) }
    @objc private func cancelAction() { cancel() }

    @objc private func exportDiagnosticsAction() {
        guard hasDiagnostics, !exportingDiagnostics, flow.phase != .finishing, let engine else { return }
        let token = generation
        exportingDiagnostics = true
        if flow.phase == .running { flow.togglePause(at: now, hasInFlightFrame: processingFrame) }
        captureRevision &+= 1; pacer.reset(); source?.setPaused(true)
        // The capture hotkeys must not intercept Return/Space/Escape in the
        // native directory picker. Resume only for this same capture session.
        removeInput()
        status.stringValue = "已暂停 · 请选择诊断保存位置"
        updateButtons()
        Task { [weak self] in
            let snapshot = await engine.diagnosticSnapshot()
            guard let self, self.generation == token, self.isActive else { return }
            if let snapshot { self.presentDiagnosticExport(snapshot, expectedGeneration: token) }
            guard self.generation == token, self.isActive else { return }
            self.exportingDiagnostics = false
            self.status.stringValue = self.fatalFrameError.map { "采集已停止：\($0)。可保存已有截图。" }
                ?? "已暂停 · 点继续后再滚动；诊断只会保存到您选择的位置"
            self.installInput()
            self.updateButtons()
        }
    }

    private func presentDiagnosticExport(_ snapshot: ScrollCaptureDiagnosticSnapshot, expectedGeneration: UUID) {
        guard generation == expectedGeneration else { return }
        let picker = NSOpenPanel()
        picker.title = "导出长截图诊断"
        picker.message = "包含断开前后两张选区画面（可能含会话文字）和采集技术信息。仅保存到所选本机文件夹，不会自动上传。"
        picker.prompt = "保存诊断"
        picker.canChooseDirectories = true; picker.canChooseFiles = false
        picker.canCreateDirectories = true; picker.allowsMultipleSelection = false
        guard picker.runModal() == .OK, let directory = picker.url, generation == expectedGeneration else { return }
        do {
            let folder = try snapshot.export(to: directory,
                version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.1.16",
                build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "18")
            let alert = NSAlert(); alert.messageText = "诊断已保存"
            alert.informativeText = folder.path + "\n包含 reference.png、failed.png 和 report.json。发送前请自行检查画面内容。"
            alert.addButton(withTitle: "好"); alert.runModal()
        } catch {
            let alert = NSAlert(); alert.messageText = "诊断未能完整保存"
            alert.informativeText = error.localizedDescription + "\n已有长截图未受影响。"
            alert.addButton(withTitle: "好"); alert.runModal()
        }
    }

    private func finish(_ action: ScrollOutputAction) {
        guard !exportingDiagnostics else { return }
        guard flow.hasImage else { status.stringValue = "正在等待第一帧，请稍候…"; return }
        let includeTail = flow.phase != .paused && fatalFrameError == nil
        let verifyPausedTail = flow.phase == .paused && fatalFrameError == nil
#if SCROLL_CAPTURE_DIAGNOSTICS
        print("SCROLL_FINISH includeTail=\(includeTail) pausedProof=\(verifyPausedTail) phase=\(flow.phase)")
#endif
        guard flow.requestFinish(action), let source, let engine else { return }
        let token = generation
        motionLoop?.cancel(); motionLoop = nil
        let pending = captureLoop; pending?.cancel(); captureLoop = nil
        finishSettler = ScrollFinishSettler(startedAt: now)
        removeInput(); installInput(finishing: true)
        status.stringValue = "正在等待滚动停止并接好末尾…"; updateButtons()
        finishTask = Task { [weak self] in
            await pending?.value
            guard let self, self.generation == token else { return }
            var tailTimedOut = false
            // One consumer owns the tail. Keep draining while inertia settles,
            // instead of filling a queue during a fixed sleep before stopping.
            if includeTail {
                while self.generation == token, !Task.isCancelled, self.fatalFrameError == nil {
                    if let failure = source.failure { self.fatalFrameError = failure; break }
                    let consumed = await self.consumeNext(source: source, engine: engine, token: token)
                    guard self.generation == token, !Task.isCancelled else { return }
                    let decision = self.finishSettler?.decision(at: self.now, hasPending: source.hasPendingFrames) ?? .timedOut
                    if decision != .waiting {
                        tailTimedOut = decision == .timedOut
                        break
                    }
                    if !consumed {
                        do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
                    }
                }
            }
            if let failure = source.failure { self.fatalFrameError = failure }
            let preserveTail = includeTail && self.fatalFrameError == nil
            // A paused/fatal stop invalidates the source buffer. Preserve its
            // missing-tail evidence before that teardown clears the counters.
            let deferredBeforeStop = source.lastDeferredSequence
            await source.stop(preservingPending: preserveTail)
            guard self.generation == token else { return }
            if preserveTail {
                while await self.consumeNext(source: source, engine: engine, token: token) {
                    guard self.generation == token else { return }
                    if self.fatalFrameError != nil { break }
                }
                guard self.generation == token, !Task.isCancelled else { return }
                if self.fatalFrameError == nil {
                    self.status.stringValue = "正在核对最终画面…"
                    do {
                        let final = try await source.captureFinalFrame(after: self.sequence)
                        guard self.generation == token, !Task.isCancelled else { return }
                        _ = await self.consume(final, source: source, engine: engine, token: token)
                    } catch is CancellationError { return }
                    catch {
                        guard self.generation == token else { return }
                        self.fatalFrameError = "无法核对最终画面：" + error.localizedDescription
                    }
                }
            }
            if verifyPausedTail {
                // A paused stream can have no delivered complete sample even
                // after the page moved. Verify without changing the saved image.
                do {
                    let final = try await source.captureFinalFrame(after: self.sequence)
                    guard self.generation == token, !Task.isCancelled else { return }
                    let matches = try await engine.matchesLastViewport(final.image)
#if SCROLL_CAPTURE_DIAGNOSTICS
                    print("SCROLL_PAUSED_PROOF matches=\(matches) nativeOrdinal=\(final.sequence)")
#endif
                    guard self.generation == token, !Task.isCancelled else { return }
                    if matches {
                        self.lastMatchedSequence = final.sequence
                        self.flow.matchedWithoutAdvance()
                    } else {
                        _ = self.flow.rejected(at: self.now)
                    }
                } catch is CancellationError { return }
                catch {
                    guard self.generation == token else { return }
                    self.fatalFrameError = "无法核对暂停后的画面：" + error.localizedDescription
                }
            }
            guard self.generation == token else { return }
            let image = await engine.output()
            guard self.generation == token else { return }
            let diagnostic = await engine.diagnosticSnapshot()
            guard self.generation == token else { return }
            let callback = self.onComplete, output = self.onOutput
            let deferredTail = max(deferredBeforeStop, source.lastDeferredSequence) > self.lastMatchedSequence
            let failure = self.fatalFrameError
                ?? (tailTimedOut ? "页面仍在变化，等待末尾稳定已超时；请检查结尾。下次可先停住滚动，再点完成。" : nil)
                ?? (deferredTail ? "滚动快于处理速度，末尾画面尚未确认；请检查结尾。再次采集时可停住等待处理，或回到预览位置后缓慢滚动。" : nil)
            let incomplete = self.flow.hasUnmatchedFrame || failure != nil
#if SCROLL_CAPTURE_DIAGNOSTICS
            print("SCROLL_OUTPUT incomplete=\(incomplete) unmatched=\(self.flow.hasUnmatchedFrame)")
#endif
            self.cancel()
            let resultGeneration = self.generation
            guard let image else { return }
            if incomplete {
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert(); alert.messageText = "最后一段未完整拼接"
                alert.informativeText = "已保留成功拼接的内容，请在预览中检查结尾。可输出已有内容，或留在编辑器检查。"
                if let failure { alert.informativeText += "\n采集停止原因：" + failure }
                alert.addButton(withTitle: "输出已有内容"); alert.addButton(withTitle: "查看编辑器")
                if diagnostic != nil {
                    alert.informativeText += "\n也可导出断开前后的选区画面用于排查；导出后将打开编辑器。"
                    alert.addButton(withTitle: "导出诊断…")
                }
                let response = alert.runModal()
#if SCROLL_CAPTURE_DIAGNOSTICS
                print("SCROLL_WARNING_RESPONSE \(response.rawValue)")
#endif
                guard self.generation == resultGeneration else { return }
                if response == .alertThirdButtonReturn, let diagnostic {
                    self.presentDiagnosticExport(diagnostic, expectedGeneration: resultGeneration)
                    guard self.generation == resultGeneration else { return }
                    callback?(image); return
                }
                if response != .alertFirstButtonReturn { callback?(image); return }
            }
            if let output { output(image, action) } else { callback?(image) }
        }
    }

    func cancel() {
        generation = UUID(); flow.end()
        pacer.reset(); finishSettler = nil
        captureLoop?.cancel(); captureLoop = nil
        motionLoop?.cancel(); motionLoop = nil
        finishTask?.cancel(); finishTask = nil
        let oldSource = source; source = nil
        if let oldSource { Task { await oldSource.stop() } }
        removeInput()
        hasDiagnostics = false; exportingDiagnostics = false; diagnosticButton = nil
        for window in [panel, previewPanel, borderPanel].compactMap({ $0 }) {
            window.delegate = nil; window.orderOut(nil); window.close()
        }
        panel = nil; previewPanel = nil; borderPanel = nil
        engine = nil; region = nil; onComplete = nil
        outputButtons.removeAll()
        onActivityChange?(false)
    }
    private func removeInput() {
        for key in hotkeys { UnregisterEventHotKey(key) }; hotkeys.removeAll()
        if let eventHandler { RemoveEventHandler(eventHandler) }; eventHandler = nil
        for monitor in [localKeys, wheelMonitor, localWheelMonitor].compactMap({ $0 }) { NSEvent.removeMonitor(monitor) }
        localKeys = nil; wheelMonitor = nil; localWheelMonitor = nil
    }
    func windowWillClose(_ notification: Notification) { cancel() }

    private func installInput(finishing: Bool = false) {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard id.signature == 0x46525343 else { return OSStatus(eventNotHandledErr) }
            let controller = Unmanaged<ScrollCaptureController>.fromOpaque(context).takeUnretainedValue()
            let code = id.id
            let token = controller.generation
            Task { @MainActor in if controller.generation == token { controller.handleKey(code) } }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        var registered = Set<UInt16>()
        if eventHandler != nil {
            for code in (finishing ? [kVK_Escape] : [kVK_Return, kVK_Space, kVK_ANSI_O, kVK_Escape]) {
                var reference: EventHotKeyRef?
                let modifiers = code == kVK_Escape ? UInt32(0) : ScrollShortcutPolicy.globalOutputModifiers
                if RegisterEventHotKey(UInt32(code), modifiers, EventHotKeyID(signature: 0x46525343, id: UInt32(code)), GetApplicationEventTarget(), 0, &reference) == noErr, let reference {
                    hotkeys.append(reference)
                    if modifiers == 0 { registered.insert(UInt16(code)) }
                }
            }
        }
        // Plain typing belongs to the target application. Unmodified output
        // keys work only while this capture's control panel has focus.
        localKeys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, ScrollShortcutPolicy.handlesLocalOutput(modifiers: event.modifierFlags,
                  panelHasFocus: self.panel?.isKeyWindow == true),
                  (finishing ? [53] : [36, 49, 31, 53]).contains(Int(event.keyCode)), !registered.contains(event.keyCode) else { return event }
            self.handleKey(UInt32(event.keyCode)); return nil
        }
        guard !finishing else { return }
        wheelMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in self?.manualWheel(event) }
        localWheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in self?.manualWheel(event); return event }
    }
    private func handleKey(_ code: UInt32) {
        guard isActive, !exportingDiagnostics else { return }
        switch Int(code) {
        case kVK_Return: finish(.copy)
        case kVK_Space: finish(.save)
        case kVK_ANSI_O: finish(.recognize)
        case kVK_Escape: cancel()
        default: break
        }
    }
    private func manualWheel(_ event: NSEvent) {
        guard selection.contains(NSEvent.mouseLocation),
              event.cgEvent?.getIntegerValueField(.eventSourceUserData) != Self.eventTag else { return }
        if flow.phase == .paused {
            flow.userScrolled(); captureRevision &+= 1
            status.stringValue = "暂停期间页面已移动 · 点继续接回后再完成，或保存已截内容"
            return
        }
        guard flow.shouldScroll else { return }
        flow.setAutomatic(false, at: now); pacer.reset()
        status.stringValue = "已由手动滚轮接管"; updateButtons()
    }

    private func updateButtons() {
        let ready = flow.hasImage && flow.phase != .finishing && !exportingDiagnostics
        for button in outputButtons { button.isEnabled = ready }
        autoButton?.isEnabled = ready && fatalFrameError == nil
        autoButton?.title = flow.mode == .automatic ? "停止自动" : "自动滚动"
        pauseButton?.isEnabled = ready && fatalFrameError == nil
        pauseButton?.title = flow.phase == .paused ? "继续" : "暂停"
        diagnosticButton?.isEnabled = ready && hasDiagnostics
    }
    private func button(_ title: String, _ selector: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: selector)
        button.bezelStyle = .rounded; button.font = .systemFont(ofSize: 12)
        return button
    }
    private func overlay(_ rect: CGRect, title: String, controls: Bool) -> NSPanel {
        let panel = ScrollControlPanel(contentRect: rect, styleMask: controls ? [.titled, .nonactivatingPanel, .utilityWindow] : [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = title; panel.level = .floating; panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = controls; panel.ignoresMouseEvents = !controls
        return panel
    }
    private func buildPanels(screen: NSScreen) {
        let layout = ScrollOverlayLayout.make(selection: selection, visibleScreen: screen.visibleFrame)
        let border = overlay(selection, title: "", controls: false)
        border.isOpaque = false; border.backgroundColor = .clear; border.hasShadow = false
        border.contentView = ScrollBorderView(frame: CGRect(origin: .zero, size: selection.size))
        border.orderFrontRegardless(); borderPanel = border
        let previewPanel = overlay(layout.preview, title: "", controls: false)
        previewPanel.backgroundColor = .windowBackgroundColor
        previewPanel.contentView?.wantsLayer = true; previewPanel.contentView?.layer?.cornerRadius = 10
        sizeLabel = NSTextField(labelWithString: "拼接预览 · 最新部分")
        sizeLabel.font = .systemFont(ofSize: 10); sizeLabel.alignment = .center
        preview = NSImageView(); preview.imageScaling = .scaleProportionallyDown; preview.imageAlignment = .alignTop
        let pstack = NSStackView(views: [sizeLabel, preview]); pstack.orientation = .vertical; pstack.spacing = 8
        pstack.translatesAutoresizingMaskIntoConstraints = false
        previewPanel.contentView!.addSubview(pstack)
        NSLayoutConstraint.activate([
            pstack.leadingAnchor.constraint(equalTo: previewPanel.contentView!.leadingAnchor, constant: 10),
            pstack.trailingAnchor.constraint(equalTo: previewPanel.contentView!.trailingAnchor, constant: -10),
            pstack.topAnchor.constraint(equalTo: previewPanel.contentView!.topAnchor, constant: 10),
            pstack.bottomAnchor.constraint(equalTo: previewPanel.contentView!.bottomAnchor, constant: -10),
            preview.widthAnchor.constraint(equalTo: pstack.widthAnchor)
        ])
        previewPanel.orderFrontRegardless(); self.previewPanel = previewPanel
        let panel = overlay(layout.toolbar, title: "长截图 · 拖动标题栏移动", controls: true)
        panel.delegate = self
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        status = NSTextField(wrappingLabelWithString: "正在准备第一帧…随后直接在选区内滚动")
        status.font = .systemFont(ofSize: 12)
        let row = NSStackView(); row.orientation = .horizontal; row.spacing = 5
        autoButton = button("自动滚动", #selector(toggleAutomatic)); pauseButton = button("暂停", #selector(togglePause))
        speed = NSSegmentedControl(labels: ["慢", "中", "快"], trackingMode: .selectOne, target: nil, action: nil)
        speed?.selectedSegment = 1; speed?.toolTip = "自动滚动速度"
        outputButtons = [button("完成 / 编辑", #selector(editAction)), button("复制 ↩", #selector(copyAction)), button("保存 ␣", #selector(saveAction)), button("识字 O", #selector(recognizeAction))]
        for view in [autoButton!, pauseButton!, speed!] + outputButtons + [button("取消 Esc", #selector(cancelAction))] { row.addArrangedSubview(view) }
        let hint = NSTextField(labelWithString: "控制条内 ↩复制 / 空格保存 / O识字 · 全局 ⌃⌥⌘ + 对应键 · Esc取消")
        hint.font = .systemFont(ofSize: 10); hint.textColor = .secondaryLabelColor
        let footer = NSStackView(); footer.orientation = .horizontal; footer.spacing = 8
        diagnosticButton = button("导出诊断…", #selector(exportDiagnosticsAction))
        diagnosticButton?.toolTip = "首次断开后可用；包含选区画面，仅保存到您选择的本机文件夹。"
        footer.addArrangedSubview(hint); footer.addArrangedSubview(diagnosticButton!)
        stack.addArrangedSubview(status); stack.addArrangedSubview(row); stack.addArrangedSubview(footer)
        panel.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: panel.contentView!.topAnchor, constant: 10)
        ])
        // Frame includes the titlebar; clamp again after creating the panel.
        var frame = panel.frame
        frame.origin.x = min(max(screen.visibleFrame.minX, frame.minX), screen.visibleFrame.maxX - frame.width)
        frame.origin.y = min(max(screen.visibleFrame.minY, frame.minY), screen.visibleFrame.maxY - frame.height)
        panel.setFrame(frame, display: false)
        self.panel = panel; updateButtons(); panel.orderFrontRegardless()
    }
}

private final class ScrollControlPanel: NSPanel {
    override var canBecomeKey: Bool { !ignoresMouseEvents }
    override var canBecomeMain: Bool { false }
}
private final class ScrollBorderView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.setStroke()
        let border = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1)); border.lineWidth = 2; border.stroke()
    }
}
