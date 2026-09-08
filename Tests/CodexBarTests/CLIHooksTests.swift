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
    func `sample usage update represents session and weekly windows`() {
        let event = CodexBarCLI.sampleHookEvent(type: .usageUpdated, provider: UsageProvider.codex.rawValue)

        #expect(event.usagePercent == 0.5)
        #expect(event.windowMinutes == 300)
        #expect(event.resetAt != nil)
        #expect(event.secondaryUsagePercent == 0.4)
        #expect(event.secondaryWindowMinutes == 10080)
        #expect(event.secondaryResetAt != nil)
    }

    @Test
    func `usage updated event carries primary and secondary quota windows`() throws {
        let primaryReset = try #require(ISO8601DateFormatter().date(from: "2026-09-08T12:00:00Z"))
        let secondaryReset = try #require(ISO8601DateFormatter().date(from: "2026-09-10T12:00:00Z"))
        let event = HookEvent(
            event: .usageUpdated,
            provider: UsageProvider.codex.rawValue,
            window: "Session",
            usagePercent: 0.2,
            resetAt: primaryReset,
            secondaryUsagePercent: 0.6,
            secondaryResetAt: secondaryReset,
            timestamp: primaryReset)

        let data = try event.jsonPayload()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(HookEvent.self, from: data)

        #expect(decoded.event == .usageUpdated)
        #expect(decoded.usagePercent == 0.2)
        #expect(decoded.secondaryUsagePercent == 0.6)
        #expect(decoded.secondaryResetAt == secondaryReset)
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
