import Foundation
import Testing
@testable import CodexBarCore

/// Tokscale parity for Codex token accounting (`tokscale/crates/tokscale-core/src/sessions/codex.rs`):
/// cache-read alias resolution (larger alias wins), reasoning as an independent additive bucket,
/// and stale out-of-order `token_count` rejection. Storage keeps raw counts; subset clamping
/// belongs to pricing (`codexCostUSD`).
struct CodexTokscaleParityTests {
    private struct Usage {
        let input: Int
        var cached: Int?
        var cacheRead: Int?
        let output: Int
        var reasoning: Int?
    }

    @Test
    func `cache read aliases resolve to the larger value`() throws {
        let report = try Self.scanSession("parity-cache-alias") { timestamp in
            [
                Self.turnContext(timestamp: timestamp, model: "openai/gpt-5.4"),
                Self.tokenCount(
                    timestamp: timestamp,
                    model: "openai/gpt-5.4",
                    total: Self.Usage(input: 100, cached: 0, cacheRead: 40, output: 10)),
            ]
        }
        let entry = try #require(report.data.first)
        // Some Codex builds report `cached_input_tokens` as 0 while `cache_read_input_tokens`
        // carries the real count; the larger alias wins.
        #expect(entry.inputTokens == 100)
        #expect(entry.cacheReadTokens == 40)
        #expect(entry.outputTokens == 10)
    }

    @Test
    func `cache read aliases resolve without storage clamping`() throws {
        let report = try Self.scanSession("parity-cache-clamp") { timestamp in
            [
                Self.turnContext(timestamp: timestamp, model: "openai/gpt-5.4"),
                Self.tokenCount(
                    timestamp: timestamp,
                    model: "openai/gpt-5.4",
                    total: Self.Usage(input: 100, cached: 120, output: 10)),
            ]
        }
        let entry = try #require(report.data.first)
        // Storage preserves the reported alias; pricing clamps cached to input when costing.
        #expect(entry.inputTokens == 100)
        #expect(entry.cacheReadTokens == 120)
    }

    @Test
    func `reasoning splits out of stored output but still bills at the output rate`() throws {
        let report = try Self.scanSession("parity-reasoning-split") { timestamp in
            [
                Self.turnContext(timestamp: timestamp, model: "openai/gpt-5.4"),
                Self.tokenCount(
                    timestamp: timestamp,
                    model: "openai/gpt-5.4",
                    total: Self.Usage(input: 100, cached: 0, output: 100, reasoning: 30)),
            ]
        }
        let entry = try #require(report.data.first)
        // `reasoning_output_tokens` is a subset of `output_tokens`: reports present the
        // exclusive remainder so token buckets stay additive...
        #expect(entry.inputTokens == 100)
        #expect(entry.outputTokens == 70)
        #expect(entry.reasoningTokens == 30)
        // Pricing uses the original inclusive output counter, so USD is unchanged.
        let expectedCost = try #require(CostUsagePricing.codexCostUSD(
            model: "gpt-5.4",
            inputTokens: 100,
            cachedInputTokens: 0,
            outputTokens: 100))
        #expect(entry.costUSD == expectedCost)
    }

    // MARK: - Fixtures

    private static func scanSession(
        _ sessionId: String,
        lines: (String) -> [[String: Any]]) throws -> CostUsageDailyReport
    {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 8, day: 21)
        let timestamp = env.isoString(for: day)
        var allLines: [[String: Any]] = [
            [
                "type": "session_meta",
                "timestamp": timestamp,
                "payload": [
                    "id": sessionId,
                    "timestamp": timestamp,
                ],
            ],
        ]
        allLines.append(contentsOf: lines(timestamp))
        _ = try env.writeCodexSessionFile(
            day: day,
            filename: "rollout-\(timestamp)-\(sessionId).jsonl",
            contents: env.jsonl(allLines))
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            maxCodexSessionFileBytes: 1024 * 1024,
            maxCodexScanBytesPerRefresh: 1024 * 1024)
        options.refreshMinIntervalSeconds = 0
        return CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
    }

    private static func isoString(timestamp: String, offset: TimeInterval) -> String {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: timestamp) else { return timestamp }
        return formatter.string(from: date.addingTimeInterval(offset))
    }

    private static func turnContext(timestamp: String, model: String) -> [String: Any] {
        [
            "type": "turn_context",
            "timestamp": timestamp,
            "payload": ["model": model],
        ]
    }

    private static func tokenCount(
        timestamp: String,
        model: String,
        total: Usage? = nil,
        last: Usage? = nil) -> [String: Any]
    {
        func usageObject(_ usage: Usage) -> [String: Any] {
            var object: [String: Any] = [
                "input_tokens": usage.input,
                "output_tokens": usage.output,
            ]
            if let cached = usage.cached {
                object["cached_input_tokens"] = cached
            }
            if let cacheRead = usage.cacheRead {
                object["cache_read_input_tokens"] = cacheRead
            }
            if let reasoning = usage.reasoning {
                object["reasoning_output_tokens"] = reasoning
            }
            return object
        }

        var info: [String: Any] = ["model": model]
        if let total {
            info["total_token_usage"] = usageObject(total)
        }
        if let last {
            info["last_token_usage"] = usageObject(last)
        }
        return [
            "type": "event_msg",
            "timestamp": timestamp,
            "payload": [
                "type": "token_count",
                "info": info,
            ],
        ]
    }
}
