import Foundation
import Testing
@testable import CodexBarCore

struct HookDispatchTests {
    private func event(
        _ type: HookEventType = .quotaReached,
        provider: String = "codex",
        usagePercent: Double? = 0.95,
        window: String? = "session") -> HookEvent
    {
        HookEvent(
            event: type,
            provider: provider,
            window: window,
            usagePercent: usagePercent,
            resetAt: Date(timeIntervalSince1970: 1_700_000_000),
            timestamp: Date(timeIntervalSince1970: 1_700_000_100))
    }

    @Test
    func `invalid timeout threshold and provider fail closed`() {
        let event = self.event(.quotaLow, provider: "codex", usagePercent: 0.95)
        #expect(!HookRule(
            event: .quotaLow,
            threshold: 1.1,
            executable: "/bin/echo").matches(event))
        #expect(!HookRule(
            event: .quotaLow,
            threshold: 0,
            executable: "/bin/echo").matches(event))
        #expect(!HookRule(
            event: .quotaLow,
            provider: "unknown",
            executable: "/bin/echo").matches(event))
        #expect(!HookRule(
            event: .quotaLow,
            executable: "/bin/echo",
            timeoutSeconds: 0).matches(event))
        #expect(!HookRule(
            event: .quotaReached,
            executable: "/bin/echo",
            arguments: Array(repeating: "x", count: HookRule.maximumArgumentCount + 1)).matches(event))
        let tooManyRules = HooksConfig(
            enabled: true,
            events: Array(
                repeating: HookRule(event: .quotaReached, executable: "/bin/echo"),
                count: HooksConfig.maximumRuleCount + 1))
        #expect(tooManyRules.matchingRules(for: event).isEmpty)
    }

    @Test
    func `runner writes the complete JSON payload to stdin`() async throws {
        let original = self.event(.quotaReached, provider: "claude", usagePercent: 0.42, window: "session")
        let result = try await HookRunner.run(
            rule: HookRule(event: .quotaReached, executable: "/bin/cat"),
            event: original)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(HookEvent.self, from: Data(result.stdout.utf8))

        #expect(decoded == original)
        #expect(result.stdout ==
            "{\"event\":\"quota_reached\",\"provider\":\"claude\",\"resetAt\":\"2023-11-14T22:13:20Z\"," +
                "\"timestamp\":\"2023-11-14T22:15:00Z\",\"usagePercent\":0.42,\"window\":\"session\"}")
    }

    @Test
    func `runner rejects payloads above the pipe-safe limit`() async {
        let oversized = HookEvent(
            event: .quotaReached,
            provider: "codex",
            account: String(repeating: "x", count: HookRunner.maximumPayloadBytes),
            timestamp: Date())

        await #expect(throws: HookRunnerError.self) {
            try await HookRunner.run(
                rule: HookRule(event: .quotaReached, executable: "/bin/cat"),
                event: oversized)
        }
    }

    @Test
    func `runner preserves whitespace and empty argument boundaries`() async throws {
        let rule = HookRule(
            event: .quotaReached,
            executable: "/usr/bin/printf",
            arguments: ["<%s>|<%s>|<%s>", "quota reached", "", "tail"])
        let result = try await HookRunner.run(rule: rule, event: self.event())

        #expect(result.stdout == "<quota reached>|<>|<tail>")
    }

    @Test
    func `dispatch coalesces repeated refresh failures`() async throws {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-hook-rate-limit-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: output) }
        let event = self.event(.refreshFailed, usagePercent: nil, window: nil)
        let config = HooksConfig(enabled: true, events: [
            HookRule(event: .refreshFailed, executable: "/usr/bin/tee", arguments: ["-a", output.path]),
        ])
        let limiter = HookRateLimiter(window: 600)

        await HookRunner.dispatch(event: event, config: config, rateLimiter: limiter)
        await HookRunner.dispatch(event: event, config: config, rateLimiter: limiter)
        let contents = try String(contentsOf: output, encoding: .utf8)

        #expect(contents.components(separatedBy: "\"event\":\"refresh_failed\"").count - 1 == 1)
    }

    @Test
    func `dispatch contains one rule failure and continues`() async {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-hook-failure-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: output) }
        let event = self.event()
        let config = HooksConfig(enabled: true, events: [
            HookRule(event: .quotaReached, executable: "/nonexistent/codexbar-hook"),
            HookRule(event: .quotaReached, executable: "/usr/bin/tee", arguments: [output.path]),
        ])

        await HookRunner.dispatch(event: event, config: config, rateLimiter: HookRateLimiter())

        #expect(FileManager.default.fileExists(atPath: output.path))
    }

    @Test
    func `disabled dispatch never invokes a rule`() async {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-hook-disabled-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: output) }
        let config = HooksConfig(enabled: false, events: [
            HookRule(event: .quotaReached, executable: "/usr/bin/tee", arguments: [output.path]),
        ])

        await HookRunner.dispatch(event: self.event(), config: config, rateLimiter: HookRateLimiter())

        #expect(!FileManager.default.fileExists(atPath: output.path))
    }
}
