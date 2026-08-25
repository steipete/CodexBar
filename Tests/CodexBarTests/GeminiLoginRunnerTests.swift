import Testing
@testable import CodexBar

struct GeminiLoginRunnerTests {
    @Test
    func `skips the Gemini CLI when the consumer tier deprecation was observed`() async {
        let result = await GeminiLoginRunner.run(consumerTierDeprecationObserved: true) {
            Issue.record("Credentials watcher must not be armed when the Gemini CLI is skipped")
        }
        guard case .consumerTierDeprecated = result.outcome else {
            Issue.record("Expected consumerTierDeprecated outcome, got \(result.outcome)")
            return
        }
    }
}
