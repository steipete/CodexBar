import Foundation
import Testing
@testable import CodexBarCore

struct CostUsageScannerClaudeFableTests {
    @Test
    func `claude fable 5 issue row gets priced`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 6, day: 9)
        let fileURL = try env.writeClaudeProjectFile(
            relativePath: "project-a/fable-5.jsonl",
            contents: env.jsonl([
                [
                    "message": [
                        "model": "claude-fable-5",
                        "id": "msg_fable_5",
                        "type": "message",
                        "role": "assistant",
                        "usage": [
                            "input_tokens": 100,
                            "cache_creation_input_tokens": 10,
                            "cache_read_input_tokens": 20,
                            "output_tokens": 5,
                        ],
                    ],
                    "requestId": "req_fable_5",
                    "type": "assistant",
                    "timestamp": "2026-06-09T12:00:00.000Z",
                    "sessionId": "session_fable_5",
                ],
            ]))

        let parsed = CostUsageScanner.parseClaudeFile(
            fileURL: fileURL,
            range: CostUsageScanner.CostUsageDayRange(since: day, until: day),
            providerFilter: .all)

        #expect(parsed.rows.count == 1)
        #expect(parsed.rows[0].model == "claude-fable-5")
        let expected = 0.001395
        #expect(abs((Double(parsed.rows[0].costNanos) / 1_000_000_000) - expected) < 0.000000001)
    }

    @Test
    func `claude transcript refusal remains priced without billing provenance`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 6, day: 9)
        let fileURL = try env.writeClaudeProjectFile(
            relativePath: "project-a/fable-5-refusal.jsonl",
            contents: env.jsonl([
                [
                    "message": [
                        "model": "claude-fable-5",
                        "id": "msg_fable_5_refusal",
                        "type": "message",
                        "role": "assistant",
                        "stop_reason": "refusal",
                        "usage": [
                            "input_tokens": 100,
                            "cache_creation_input_tokens": 10,
                            "cache_read_input_tokens": 20,
                            "output_tokens": 0,
                        ],
                    ],
                    "requestId": "req_fable_5_refusal",
                    "type": "assistant",
                    "timestamp": "2026-06-09T12:00:00.000Z",
                    "sessionId": "session_fable_5_refusal",
                ],
            ]))

        let parsed = CostUsageScanner.parseClaudeFile(
            fileURL: fileURL,
            range: CostUsageScanner.CostUsageDayRange(since: day, until: day),
            providerFilter: .all)

        #expect(parsed.rows.count == 1)
        #expect(parsed.rows[0].input == 100)
        #expect(parsed.rows[0].cacheCreate == 10)
        #expect(parsed.rows[0].cacheRead == 20)
        #expect(parsed.rows[0].output == 0)
        let expected = 0.001145
        #expect(abs((Double(parsed.rows[0].costNanos) / 1_000_000_000) - expected) < 0.000000001)
        #expect(parsed.rows[0].costPriced == true)
    }

    @Test
    func `claude fable 5 prices one hour cache creation tokens`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 6, day: 9)
        let fileURL = try env.writeClaudeProjectFile(
            relativePath: "project-a/fable-5-cache-ttl.jsonl",
            contents: env.jsonl([
                [
                    "message": [
                        "model": "claude-fable-5",
                        "id": "msg_fable_5_cache_ttl",
                        "type": "message",
                        "role": "assistant",
                        "usage": [
                            "input_tokens": 100,
                            "cache_creation_input_tokens": 30,
                            "cache_creation": [
                                "ephemeral_5m_input_tokens": 10,
                                "ephemeral_1h_input_tokens": 20,
                            ],
                            "cache_read_input_tokens": 20,
                            "output_tokens": 5,
                        ],
                    ],
                    "requestId": "req_fable_5_cache_ttl",
                    "type": "assistant",
                    "timestamp": "2026-06-09T12:00:00.000Z",
                    "sessionId": "session_fable_5_cache_ttl",
                ],
            ]))

        let parsed = CostUsageScanner.parseClaudeFile(
            fileURL: fileURL,
            range: CostUsageScanner.CostUsageDayRange(since: day, until: day),
            providerFilter: .all)

        #expect(parsed.rows.count == 1)
        #expect(parsed.rows[0].cacheCreate == 30)
        #expect(parsed.rows[0].cacheCreate1h == 20)
        let expected = 0.001795
        #expect(abs((Double(parsed.rows[0].costNanos) / 1_000_000_000) - expected) < 0.000000001)
    }

    @Test
    func `claude cached rows preserve one hour writes for deferred pricing`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 6, day: 9)
        _ = try env.writeClaudeProjectFile(
            relativePath: "project-a/custom-cache-ttl.jsonl",
            contents: env.jsonl([
                [
                    "message": [
                        "model": "claude-custom-cache-model",
                        "id": "msg_custom_cache_ttl",
                        "type": "message",
                        "role": "assistant",
                        "usage": [
                            "input_tokens": 100,
                            "cache_creation_input_tokens": 30,
                            "cache_creation": [
                                "ephemeral_5m_input_tokens": 10,
                                "ephemeral_1h_input_tokens": 20,
                            ],
                            "cache_read_input_tokens": 20,
                            "output_tokens": 5,
                        ],
                    ],
                    "requestId": "req_custom_cache_ttl",
                    "type": "assistant",
                    "timestamp": "2026-06-09T12:00:00.000Z",
                    "sessionId": "session_custom_cache_ttl",
                ],
            ]))

        var options = CostUsageScanner.Options(
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0

        let unpriced = CostUsageScanner.loadDailyReport(
            provider: .claude,
            since: day,
            until: day,
            now: day,
            options: options)
        #expect(unpriced.summary?.totalCostUSD == nil)

        let cached = CostUsageCacheIO.load(provider: .claude, cacheRoot: env.cacheRoot)
        #expect(cached.days["2026-06-09"]?["claude-custom-cache-model"]?[safe: 7] == 20)

        try ModelsDevCache.save(
            catalog: Self.anthropicModelsDevCatalog(model: "claude-custom-cache-model"),
            fetchedAt: day,
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 3600

        let repriced = CostUsageScanner.loadDailyReport(
            provider: .claude,
            since: day,
            until: day,
            now: day.addingTimeInterval(1),
            options: options)

        let expected = 0.001795
        #expect(abs((repriced.summary?.totalCostUSD ?? 0) - expected) < 0.000000001)
    }

    @Test
    func `claude deferred pricing preserves request long context boundaries`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 6, day: 9)
        _ = try env.writeClaudeProjectFile(
            relativePath: "project-a/custom-threshold.jsonl",
            contents: env.jsonl([
                Self.claudeUsageEvent(
                    model: "claude-custom-threshold-model",
                    messageID: "msg_custom_threshold_1",
                    requestID: "req_custom_threshold_1",
                    inputTokens: 150_000),
                Self.claudeUsageEvent(
                    model: "claude-custom-threshold-model",
                    messageID: "msg_custom_threshold_2",
                    requestID: "req_custom_threshold_2",
                    inputTokens: 150_000),
            ]))

        var options = CostUsageScanner.Options(
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0

        let unpriced = CostUsageScanner.loadDailyReport(
            provider: .claude,
            since: day,
            until: day,
            now: day,
            options: options)
        #expect(unpriced.summary?.totalCostUSD == nil)

        try ModelsDevCache.save(
            catalog: Self.anthropicThresholdModelsDevCatalog(model: "claude-custom-threshold-model"),
            fetchedAt: day,
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 3600

        let repriced = CostUsageScanner.loadDailyReport(
            provider: .claude,
            since: day,
            until: day,
            now: day.addingTimeInterval(1),
            options: options)

        #expect(abs((repriced.summary?.totalCostUSD ?? 0) - 3) < 0.000000001)
    }

    @Test
    func `claude cached rows reprice after models dev catalog changes`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 6, day: 9)
        let model = "claude-custom-repricing-model"
        _ = try env.writeClaudeProjectFile(
            relativePath: "project-a/custom-repricing.jsonl",
            contents: env.jsonl([
                Self.claudeUsageEvent(
                    model: model,
                    messageID: "msg_custom_repricing",
                    requestID: "req_custom_repricing",
                    inputTokens: 240_000),
            ]))
        try ModelsDevCache.save(
            catalog: Self.anthropicThresholdModelsDevCatalog(model: model),
            fetchedAt: day,
            cacheRoot: env.cacheRoot)

        var options = CostUsageScanner.Options(
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0

        let premium = CostUsageScanner.loadDailyReport(
            provider: .claude,
            since: day,
            until: day,
            now: day,
            options: options)
        #expect(abs((premium.summary?.totalCostUSD ?? 0) - 4.8) < 0.000000001)

        try ModelsDevCache.save(
            catalog: Self.anthropicModelsDevCatalog(model: model),
            fetchedAt: day.addingTimeInterval(1),
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 3600

        let repriced = CostUsageScanner.loadDailyReport(
            provider: .claude,
            since: day,
            until: day,
            now: day.addingTimeInterval(2),
            options: options)

        #expect(abs((repriced.summary?.totalCostUSD ?? 0) - 2.4) < 0.000000001)
    }

    @Test
    func `claude cached historical rows keep original tariff`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 3, day: 12)
        _ = try env.writeClaudeProjectFile(
            relativePath: "project-a/sonnet-46-historical.jsonl",
            contents: env.jsonl([
                [
                    "message": [
                        "model": "claude-sonnet-4-6",
                        "id": "msg_sonnet_46_historical",
                        "type": "message",
                        "role": "assistant",
                        "usage": [
                            "input_tokens": 240_000,
                            "cache_creation_input_tokens": 0,
                            "cache_read_input_tokens": 0,
                            "output_tokens": 0,
                        ],
                    ],
                    "requestId": "req_sonnet_46_historical",
                    "type": "assistant",
                    "timestamp": "2026-03-12T12:00:00.000Z",
                    "sessionId": "session_sonnet_46_historical",
                ],
            ]))

        var options = CostUsageScanner.Options(
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0

        let initial = CostUsageScanner.loadDailyReport(
            provider: .claude,
            since: day,
            until: day,
            now: day,
            options: options)
        #expect(abs((initial.summary?.totalCostUSD ?? 0) - 1.44) < 0.000000001)

        try ModelsDevCache.save(
            catalog: Self.anthropicSonnet46StandardCatalog(),
            fetchedAt: day,
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 3600

        let cached = CostUsageScanner.loadDailyReport(
            provider: .claude,
            since: day,
            until: day,
            now: day.addingTimeInterval(1),
            options: options)

        #expect(abs((cached.summary?.totalCostUSD ?? 0) - 1.44) < 0.000000001)
    }

    private static func anthropicModelsDevCatalog(model: String) throws -> ModelsDevCatalog {
        let json = """
        {
          "anthropic": {
            "id": "anthropic",
            "models": {
              "\(model)": {
                "id": "\(model)",
                "cost": {
                  "input": 10,
                  "output": 50,
                  "cache_read": 1,
                  "cache_write": 12.5
                }
              }
            }
          }
        }
        """
        return try JSONDecoder().decode(ModelsDevCatalog.self, from: Data(json.utf8))
    }

    private static func anthropicThresholdModelsDevCatalog(model: String) throws -> ModelsDevCatalog {
        let json = """
        {
          "anthropic": {
            "id": "anthropic",
            "models": {
              "\(model)": {
                "id": "\(model)",
                "cost": {
                  "input": 10,
                  "output": 50,
                  "cache_read": 1,
                  "cache_write": 12.5,
                  "context_over_200k": {
                    "input": 20,
                    "output": 75,
                    "cache_read": 2,
                    "cache_write": 25
                  }
                }
              }
            }
          }
        }
        """
        return try JSONDecoder().decode(ModelsDevCatalog.self, from: Data(json.utf8))
    }

    private static func anthropicSonnet46StandardCatalog() throws -> ModelsDevCatalog {
        let json = """
        {
          "anthropic": {
            "id": "anthropic",
            "models": {
              "claude-sonnet-4-6": {
                "id": "claude-sonnet-4-6",
                "cost": {
                  "input": 3,
                  "output": 15,
                  "cache_read": 0.3,
                  "cache_write": 3.75
                }
              }
            }
          }
        }
        """
        return try JSONDecoder().decode(ModelsDevCatalog.self, from: Data(json.utf8))
    }

    private static func claudeUsageEvent(
        model: String,
        messageID: String,
        requestID: String,
        inputTokens: Int) -> [String: Any]
    {
        [
            "message": [
                "model": model,
                "id": messageID,
                "type": "message",
                "role": "assistant",
                "usage": [
                    "input_tokens": inputTokens,
                    "cache_creation_input_tokens": 0,
                    "cache_read_input_tokens": 0,
                    "output_tokens": 0,
                ],
            ],
            "requestId": requestID,
            "type": "assistant",
            "timestamp": "2026-06-09T12:00:00.000Z",
            "sessionId": "session_\(requestID)",
        ]
    }
}
