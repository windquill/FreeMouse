import Testing
@testable import FreeMouse

@MainActor struct SystemTranslationTests {
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
