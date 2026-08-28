import CodexBarCore
import Foundation
import Testing
@testable import CodexBarCLI

struct CLIHooksTests {
    @Test
    func `sample quota-low event matches maximum threshold`() {
        let event = CodexBarCLI.sampleHookEvent(type: .quotaLow, provider: UsageProvider.codex.rawValue)
        let rule = HookRule(event: .quotaLow, threshold: 1, executable: "/bin/echo")

        #expect(event.usagePercent == 1)
        #expect(rule.matches(event))
    }

    @Test
    func `sample refresh failure uses production status`() {
        let event = CodexBarCLI.sampleHookEvent(type: .refreshFailed, provider: UsageProvider.codex.rawValue)

        #expect(event.status == "error")
    }

    @Test
    func `hook test JSON result is structured`() throws {
        let result = HookTestResult(
            ruleID: "fixture",
            executable: "/bin/echo",
            event: "quota_reached",
            provider: "codex",
            success: true,
            stdout: "ok",
            error: nil)
        let encoded = try #require(CodexBarCLI.encodeJSON([result], pretty: false))
        let decoded = try JSONDecoder().decode([HookTestResult].self, from: Data(encoded.utf8))

        #expect(decoded == [result])
    }
}
