import CodexBarCore
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
    func `returns antigravity guidance when consumer tier is deprecated`() {
        let result = GeminiLoginRunner.Result(outcome: .consumerTierDeprecated)
        let info = StatusItemController.geminiLoginAlertInfo(for: result)
        #expect(info?.title == "Gemini CLI login is no longer supported")
        #expect(info?.message.hasPrefix(GeminiConsumerTierMigration.deprecationError) == true)
    }

    @Test
    func `offers an account switch recovery when consumer tier is deprecated`() {
        let result = GeminiLoginRunner.Result(outcome: .consumerTierDeprecated)
        let info = StatusItemController.geminiLoginAlertInfo(for: result)
        #expect(info?.confirmButtonTitle == "Switch Account…")
        #expect(info?.message.contains(GeminiConsumerTierMigration.loginSwitchAccountPrompt) == true)
    }

    @Test
    func `plain login failures offer no recovery button`() {
        let missing = StatusItemController.geminiLoginAlertInfo(for: .init(outcome: .missingBinary))
        let failed = StatusItemController.geminiLoginAlertInfo(for: .init(outcome: .launchFailed("Boom")))
        #expect(missing?.confirmButtonTitle == nil)
        #expect(failed?.confirmButtonTitle == nil)
    }

    @Test
    func `returns nil on success`() {
        let result = GeminiLoginRunner.Result(outcome: .success)
        let info = StatusItemController.geminiLoginAlertInfo(for: result)
        #expect(info == nil)
    }
}
