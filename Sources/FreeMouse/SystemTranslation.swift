import AppKit
import SwiftUI
import Translation
import Vision
import NaturalLanguage
import AVFoundation

@MainActor final class SystemTranslationWindow {
    private var window: NSWindow?
    let state = SystemTranslationState()
    var onSelect: (() -> Void)?
    func hideForSelection() { window?.orderOut(nil) }
    func restoreAfterCancellation() { if window != nil { show() } }
    func recognize(_ image: CGImage) {
        state.busy = true
        state.text = ""; state.result = ""; state.error = nil
        state.status = "正在识别框选文字…"
        show()
        Task {
            do {
                let text = try await Task.detached(priority: .userInitiated) {
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.automaticallyDetectsLanguage = true
                    request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US", "ja-JP", "ko-KR"]
                    request.usesLanguageCorrection = true
                    try VNImageRequestHandler(cgImage: image).perform([request])
                    return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
                }.value
                state.acceptRecognizedText(text)
            } catch {
                state.busy = false; state.status = "识别失败"
                state.error = "文字识别失败：\(error.localizedDescription)。请重新框选。"
            }
        }
    }
    private func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 510),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "划选翻译"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SystemTranslationView(state: state,
                select: { [weak self] in self?.onSelect?() },
                pin: { [weak window] in
                    guard let window else { return }
                    window.level = window.level == .floating ? .normal : .floating
                }))
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor final class SystemTranslationState: ObservableObject {
    @Published var text = ""
    @Published var result = ""
    @Published var source = "auto"
    @Published var target = "zh-Hans"
    @Published var configuration: TranslationSession.Configuration?
    @Published var busy = false
    @Published var error: String?
    @Published var status = ""
    private(set) var requestText = ""
    private let speaker = AVSpeechSynthesizer()

    func acceptRecognizedText(_ value: String) {
        text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        translate()
    }
    func translate() {
        requestText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        result = ""; error = nil
        guard !requestText.isEmpty else {
            busy = false; status = "未识别到文字"
            error = "未识别到文字，请重新框选清晰的文字区域。"
            return
        }
        let detected = source == "auto" ? NLLanguageRecognizer.dominantLanguage(for: requestText)?.rawValue : source
        if let detected,
           Locale.Language(identifier: detected).languageCode == Locale.Language(identifier: target).languageCode,
           Locale.Language(identifier: detected).script == Locale.Language(identifier: target).script {
            result = requestText; busy = false; status = "原文与目标语言相同"
            return
        }
        busy = true; status = "系统翻译中…"
        let sourceLanguage = source == "auto" ? nil : Locale.Language(identifier: source)
        if let current = configuration, current.target?.minimalIdentifier == target,
           current.source?.minimalIdentifier == sourceLanguage?.minimalIdentifier {
            configuration?.invalidate()
        } else {
            configuration = .init(source: sourceLanguage, target: Locale.Language(identifier: target))
        }
    }
    func copy(_ value: String) {
        guard !value.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
    func speak(_ value: String, language: String?) {
        speaker.stopSpeaking(at: .immediate)
        guard !value.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: value)
        if let language { utterance.voice = AVSpeechSynthesisVoice(language: language) }
        speaker.speak(utterance)
    }
}

struct SystemTranslationView: View {
    @ObservedObject var state: SystemTranslationState
    var select: () -> Void = {}
    var pin: () -> Void = {}
    private let languages = [("中文简体", "zh-Hans"), ("中文繁體", "zh-Hant"), ("English", "en"),
        ("日本語", "ja"), ("한국어", "ko"), ("Français", "fr"), ("Deutsch", "de"), ("Español", "es")]
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button(action: pin) { Image(systemName: "pin") }.help("切换置顶")
                Spacer()
                Text(state.status).font(.caption).foregroundStyle(.secondary)
                if state.busy { ProgressView().controlSize(.small) }
                Button(action: select) { Image(systemName: "viewfinder") }.help("重新框选翻译").disabled(state.busy)
            }.buttonStyle(.borderless)
            VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: $state.text).font(.system(size: 17)).scrollContentBackground(.hidden)
                    .frame(minHeight: 100).disabled(state.busy).accessibilityLabel("识别原文")
                controls(state.text, language: state.source == "auto" ? nil : state.source)
            }.padding(14).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
            HStack {
                Picker("原文", selection: $state.source) {
                    Text("自动检测").tag("auto")
                    ForEach(languages, id: \.1) { Text($0.0).tag($0.1) }
                }.labelsHidden()
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                Picker("译文", selection: $state.target) {
                    ForEach(languages, id: \.1) { Text($0.0).tag($0.1) }
                }.labelsHidden()
            }.disabled(state.busy).padding(12)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 12) {
                Label("系统翻译", systemImage: "character.bubble").font(.headline)
                ScrollView {
                    Text(state.result.isEmpty ? (state.busy ? state.status : "译文会自动显示在这里") : state.result)
                        .font(.system(size: 17)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(minHeight: 110)
                controls(state.result, language: state.target)
            }.padding(14).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
            if let error = state.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Text("框选后自动识别并翻译；首次使用可能下载系统语言包。")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("重新翻译") { state.translate() }.disabled(state.busy || state.text.isEmpty)
            }
        }.padding(16).frame(minWidth: 460, minHeight: 440)
            .onChange(of: state.target) { _, _ in if !state.busy { state.translate() } }
            .onChange(of: state.source) { _, _ in if !state.busy { state.translate() } }
            .translationTask(state.configuration) { session in
                guard state.busy else { return }
                defer { state.busy = false }
                do { state.result = try await session.translate(state.requestText).targetText; state.status = "翻译完成" }
                catch { state.error = "翻译未完成：\(error.localizedDescription)。请检查系统语言包或更换语言。"; state.status = "翻译失败" }
            }
    }
    private func controls(_ text: String, language: String?) -> some View {
        HStack(spacing: 14) {
            Button { state.speak(text, language: language) } label: { Image(systemName: "speaker.wave.2") }.help("朗读")
            Button { state.copy(text) } label: { Image(systemName: "doc.on.doc") }.help("复制")
            Spacer()
        }.buttonStyle(.borderless).disabled(state.busy || text.isEmpty)
    }
}
