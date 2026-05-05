import Testing
@testable import CodexBar

struct GeminiLoginAlertTests {
    @Test
    func `returns alert for missing binary`() {
        let result = GeminiLoginRunner.Result(outcome: .missingBinary)
        let info = StatusItemController.geminiLoginAlertInfo(for: result)
        #expect(info?.title == "Gemini CLI not found")
        #expect(info?.message == "Install the Gemini CLI (npm i -g @google/gemini-cli) and try again.")
    }

    @Test
    func `returns alert for launch failure`() {
        let result = GeminiLoginRunner.Result(outcome: .launchFailed("Boom"))
        let info = StatusItemController.geminiLoginAlertInfo(for: result)
        #expect(info?.title == "Could not open Terminal for Gemini")
        #expect(info?.message == "Boom")
    }

    @Test
    func `returns nil on success`() {
        let result = GeminiLoginRunner.Result(outcome: .success)
        let info = StatusItemController.geminiLoginAlertInfo(for: result)
        #expect(info == nil)
    }
}
