import Testing
import Translation
import Foundation
@testable import FreeMouse

@MainActor struct SystemTranslationTests {
    @Test func detectedEnglishIsPassedToSessionAndUsesLowLatency() {
        let state = SystemTranslationState()
        state.acceptRecognizedText("Tests/FreeMouseTests")
        #expect(state.configuration?.source?.languageCode?.identifier == "en")
        if #available(macOS 26.4, *) { #expect(state.configuration?.preferredStrategy == .lowLatency) }
    }
    @Test func cancelAndLateResponseCannotOverwriteNewRequest() {
        let state = SystemTranslationState()
        state.acceptRecognizedText("Hello world")
        let old = state.requestID
        state.cancel()
        #expect(!state.busy)
        #expect(state.configuration == nil)
        state.acceptRecognizedText("Tests/FreeMouseTests")
        let current = state.requestID
        state.finish("old", for: old)
        #expect(state.busy)
        #expect(state.result.isEmpty)
        state.finish("new", for: current)
        #expect(state.result == "new")
        #expect(!state.busy)
    }
    @Test func timeoutUnlocksUIAndIgnoresLateResult() {
        let state = SystemTranslationState()
        state.acceptRecognizedText("Hello world")
        let id = state.requestID
        state.expireRequest(id)
        #expect(!state.busy)
        #expect(state.error != nil)
        state.finish("late", for: id)
        #expect(state.result.isEmpty)
    }
    @Test func completedResultIsCachedButLanguageChangeMissesCache() {
        let state = SystemTranslationState()
        state.acceptRecognizedText("Hello world")
        state.finish("你好", for: state.requestID)
        state.acceptRecognizedText("Hello world")
        #expect(!state.busy)
        #expect(state.result == "你好")
        state.target = "ja"
        state.translate()
        #expect(state.busy)
        #expect(state.result.isEmpty)
    }
    @Test func recognizedTextImmediatelyStartsTranslation() {
        let state = SystemTranslationState()
        state.acceptRecognizedText("  Hello world\n ")
        #expect(state.text == "Hello world")
        #expect(state.busy)
        #expect(state.configuration != nil)
        #expect(state.requestText == "Hello world")
    }
    @Test func blankRecognitionDoesNotStartSession() {
        let state = SystemTranslationState()
        state.acceptRecognizedText(" \n ")
        #expect(!state.busy)
        #expect(state.configuration == nil)
        #expect(state.error != nil)
    }
    @Test func chineseScriptChangeDoesNotReturnUnchangedOriginal() {
        let state = SystemTranslationState()
        state.source = "zh-Hans"
        state.target = "zh-Hant"
        state.acceptRecognizedText("这是简体中文测试。")
        #expect(state.busy)
        #expect(state.configuration != nil)
        #expect(state.result.isEmpty)
    }
    @Test func sameLanguageDisplaysOriginalWithoutUnsupportedSession() {
        let state = SystemTranslationState()
        state.target = "en"
        state.acceptRecognizedText("This is a simple English sentence for translation.")
        #expect(!state.busy)
        #expect(state.result == state.text)
        #expect(state.configuration == nil)
    }
}
