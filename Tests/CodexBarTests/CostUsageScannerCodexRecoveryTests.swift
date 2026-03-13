import Foundation
import Testing
@testable import CodexBarCore

@Suite
struct CostUsageScannerCodexRecoveryTests {
    @Test
    func codexRecoversModelFromTruncatedTurnContextPrefix() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2025, month: 12, day: 29)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))

        let model = "openai/gpt-5.2-codex"
        let truncatedTurnContext = makeTruncatedCodexPayloadLine(
            type: "turn_context",
            timestamp: iso0,
            payloadBodyPrefix: #""model":"openai/gpt-5.2-codex","notes":"#)
        let tokenCount: [String: Any] = [
            "type": "event_msg",
            "timestamp": iso1,
            "payload": [
                "type": "token_count",
                "info": [
                    "total_token_usage": [
                        "input_tokens": 100,
                        "cached_input_tokens": 20,
                        "output_tokens": 10,
                    ],
                ],
            ],
        ]

        _ = try env.writeCodexSessionFile(
            day: day,
            filename: "truncated-turn-context.jsonl",
            contents: truncatedTurnContext + env.jsonl([tokenCount]))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0

        let report = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)

        #expect(report.data.count == 1)
        #expect(report.data[0].modelsUsed == [CostUsagePricing.normalizeCodexModel(model)])
        #expect(report.data[0].totalTokens == 110)
    }

    @Test
    func codexKeepsPriorModelUntilExplicitSwitchAfterTruncatedLines() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2025, month: 12, day: 30)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))
        let iso2 = env.isoString(for: day.addingTimeInterval(2))
        let iso3 = env.isoString(for: day.addingTimeInterval(3))
        let iso4 = env.isoString(for: day.addingTimeInterval(4))
        let iso5 = env.isoString(for: day.addingTimeInterval(5))

        let firstModel = "openai/gpt-5.2-codex"
        let secondModel = "openai/gpt-5.3-codex"
        let initialContext = makeTruncatedCodexPayloadLine(
            type: "turn_context",
            timestamp: iso0,
            payloadBodyPrefix: #""model":"openai/gpt-5.2-codex","notes":"#)
        let ambiguousContext = makeTruncatedCodexPayloadLine(
            type: "turn_context",
            timestamp: iso2,
            payloadBodyPrefix: #""notes":"#)
        let switchContext: [String: Any] = [
            "type": "turn_context",
            "timestamp": iso4,
            "payload": [
                "model": secondModel,
            ],
        ]

        let tokenCount1: [String: Any] = [
            "type": "event_msg",
            "timestamp": iso1,
            "payload": [
                "type": "token_count",
                "info": [
                    "total_token_usage": [
                        "input_tokens": 100,
                        "cached_input_tokens": 20,
                        "output_tokens": 10,
                    ],
                ],
            ],
        ]
        let tokenCount2: [String: Any] = [
            "type": "event_msg",
            "timestamp": iso3,
            "payload": [
                "type": "token_count",
                "info": [
                    "total_token_usage": [
                        "input_tokens": 160,
                        "cached_input_tokens": 40,
                        "output_tokens": 16,
                    ],
                ],
            ],
        ]
        let tokenCount3: [String: Any] = [
            "type": "event_msg",
            "timestamp": iso5,
            "payload": [
                "type": "token_count",
                "info": [
                    "total_token_usage": [
                        "input_tokens": 200,
                        "cached_input_tokens": 50,
                        "output_tokens": 20,
                    ],
                ],
            ],
        ]

        let contents = try initialContext
            + env.jsonl([tokenCount1])
            + ambiguousContext
            + env.jsonl([tokenCount2])
            + env.jsonl([switchContext])
            + env.jsonl([tokenCount3])
        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "mixed-models.jsonl",
            contents: contents)

        let range = CostUsageScanner.CostUsageDayRange(since: day, until: day)
        let parsed = CostUsageScanner.parseCodexFile(fileURL: fileURL, range: range)
        let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: day)
        let firstPacked = parsed.days[dayKey]?[CostUsagePricing.normalizeCodexModel(firstModel)] ?? []
        let secondPacked = parsed.days[dayKey]?[CostUsagePricing.normalizeCodexModel(secondModel)] ?? []

        #expect(firstPacked == [160, 40, 16])
        #expect(secondPacked == [40, 10, 4])
        #expect(parsed.lastModel == secondModel)
    }

    @Test
    func codexDailyReportIgnoresLegacyCacheArtifactAndRecomputesBuckets() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2025, month: 12, day: 31)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))
        let model = "openai/gpt-5.2-codex"
        let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: day)

        let legacyCacheURL = env.cacheRoot
            .appendingPathComponent("cost-usage", isDirectory: true)
            .appendingPathComponent("codex-v1.json", isDirectory: false)
        try FileManager.default.createDirectory(
            at: legacyCacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let staleCache = CostUsageCache(
            version: 1,
            lastScanUnixMs: Int64(day.timeIntervalSince1970 * 1000),
            files: [
                "/tmp/stale-session.jsonl": CostUsageScanner.makeFileUsage(
                    mtimeUnixMs: 1,
                    size: 1,
                    days: [dayKey: ["gpt-5": [999, 0, 1]]],
                    parsedBytes: 1,
                    lastModel: "gpt-5",
                    lastTotals: CostUsageCodexTotals(input: 999, cached: 0, output: 1),
                    sessionId: "stale-session"),
            ],
            days: [dayKey: ["gpt-5": [999, 0, 1]]],
            roots: nil)
        let staleData = try JSONEncoder().encode(staleCache)
        try staleData.write(to: legacyCacheURL, options: [.atomic])

        let truncatedTurnContext = makeTruncatedCodexPayloadLine(
            type: "turn_context",
            timestamp: iso0,
            payloadBodyPrefix: #""model":"openai/gpt-5.2-codex","notes":"#)
        let tokenCount: [String: Any] = [
            "type": "event_msg",
            "timestamp": iso1,
            "payload": [
                "type": "token_count",
                "info": [
                    "total_token_usage": [
                        "input_tokens": 100,
                        "cached_input_tokens": 20,
                        "output_tokens": 10,
                    ],
                ],
            ],
        ]
        _ = try env.writeCodexSessionFile(
            day: day,
            filename: "cache-rollout.jsonl",
            contents: truncatedTurnContext + env.jsonl([tokenCount]))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 3600

        let report = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)

        let currentCacheURL = CostUsageCacheIO.cacheFileURL(provider: .codex, cacheRoot: env.cacheRoot)
        #expect(currentCacheURL != legacyCacheURL)
        #expect(report.data.count == 1)
        #expect(report.data[0].modelsUsed == [CostUsagePricing.normalizeCodexModel(model)])
        #expect(report.data[0].totalTokens == 110)
    }

    @Test
    func codexRecoversModelWhenTruncatedPrefixEndsMidUTF8Sequence() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 1, day: 1)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))
        let model = "openai/gpt-5.2-codex"

        let truncatedTurnContext = makeUTF8BoundaryTruncatedTurnContextLine(
            timestamp: iso0,
            model: model)
        let tokenCount: [String: Any] = [
            "type": "event_msg",
            "timestamp": iso1,
            "payload": [
                "type": "token_count",
                "info": [
                    "total_token_usage": [
                        "input_tokens": 120,
                        "cached_input_tokens": 24,
                        "output_tokens": 12,
                    ],
                ],
            ],
        ]

        _ = try env.writeCodexSessionFile(
            day: day,
            filename: "utf8-boundary.jsonl",
            contents: truncatedTurnContext + env.jsonl([tokenCount]))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0

        let report = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)

        #expect(report.data.count == 1)
        #expect(report.data[0].modelsUsed == [CostUsagePricing.normalizeCodexModel(model)])
        #expect(report.data[0].totalTokens == 132)
    }
}

private func makeTruncatedCodexPayloadLine(
    type: String,
    timestamp: String? = nil,
    payloadBodyPrefix: String,
    fillerCount: Int = 40000) -> String
{
    let filler = String(repeating: "a", count: fillerCount)
    var fields = [#""type":"\#(type)""#]
    if let timestamp {
        fields.append(#""timestamp":"\#(timestamp)""#)
    }
    let payload = #""payload":{"# + payloadBodyPrefix + filler + #""}"#
    fields.append(payload)
    return "{\(fields.joined(separator: ","))}\n"
}

private func makeUTF8BoundaryTruncatedTurnContextLine(timestamp: String, model: String) -> String {
    let prefixStart = #"{"type":"turn_context","timestamp":"\#(timestamp)","payload":{"model":"\#(model)","notes":""#
    let prefixByteLimit = 32 * 1024
    let prefixBytes = prefixStart.lengthOfBytes(using: .utf8)
    let paddingCount = (0...3).first { candidate in
        (prefixByteLimit - prefixBytes - candidate) % 4 != 0
    } ?? 1
    let filler = String(repeating: "a", count: paddingCount) + String(repeating: "🙂", count: 10000)
    return prefixStart + filler + #""}}"# + "\n"
}
