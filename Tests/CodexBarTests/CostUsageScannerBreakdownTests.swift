import CryptoKit
import Foundation
import Testing
@testable import CodexBarCore

// swiftlint:disable file_length
// swiftlint:disable type_body_length
struct CostUsageScannerBreakdownTests {
    private typealias Usage = (input: Int, cached: Int, output: Int)

    private func codexTurnContext(timestamp: String, model: String) -> [String: Any] {
        [
            "type": "turn_context",
            "timestamp": timestamp,
            "payload": [
                "model": model,
            ],
        ]
    }

    private func codexTokenCount(
        timestamp: String,
        model: String,
        total: Usage? = nil,
        last: Usage? = nil) -> [String: Any]
    {
        var info: [String: Any] = [
            "model": model,
        ]
        if let total {
            info["total_token_usage"] = [
                "input_tokens": total.input,
                "cached_input_tokens": total.cached,
                "output_tokens": total.output,
            ]
        }
        if let last {
            info["last_token_usage"] = [
                "input_tokens": last.input,
                "cached_input_tokens": last.cached,
                "output_tokens": last.output,
            ]
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

    private func codexTokenCountWithoutModel(timestamp: String, last: Usage) -> [String: Any] {
        [
            "type": "event_msg",
            "timestamp": timestamp,
            "payload": [
                "type": "token_count",
                "info": [
                    "last_token_usage": [
                        "input_tokens": last.input,
                        "cached_input_tokens": last.cached,
                        "output_tokens": last.output,
                    ],
                ],
            ],
        ]
    }

    private func oversizedCodexTurnContextLine(timestamp: String, model: String) -> String {
        let largeInstructions = String(repeating: "x", count: 300 * 1024)
        return #"{"type":"turn_context","timestamp":""#
            + timestamp
            + #"","payload":{"model":""#
            + model
            + #"","instructions":""#
            + largeInstructions
            + #""}}"#
    }

    private func oversizedCodexTurnContextInfoModelLine(timestamp: String, model: String) -> String {
        let largeInstructions = String(repeating: "x", count: 300 * 1024)
        return #"{"type":"turn_context","timestamp":""#
            + timestamp
            + #"","payload":{"empty":"","info":{"model":""#
            + model
            + #""},"instructions":""#
            + largeInstructions
            + #""}}"#
    }

    private func oversizedCodexTurnContextPromptOnlyLine(timestamp: String, promptModel: String) -> String {
        let prompt = #"example: {\"type\":\"turn_context\",\"payload\":{\"model\":\"\#(promptModel)\"}}"#
            + String(repeating: "x", count: 300 * 1024)
        return #"{"type":"turn_context","timestamp":""#
            + timestamp
            + #"","payload":{"instructions":""#
            + prompt
            + #""}}"#
    }

    @Test
    func `codex daily report parses token counts and caches`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2025, month: 12, day: 20)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))
        let iso2 = env.isoString(for: day.addingTimeInterval(2))

        let model = "openai/gpt-5.2-codex"
        let turnContext: [String: Any] = [
            "type": "turn_context",
            "timestamp": iso0,
            "payload": [
                "model": model,
            ],
        ]
        let firstTokenCount: [String: Any] = [
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
                    "model": model,
                ],
            ],
        ]

        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "session.jsonl",
            contents: env.jsonl([turnContext, firstTokenCount]))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"))
        options.refreshMinIntervalSeconds = 0

        let first = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        #expect(first.data.count == 1)
        #expect(first.data[0].modelsUsed == ["gpt-5.2-codex"])
        #expect(first.data[0].modelBreakdowns == [
            CostUsageDailyReport.ModelBreakdown(
                modelName: "gpt-5.2-codex",
                costUSD: first.data[0].costUSD,
                totalTokens: 110),
        ])
        #expect(first.data[0].totalTokens == 110)
        #expect((first.data[0].costUSD ?? 0) > 0)
        let firstCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        #expect(firstCache.codexPricingKey?.hasPrefix("builtin-") == true)

        let secondTokenCount: [String: Any] = [
            "type": "event_msg",
            "timestamp": iso2,
            "payload": [
                "type": "token_count",
                "info": [
                    "total_token_usage": [
                        "input_tokens": 160,
                        "cached_input_tokens": 40,
                        "output_tokens": 16,
                    ],
                    "model": model,
                ],
            ],
        ]
        try env.jsonl([turnContext, firstTokenCount, secondTokenCount])
            .write(to: fileURL, atomically: true, encoding: .utf8)

        let second = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        #expect(second.data.count == 1)
        #expect(second.data[0].modelsUsed == ["gpt-5.2-codex"])
        #expect(second.data[0].totalTokens == 176)
        #expect((second.data[0].costUSD ?? 0) > (first.data[0].costUSD ?? 0))
    }

    @Test
    func `codex incremental append falls back to rescan when fork metadata appears late`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 3, day: 11)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))
        let iso2 = env.isoString(for: day.addingTimeInterval(2))
        let iso3 = env.isoString(for: day.addingTimeInterval(3))
        let model = "gpt-5.4"
        let sessionMeta: [String: Any] = [
            "type": "session_meta",
            "timestamp": iso0,
            "payload": ["id": "late-fork-child"],
        ]
        let turnContext = self.codexTurnContext(timestamp: iso0, model: model)
        let firstTokenCount = self.codexTokenCount(
            timestamp: iso1,
            model: model,
            total: (input: 10, cached: 0, output: 0),
            last: (input: 10, cached: 0, output: 0))
        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "late-fork-child.jsonl",
            contents: env.jsonl([sessionMeta, turnContext, firstTokenCount]))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"))
        options.refreshMinIntervalSeconds = 0

        let first = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        #expect(first.data.first?.totalTokens == 10)

        let lateForkMeta: [String: Any] = [
            "type": "session_meta",
            "timestamp": iso2,
            "payload": [
                "id": "late-fork-child",
                "forked_from_id": "missing-parent",
                "timestamp": iso2,
            ],
        ]
        let replayedForkUsage = self.codexTokenCount(
            timestamp: iso3,
            model: model,
            total: (input: 1000, cached: 900, output: 100),
            last: (input: 1000, cached: 900, output: 100))
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(("\n" + env.jsonl([lateForkMeta, replayedForkUsage])).utf8))
        try handle.close()

        let second = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        #expect(second.data.first?.totalTokens == 10)
    }

    @Test
    func `codex daily report reprices cached sessions when models dev pricing changes`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))
        let olderDay = try env.makeLocalNoon(year: 2026, month: 5, day: 5)
        let olderFileURL = try env.writeCodexSessionFile(
            day: olderDay,
            filename: "older-session.jsonl",
            contents: env.jsonl([
                self.codexTurnContext(timestamp: env.isoString(for: olderDay), model: "custom-codex-model"),
                self.codexTokenCount(
                    timestamp: env.isoString(for: olderDay.addingTimeInterval(1)),
                    model: "custom-codex-model",
                    last: (input: 100, cached: 20, output: 10)),
            ]))
        try FileManager.default.setAttributes(
            [.modificationDate: olderDay],
            ofItemAtPath: olderFileURL.path)

        let model = "custom-codex-model"
        _ = try env.writeCodexSessionFile(
            day: day,
            filename: "session.jsonl",
            contents: env.jsonl([
                self.codexTurnContext(timestamp: iso0, model: model),
                self.codexTokenCount(timestamp: iso1, model: model, last: (input: 100, cached: 20, output: 10)),
            ]))

        try ModelsDevCache.save(
            catalog: Self.modelsDevCatalog(model: model, input: 1, output: 2, cacheRead: 0.5),
            fetchedAt: Date(timeIntervalSince1970: 1),
            cacheRoot: env.cacheRoot)

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"))
        options.refreshMinIntervalSeconds = 0

        let first = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: olderDay,
            until: day,
            now: day,
            options: options)
        let oldDailyCost = (80.0 / 1_000_000.0) + (20.0 * 0.5 / 1_000_000.0)
            + (10.0 * 2.0 / 1_000_000.0)
        let costTolerance = 0.000000001
        #expect(abs((first.summary?.totalCostUSD ?? 0) - (oldDailyCost * 2)) < costTolerance)

        try ModelsDevCache.save(
            catalog: Self.modelsDevCatalog(model: model, input: 1, output: 2, cacheRead: 0.5),
            fetchedAt: Date(timeIntervalSince1970: 2),
            cacheRoot: env.cacheRoot)

        options.refreshMinIntervalSeconds = 60
        let samePricing = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(1),
            options: options)
        let samePricingCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        #expect(abs((samePricing.summary?.totalCostUSD ?? 0) - oldDailyCost) < costTolerance)
        #expect(samePricingCache.scanSinceKey == "2026-05-04")

        try ModelsDevCache.save(
            catalog: Self.modelsDevCatalog(model: model, input: 10, output: 20, cacheRead: 5),
            fetchedAt: Date(timeIntervalSince1970: 2),
            cacheRoot: env.cacheRoot)

        options.refreshMinIntervalSeconds = 60
        let narrowRepriced = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(2),
            options: options)
        let newDailyCost = (80.0 * 10.0 / 1_000_000.0)
            + (20.0 * 5.0 / 1_000_000.0)
            + (10.0 * 20.0 / 1_000_000.0)
        #expect(abs((narrowRepriced.summary?.totalCostUSD ?? 0) - newDailyCost) < costTolerance)

        let wideRepriced = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: olderDay,
            until: day,
            now: day.addingTimeInterval(3),
            options: options)

        #expect(abs((wideRepriced.summary?.totalCostUSD ?? 0) - (newDailyCost * 2)) < costTolerance)
    }

    @Test
    func `codex daily report reprices cached costs when cost formula version changes`() throws {
        // Costs are persisted per file as precomputed nanos and only recomputed when the pricing
        // key changes. A formula-only fix (rates unchanged) must still invalidate caches written
        // by an older formula, otherwise stale (e.g. inflated) costs would be reused indefinitely.
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))
        let model = "gpt-5.5"
        _ = try env.writeCodexSessionFile(
            day: day,
            filename: "session.jsonl",
            contents: env.jsonl([
                self.codexTurnContext(timestamp: iso0, model: model),
                self.codexTokenCount(timestamp: iso1, model: model, last: (input: 100, cached: 20, output: 10)),
            ]))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"))
        options.refreshMinIntervalSeconds = 0

        let first = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        // gpt-5.5 built-in: only the 80 non-cached input tokens bill at the input rate.
        let correctCost = (80.0 * 5e-6) + (20.0 * 5e-7) + (10.0 * 3e-5)
        let tolerance = 0.000000001
        #expect(abs((first.summary?.totalCostUSD ?? 0) - correctCost) < tolerance)

        // Simulate a cache written by the previous formula. Its key hashed only the rates, so
        // derive that exact legacy key and verify the formula version makes the current key differ.
        var cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let legacyPricingKey = "builtin-\(Self.sha256Hex(CostUsagePricing.codexBuiltInPricingFingerprint()))"
        let currentPricingKey = try #require(cache.codexPricingKey)
        #expect(currentPricingKey != legacyPricingKey)
        cache.codexPricingKey = legacyPricingKey
        for (path, usage) in cache.files {
            guard let costNanos = usage.codexCostNanos else { continue }
            var inflated = costNanos
            for (dayKey, models) in costNanos {
                for (modelKey, value) in models {
                    inflated[dayKey]?[modelKey] = value * 10
                }
            }
            var updated = usage
            updated.codexCostNanos = inflated
            cache.files[path] = updated
        }
        CostUsageCacheIO.save(provider: .codex, cache: cache, cacheRoot: env.cacheRoot)

        // A time-only refresh is suppressed (interval 60s), so repricing here is driven solely by
        // the pricing-key mismatch from the formula version bump.
        options.refreshMinIntervalSeconds = 60
        let repriced = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(1),
            options: options)
        #expect(abs((repriced.summary?.totalCostUSD ?? 0) - correctCost) < tolerance)
    }

    @Test
    func `codex incremental cache preserves divergent total baseline`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 18)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))
        let iso2 = env.isoString(for: day.addingTimeInterval(2))
        let model = "openai/gpt-5.4"
        let sessionMeta: [String: Any] = [
            "type": "session_meta",
            "timestamp": iso0,
            "payload": ["session_id": "divergent-session"],
        ]
        let turnContext = self.codexTurnContext(timestamp: iso0, model: model)
        let firstTokenCount = self.codexTokenCount(
            timestamp: iso1,
            model: model,
            total: (input: 50, cached: 0, output: 0),
            last: (input: 100, cached: 0, output: 0))
        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "session.jsonl",
            contents: env.jsonl([sessionMeta, turnContext, firstTokenCount]))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"))
        options.refreshMinIntervalSeconds = 0

        let first = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        #expect(first.data.first?.totalTokens == 100)

        let secondTokenCount = self.codexTokenCount(
            timestamp: iso2,
            model: model,
            total: (input: 80, cached: 0, output: 0))
        try env.jsonl([sessionMeta, turnContext, firstTokenCount, secondTokenCount])
            .write(to: fileURL, atomically: true, encoding: .utf8)

        let second = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(1),
            options: options)
        let cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let usage = cache.files.first { URL(fileURLWithPath: $0.key).lastPathComponent == fileURL.lastPathComponent }?
            .value

        #expect(second.data.first?.totalTokens == 130)
        #expect(usage?.lastTotals == nil)
        #expect(usage?.lastCountedTotals?.input == 130)
        #expect(usage?.lastRawTotalsBaseline?.input == 80)
        #expect(usage?.hasDivergentTotals == true)
    }

    @Test
    func `codex incremental cache migrates legacy rows before appending delta costs`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 18)
        let olderDay = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let olderDayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: olderDay)
        let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: day)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))
        let iso2 = env.isoString(for: day.addingTimeInterval(2))
        let model = "gpt-5.4"
        let sessionMeta: [String: Any] = [
            "type": "session_meta",
            "timestamp": iso0,
            "payload": ["session_id": "legacy-cost-session"],
        ]
        let turnContext = self.codexTurnContext(timestamp: iso0, model: model)
        let firstTokenCount = self.codexTokenCount(
            timestamp: iso1,
            model: model,
            total: (input: 10, cached: 0, output: 0))
        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "session.jsonl",
            contents: env.jsonl([sessionMeta, turnContext, firstTokenCount]))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"))
        options.refreshMinIntervalSeconds = 0

        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)

        var cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let path = try #require(cache.files.keys.first)
        var cachedUsage = try #require(cache.files[path])
        #expect(cachedUsage.sessionId == "legacy-cost-session")
        #expect(cachedUsage.lastCountedTotals?.input == 10)
        cachedUsage.codexCostNanos = nil
        cachedUsage.codexRows = [
            CostUsageScanner.CodexUsageRow(
                day: olderDayKey,
                model: CostUsagePricing.normalizeCodexModel(model),
                turnID: nil,
                eventIndex: 0,
                input: 20,
                cached: 0,
                output: 0),
            CostUsageScanner.CodexUsageRow(
                day: dayKey,
                model: CostUsagePricing.normalizeCodexModel(model),
                turnID: nil,
                eventIndex: 1,
                input: 10,
                cached: 0,
                output: 0),
        ]
        cache.files[path] = cachedUsage
        CostUsageCacheIO.save(provider: .codex, cache: cache, cacheRoot: env.cacheRoot)
        let savedUsage = try #require(CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot).files[path])
        #expect(savedUsage.codexRows?.map(\.day) == [olderDayKey, dayKey])

        let secondTokenCount = self.codexTokenCount(
            timestamp: iso2,
            model: model,
            total: (input: 15, cached: 0, output: 0))
        let appended = try "\n" + env.jsonl([secondTokenCount])
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(appended.utf8))
        try handle.close()

        let report = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(1),
            options: options)
        let expectedCost = 15.0 * 2.5e-6

        #expect(report.data.first?.totalTokens == 15)
        #expect(abs((report.summary?.totalCostUSD ?? 0) - expectedCost) < 0.000_000_001)

        var migratedCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let migratedUsage = try #require(migratedCache.files[path])
        #expect(migratedUsage.codexRows?.map(\.day) == [olderDayKey, dayKey, dayKey])
        #expect(migratedUsage.codexRows?.map(\.eventIndex) == [0, 1, 2])
        #expect(migratedUsage.codexCostNanos?[dayKey] != nil)

        let parsedBytes = migratedUsage.parsedBytes
        options.refreshMinIntervalSeconds = 60
        let repeated = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(2),
            options: options)
        migratedCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        #expect(repeated.data.first?.totalTokens == 15)
        #expect(migratedCache.files[path]?.parsedBytes == parsedBytes)
    }

    @Test
    func `codex incremental cost migration retains row identities for archive dedupe`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 18)
        let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: day)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))
        let iso2 = env.isoString(for: day.addingTimeInterval(2))
        let model = "gpt-5.4"
        let sessionMeta: [String: Any] = [
            "type": "session_meta",
            "timestamp": iso0,
            "payload": ["session_id": "incremental-migration-overlap"],
        ]
        let turnContext = self.codexTurnContext(timestamp: iso0, model: model)
        let firstTokenCount = self.codexTokenCount(
            timestamp: iso1,
            model: model,
            total: (input: 10, cached: 0, output: 0))
        let secondTokenCount = self.codexTokenCount(
            timestamp: iso2,
            model: model,
            total: (input: 15, cached: 0, output: 0))
        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "incremental-migration-overlap.jsonl",
            contents: env.jsonl([sessionMeta, turnContext, firstTokenCount]))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"))
        options.refreshMinIntervalSeconds = 0

        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)

        var cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let path = try #require(cache.files.keys.first)
        cache.files[path]?.codexCostNanos = nil
        CostUsageCacheIO.save(provider: .codex, cache: cache, cacheRoot: env.cacheRoot)

        let appended = try "\n" + env.jsonl([secondTokenCount])
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(appended.utf8))
        try handle.close()

        let appendedReport = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(1),
            options: options)
        #expect(appendedReport.summary?.totalTokens == 15)

        cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let activeRows = try #require(cache.files[path]?.codexRows)
        #expect(activeRows.map(\.eventIndex) == [0, 1])

        _ = try env.writeCodexArchivedSessionFile(
            filename: "rollout-\(dayKey)T12-00-00-incremental-migration-overlap.jsonl",
            contents: env.jsonl([sessionMeta, turnContext, firstTokenCount, secondTokenCount]))

        let overlapReport = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(2),
            options: options)
        #expect(overlapReport.summary?.totalTokens == 15)
    }

    @Test
    func `codex split cache migration does not double count existing cost maps`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 18)
        let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: day)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))
        let model = "gpt-5.4"
        let normalizedModel = CostUsagePricing.normalizeCodexModel(model)
        _ = try env.writeCodexSessionFile(
            day: day,
            filename: "session.jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "timestamp": iso0,
                    "payload": ["session_id": "split-cache-session"],
                ],
                self.codexTurnContext(timestamp: iso0, model: model),
                self.codexTokenCount(
                    timestamp: iso1,
                    model: model,
                    total: (input: 10, cached: 0, output: 0)),
            ]))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"))
        options.refreshMinIntervalSeconds = 0

        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)

        var cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let path = try #require(cache.files.keys.first)
        var cachedUsage = try #require(cache.files[path])
        let originalCostNanos = try #require(cachedUsage.codexCostNanos?[dayKey]?[normalizedModel])
        let addedModel = CostUsagePricing.normalizeCodexModel("gpt-5.5")
        cachedUsage.codexRows = [
            CostUsageScanner.CodexUsageRow(
                day: dayKey,
                model: normalizedModel,
                turnID: nil,
                eventIndex: 0,
                input: 10,
                cached: 0,
                output: 0),
            CostUsageScanner.CodexUsageRow(
                day: dayKey,
                model: addedModel,
                turnID: nil,
                eventIndex: 1,
                input: 10,
                cached: 0,
                output: 0),
        ]
        cachedUsage.codexStandardCostNanos = nil
        cachedUsage.codexPriorityCostNanos = nil
        cachedUsage.codexStandardTokens = nil
        cachedUsage.codexPriorityTokens = nil
        cache.files[path] = cachedUsage
        CostUsageCacheIO.save(provider: .codex, cache: cache, cacheRoot: env.cacheRoot)

        options.refreshMinIntervalSeconds = 60
        let report = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(1),
            options: options)

        let expectedCost = 10.0 * 2.5e-6
        #expect(abs((report.summary?.totalCostUSD ?? 0) - expectedCost) < 0.000_000_001)
        let migratedUsage = try #require(CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot).files[path])
        #expect(migratedUsage.codexRows?.map(\.eventIndex) == [0, 1])
        #expect(migratedUsage.codexCostNanos?[dayKey]?[normalizedModel] == originalCostNanos)
        #expect(migratedUsage.codexCostNanos?[dayKey]?[addedModel] == Int64((10.0 * 5e-6 * 1_000_000_000).rounded()))
        #expect(migratedUsage.codexStandardTokens?[dayKey]?[normalizedModel] == 10)
        #expect(migratedUsage.codexStandardTokens?[dayKey]?[addedModel] == 10)
    }

    @Test
    func `codex narrow full rescan preserves cached days outside scan window`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let olderDay = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 18)
        let model = "gpt-5.4"
        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "multi-day-session.jsonl",
            contents: env.jsonl([
                self.codexTurnContext(timestamp: env.isoString(for: olderDay), model: model),
                self.codexTokenCount(
                    timestamp: env.isoString(for: olderDay.addingTimeInterval(1)),
                    model: model,
                    last: (input: 20, cached: 0, output: 0)),
                self.codexTokenCount(
                    timestamp: env.isoString(for: day.addingTimeInterval(1)),
                    model: model,
                    last: (input: 10, cached: 0, output: 0)),
            ]))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"))
        options.refreshMinIntervalSeconds = 0

        let wide = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: olderDay,
            until: day,
            now: day,
            options: options)
        #expect(wide.summary?.totalTokens == 30)

        try env.jsonl([
            self.codexTurnContext(timestamp: env.isoString(for: olderDay), model: model),
            self.codexTokenCount(
                timestamp: env.isoString(for: olderDay.addingTimeInterval(1)),
                model: model,
                last: (input: 20, cached: 0, output: 0)),
            self.codexTokenCount(
                timestamp: env.isoString(for: day.addingTimeInterval(1)),
                model: model,
                last: (input: 12, cached: 0, output: 0)),
        ]).write(to: fileURL, atomically: true, encoding: .utf8)

        let narrow = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(1),
            options: options)
        #expect(narrow.summary?.totalTokens == 12)

        options.refreshMinIntervalSeconds = 60
        let repeatedWide = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: olderDay,
            until: day,
            now: day.addingTimeInterval(2),
            options: options)
        #expect(repeatedWide.summary?.totalTokens == 32)
    }

    @Test
    func `codex turn id cache migration narrows retained cache window`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let olderDay = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 18)
        let olderDayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: olderDay)
        let model = "gpt-5.4"
        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "legacy-turn-ids.jsonl",
            contents: env.jsonl([
                self.codexTurnContext(timestamp: env.isoString(for: olderDay), model: model),
                self.codexTokenCount(
                    timestamp: env.isoString(for: olderDay.addingTimeInterval(1)),
                    model: model,
                    last: (input: 20, cached: 0, output: 0)),
                self.codexTokenCount(
                    timestamp: env.isoString(for: day.addingTimeInterval(1)),
                    model: model,
                    last: (input: 10, cached: 0, output: 0)),
            ]))
        let dbURL = env.root.appendingPathComponent("logs_2.sqlite")
        try CostUsageScannerCodexPriorityTests.createTestLogsDatabase(at: dbURL)

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: dbURL)
        options.refreshMinIntervalSeconds = 0

        let wide = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: olderDay,
            until: day,
            now: day,
            options: options)
        #expect(wide.summary?.totalTokens == 30)

        var cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let path = try #require(cache.files.keys.first)
        cache.files[path]?.codexTurnIDs = nil
        CostUsageCacheIO.save(provider: .codex, cache: cache, cacheRoot: env.cacheRoot)

        try env.jsonl([
            self.codexTurnContext(timestamp: env.isoString(for: olderDay), model: model),
            self.codexTokenCount(
                timestamp: env.isoString(for: olderDay.addingTimeInterval(1)),
                model: model,
                last: (input: 20, cached: 0, output: 0)),
            self.codexTokenCount(
                timestamp: env.isoString(for: day.addingTimeInterval(1)),
                model: model,
                last: (input: 12, cached: 0, output: 0)),
        ]).write(to: fileURL, atomically: true, encoding: .utf8)

        options.refreshMinIntervalSeconds = 60
        let narrow = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(1),
            options: options)
        #expect(narrow.summary?.totalTokens == 12)

        cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        #expect(cache.scanSinceKey == "2026-05-17")
        #expect(cache.scanUntilKey == "2026-05-19")
        #expect(cache.files[path]?.days[olderDayKey] == nil)

        let repeatedWide = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: olderDay,
            until: day,
            now: day.addingTimeInterval(2),
            options: options)
        #expect(repeatedWide.summary?.totalTokens == 32)
    }

    @Test
    func `codex long turn context preserves model attribution`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 18)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))
        let model = "openai/gpt-5.5"
        let turnContext: [String: Any] = [
            "type": "turn_context",
            "timestamp": iso0,
            "payload": [
                "model": model,
                "instructions": String(repeating: "x", count: 40 * 1024),
            ],
        ]
        let tokenCount: [String: Any] = [
            "type": "event_msg",
            "timestamp": iso1,
            "payload": [
                "type": "token_count",
                "info": [
                    "last_token_usage": [
                        "input_tokens": 100,
                        "cached_input_tokens": 40,
                        "output_tokens": 10,
                    ],
                ],
            ],
        ]

        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "long-turn-context.jsonl",
            contents: env.jsonl([turnContext, tokenCount]))

        let parsed = CostUsageScanner.parseCodexFile(
            fileURL: fileURL,
            range: CostUsageScanner.CostUsageDayRange(since: day, until: day))
        let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: day)

        #expect(parsed.days[dayKey]?["gpt-5.5"] == [100, 40, 10])
        #expect(parsed.days[dayKey]?["gpt-5"] == nil)
    }

    @Test
    func `codex oversized turn context prefix preserves model attribution`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 18)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))
        let model = "openai/gpt-5.5"
        let turnContextLine = self.oversizedCodexTurnContextLine(timestamp: iso0, model: model)
        let tokenCountLine = try env.jsonl([
            self.codexTokenCountWithoutModel(timestamp: iso1, last: (input: 120, cached: 30, output: 12)),
        ])

        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "oversized-turn-context.jsonl",
            contents: turnContextLine + "\n" + tokenCountLine)

        let parsed = CostUsageScanner.parseCodexFile(
            fileURL: fileURL,
            range: CostUsageScanner.CostUsageDayRange(since: day, until: day))
        let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: day)

        #expect(parsed.days[dayKey]?["gpt-5.5"] == [120, 30, 12])
        #expect(parsed.days[dayKey]?["gpt-5"] == nil)
    }

    @Test
    func `codex oversized turn context prefix supports nested info model`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 18)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))
        let model = "openai/gpt-5.5"
        let turnContextLine = self.oversizedCodexTurnContextInfoModelLine(timestamp: iso0, model: model)
        let tokenCountLine = try env.jsonl([
            self.codexTokenCountWithoutModel(timestamp: iso1, last: (input: 120, cached: 30, output: 12)),
        ])

        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "oversized-turn-context-info-model.jsonl",
            contents: turnContextLine + "\n" + tokenCountLine)

        let parsed = CostUsageScanner.parseCodexFile(
            fileURL: fileURL,
            range: CostUsageScanner.CostUsageDayRange(since: day, until: day))
        let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: day)

        #expect(parsed.days[dayKey]?["gpt-5.5"] == [120, 30, 12])
        #expect(parsed.days[dayKey]?["gpt-5"] == nil)
    }

    @Test
    func `codex oversized turn context ignores prompt model examples`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 18)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))
        let iso2 = env.isoString(for: day.addingTimeInterval(2))
        let turnContextLine = self.oversizedCodexTurnContextPromptOnlyLine(
            timestamp: iso1,
            promptModel: "openai/gpt-5.5")
        let tokenCountLine = try env.jsonl([
            self.codexTokenCountWithoutModel(timestamp: iso2, last: (input: 120, cached: 30, output: 12)),
        ])

        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "oversized-turn-context-prompt-example.jsonl",
            contents: env.jsonl([self.codexTurnContext(timestamp: iso0, model: "openai/gpt-5.4")])
                + turnContextLine + "\n" + tokenCountLine)

        let parsed = CostUsageScanner.parseCodexFile(
            fileURL: fileURL,
            range: CostUsageScanner.CostUsageDayRange(since: day, until: day))
        let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: day)

        #expect(parsed.days[dayKey]?["gpt-5.4"] == [120, 30, 12])
        #expect(parsed.days[dayKey]?["gpt-5.5"] == nil)
    }

    @Test
    func `codex token count model applies without turn context model`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 18)

        let contents = try env.jsonl([
            self.codexTokenCount(
                timestamp: env.isoString(for: day.addingTimeInterval(1)),
                model: "openai/gpt-5.5",
                last: (input: 50, cached: 10, output: 5)),
        ])
        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "token-count-model.jsonl",
            contents: contents)

        let parsed = CostUsageScanner.parseCodexFile(
            fileURL: fileURL,
            range: CostUsageScanner.CostUsageDayRange(since: day, until: day))
        let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: day)

        #expect(parsed.days[dayKey]?["gpt-5.5"] == [50, 10, 5])
        #expect(parsed.days[dayKey]?["gpt-5"] == nil)
    }

    @Test
    func `codex daily report writes corrected cache artifact for oversized turn context`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 18)
        let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: day)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))
        let model = "openai/gpt-5.5"
        let turnContextLine = self.oversizedCodexTurnContextLine(timestamp: iso0, model: model)
        let tokenCountLine = try env.jsonl([
            self.codexTokenCountWithoutModel(timestamp: iso1, last: (input: 120, cached: 30, output: 12)),
        ])

        _ = try env.writeCodexSessionFile(
            day: day,
            filename: "cached-oversized-turn-context.jsonl",
            contents: turnContextLine + "\n" + tokenCountLine)

        let oldCacheDir = env.cacheRoot.appendingPathComponent("cost-usage", isDirectory: true)
        try FileManager.default.createDirectory(at: oldCacheDir, withIntermediateDirectories: true)
        let oldCacheURL = oldCacheDir.appendingPathComponent("codex-v7.json", isDirectory: false)
        let oldCache = #"{"version":1,"lastScanUnixMs":9999999999999,"files":{},"days":{"\#(dayKey)":"#
            + #"{"gpt-5":[999,0,0]}}}"#
        try oldCache.write(to: oldCacheURL, atomically: true, encoding: .utf8)

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 3600

        let first = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        #expect(first.data.count == 1)
        #expect(first.data[0].modelsUsed == ["gpt-5.5"])
        #expect(first.data[0].modelBreakdowns?.map(\.modelName) == ["gpt-5.5"])
        #expect(first.data[0].totalTokens == 132)

        let newCacheURL = CostUsageCacheIO.cacheFileURL(provider: .codex, cacheRoot: env.cacheRoot)
        #expect(newCacheURL.lastPathComponent == "codex-v8.json")
        #expect(FileManager.default.fileExists(atPath: newCacheURL.path))
        #expect(FileManager.default.fileExists(atPath: oldCacheURL.path))

        let second = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(60),
            options: options)
        #expect(second.data.count == 1)
        #expect(second.data[0].modelsUsed == ["gpt-5.5"])
        #expect(second.data[0].totalTokens == 132)
    }

    @Test
    func `codex daily report prefers last token usage over divergent totals`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 15)
        let iso0 = env.isoString(for: day)
        let model = "openai/gpt-5.5"
        let turnContext = self.codexTurnContext(timestamp: iso0, model: model)

        _ = try env.writeCodexSessionFile(
            day: day,
            filename: "session.jsonl",
            contents: env.jsonl([
                turnContext,
                self.codexTokenCount(
                    timestamp: env.isoString(for: day.addingTimeInterval(1)),
                    model: model,
                    total: (input: 100, cached: 20, output: 10),
                    last: (input: 100, cached: 20, output: 10)),
                self.codexTokenCount(
                    timestamp: env.isoString(for: day.addingTimeInterval(2)),
                    model: model,
                    total: (input: 160, cached: 40, output: 16),
                    last: (input: 60, cached: 20, output: 6)),
                self.codexTokenCount(
                    timestamp: env.isoString(for: day.addingTimeInterval(3)),
                    model: model,
                    total: (input: 1000, cached: 900, output: 100),
                    last: (input: 40, cached: 30, output: 5)),
                self.codexTokenCount(
                    timestamp: env.isoString(for: day.addingTimeInterval(4)),
                    model: model,
                    total: (input: 1050, cached: 930, output: 110),
                    last: (input: 50, cached: 30, output: 10)),
            ]))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0
        options.forceRescan = true

        let report = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        let expectedCost = CostUsagePricing.codexCostUSD(
            model: model,
            inputTokens: 250,
            cachedInputTokens: 100,
            outputTokens: 31)

        #expect(report.data.count == 1)
        #expect(report.data[0].inputTokens == 250)
        #expect(report.data[0].outputTokens == 31)
        #expect(report.data[0].totalTokens == 281)
        #expect(abs((report.data[0].costUSD ?? 0) - (expectedCost ?? 0)) < 0.000001)
    }

    @Test
    func `codex repeated total token snapshots do not recount last usage`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 20)
        let model = "openai/gpt-5.5"
        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "repeated-total-snapshot.jsonl",
            contents: env.jsonl([
                self.codexTurnContext(timestamp: env.isoString(for: day), model: model),
                self.codexTokenCount(
                    timestamp: env.isoString(for: day.addingTimeInterval(1)),
                    model: model,
                    total: (input: 100, cached: 20, output: 10),
                    last: (input: 100, cached: 20, output: 10)),
                self.codexTokenCount(
                    timestamp: env.isoString(for: day.addingTimeInterval(2)),
                    model: model,
                    total: (input: 100, cached: 20, output: 10),
                    last: (input: 100, cached: 20, output: 10)),
                self.codexTokenCount(
                    timestamp: env.isoString(for: day.addingTimeInterval(3)),
                    model: model,
                    total: (input: 130, cached: 20, output: 12),
                    last: (input: 100, cached: 20, output: 10)),
            ]))

        let parsed = CostUsageScanner.parseCodexFile(
            fileURL: fileURL,
            range: CostUsageScanner.CostUsageDayRange(since: day, until: day))
        let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: day)
        let packed = parsed.days[dayKey]?["gpt-5.5"] ?? []

        #expect(packed[safe: 0] == 130)
        #expect(packed[safe: 1] == 20)
        #expect(packed[safe: 2] == 12)
        #expect(parsed.rows.count == 2)
    }

    @Test
    func `codex total only after divergent totals uses raw delta when it continues`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 15)
        let model = "openai/gpt-5.5"
        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "mixed-raw-continuing.jsonl",
            contents: env.jsonl([
                self.codexTurnContext(timestamp: env.isoString(for: day), model: model),
                self.codexTokenCount(
                    timestamp: env.isoString(for: day.addingTimeInterval(1)),
                    model: model,
                    total: (input: 100, cached: 0, output: 0),
                    last: (input: 100, cached: 0, output: 0)),
                self.codexTokenCount(
                    timestamp: env.isoString(for: day.addingTimeInterval(2)),
                    model: model,
                    total: (input: 1000, cached: 0, output: 0),
                    last: (input: 40, cached: 0, output: 0)),
                self.codexTokenCount(
                    timestamp: env.isoString(for: day.addingTimeInterval(3)),
                    model: model,
                    total: (input: 1050, cached: 0, output: 0)),
            ]))

        let parsed = CostUsageScanner.parseCodexFile(
            fileURL: fileURL,
            range: CostUsageScanner.CostUsageDayRange(since: day, until: day))
        let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: day)
        let packed = parsed.days[dayKey]?["gpt-5.5"] ?? []

        #expect(packed[safe: 0] == 190)
        #expect(parsed.lastTotals == nil)
    }

    @Test
    func `codex total only after divergent totals preserves zero raw dimensions`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 15)
        let model = "openai/gpt-5.5"
        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "mixed-stale-dimension.jsonl",
            contents: env.jsonl([
                self.codexTurnContext(timestamp: env.isoString(for: day), model: model),
                self.codexTokenCount(
                    timestamp: env.isoString(for: day.addingTimeInterval(1)),
                    model: model,
                    total: (input: 100, cached: 0, output: 0),
                    last: (input: 100, cached: 0, output: 0)),
                self.codexTokenCount(
                    timestamp: env.isoString(for: day.addingTimeInterval(2)),
                    model: model,
                    total: (input: 1000, cached: 900, output: 0),
                    last: (input: 40, cached: 0, output: 0)),
                self.codexTokenCount(
                    timestamp: env.isoString(for: day.addingTimeInterval(3)),
                    model: model,
                    total: (input: 1050, cached: 900, output: 0)),
            ]))

        let parsed = CostUsageScanner.parseCodexFile(
            fileURL: fileURL,
            range: CostUsageScanner.CostUsageDayRange(since: day, until: day))
        let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: day)
        let packed = parsed.days[dayKey]?["gpt-5.5"] ?? []

        #expect(packed[safe: 0] == 190)
        #expect(packed[safe: 1] == 0)
        #expect(parsed.lastTotals == nil)
    }

    @Test
    func `codex total only after divergent totals can resume from counted baseline`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 15)
        let model = "openai/gpt-5.5"
        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "mixed-counted-resume.jsonl",
            contents: env.jsonl([
                self.codexTurnContext(timestamp: env.isoString(for: day), model: model),
                self.codexTokenCount(
                    timestamp: env.isoString(for: day.addingTimeInterval(1)),
                    model: model,
                    total: (input: 100, cached: 0, output: 0),
                    last: (input: 100, cached: 0, output: 0)),
                self.codexTokenCount(
                    timestamp: env.isoString(for: day.addingTimeInterval(2)),
                    model: model,
                    total: (input: 1000, cached: 0, output: 0),
                    last: (input: 40, cached: 0, output: 0)),
                self.codexTokenCount(
                    timestamp: env.isoString(for: day.addingTimeInterval(3)),
                    model: model,
                    total: (input: 180, cached: 0, output: 0)),
            ]))

        let parsed = CostUsageScanner.parseCodexFile(
            fileURL: fileURL,
            range: CostUsageScanner.CostUsageDayRange(since: day, until: day))
        let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: day)
        let packed = parsed.days[dayKey]?["gpt-5.5"] ?? []

        #expect(packed[safe: 0] == 180)
        #expect(parsed.lastTotals?.input == 180)
    }

    @Test
    func `codex total only after last only counts from last based baseline`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 15)
        let model = "openai/gpt-5.5"
        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "last-then-total.jsonl",
            contents: env.jsonl([
                self.codexTurnContext(timestamp: env.isoString(for: day), model: model),
                self.codexTokenCount(
                    timestamp: env.isoString(for: day.addingTimeInterval(1)),
                    model: model,
                    last: (input: 100, cached: 0, output: 0)),
                self.codexTokenCount(
                    timestamp: env.isoString(for: day.addingTimeInterval(2)),
                    model: model,
                    total: (input: 150, cached: 0, output: 0)),
            ]))

        let parsed = CostUsageScanner.parseCodexFile(
            fileURL: fileURL,
            range: CostUsageScanner.CostUsageDayRange(since: day, until: day))
        let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: day)
        let packed = parsed.days[dayKey]?["gpt-5.5"] ?? []

        #expect(packed[safe: 0] == 150)
        #expect(parsed.lastTotals?.input == 150)
    }

    @Test
    func `codex daily report includes archived sessions and dedupes`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2025, month: 12, day: 22)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))

        let model = "openai/gpt-5.2-codex"
        let sessionMeta: [String: Any] = [
            "type": "session_meta",
            "payload": [
                "session_id": "sess-archived-1",
            ],
        ]
        let turnContext: [String: Any] = [
            "type": "turn_context",
            "timestamp": iso0,
            "payload": [
                "model": model,
            ],
        ]
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
                    "model": model,
                ],
            ],
        ]

        let comps = Calendar.current.dateComponents([.year, .month, .day], from: day)
        let dayKey = String(format: "%04d-%02d-%02d", comps.year ?? 1970, comps.month ?? 1, comps.day ?? 1)
        let archivedName = "rollout-\(dayKey)T12-00-00-archived.jsonl"
        let contents = try env.jsonl([sessionMeta, turnContext, tokenCount])
        _ = try env.writeCodexArchivedSessionFile(filename: archivedName, contents: contents)

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0

        let first = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        #expect(first.data.count == 1)
        #expect(first.data[0].totalTokens == 110)

        _ = try env.writeCodexSessionFile(day: day, filename: "session.jsonl", contents: contents)
        let second = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        #expect(second.data.count == 1)
        #expect(second.data[0].totalTokens == 110)
    }

    @Test
    func `codex active session stub does not hide archived usage`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 6, day: 25)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))
        let model = "openai/gpt-5.5"
        let sessionMeta: [String: Any] = [
            "type": "session_meta",
            "payload": [
                "session_id": "sess-shared-active-archive",
            ],
        ]
        let turnContext = self.codexTurnContext(timestamp: iso0, model: model)

        _ = try env.writeCodexSessionFile(
            day: day,
            filename: "active-stub.jsonl",
            contents: env.jsonl([sessionMeta, turnContext]))

        let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: day)
        _ = try env.writeCodexArchivedSessionFile(
            filename: "rollout-\(dayKey)T12-00-00-shared.jsonl",
            contents: env.jsonl([
                sessionMeta,
                turnContext,
                self.codexTokenCount(
                    timestamp: iso1,
                    model: model,
                    last: (input: 20, cached: 500, output: 5)),
            ]))

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
        let expectedCost = CostUsagePricing.codexCostUSD(
            model: model,
            inputTokens: 20,
            cachedInputTokens: 500,
            outputTokens: 5)

        #expect(report.data.count == 1)
        #expect(report.data[0].inputTokens == 20)
        #expect(report.data[0].outputTokens == 5)
        #expect(report.data[0].totalTokens == 25)
        #expect(report.data[0].modelBreakdowns?.first?.totalTokens == 25)
        #expect(abs((report.data[0].costUSD ?? 0) - (expectedCost ?? 0)) < 0.000001)
    }

    @Test
    func `codex active session partial file keeps distinct archived rows`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 6, day: 26)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))
        let iso2 = env.isoString(for: day.addingTimeInterval(2))
        let model = "openai/gpt-5.5"
        let sessionMeta: [String: Any] = [
            "type": "session_meta",
            "payload": [
                "session_id": "sess-partial-active-archive",
            ],
        ]
        let turnContext = self.codexTurnContext(timestamp: iso0, model: model)
        let firstTurn: [String: Any] = [
            "type": "event_msg",
            "timestamp": iso1,
            "payload": [
                "type": "task_started",
                "turn_id": "turn-a",
            ],
        ]
        let firstUsage = self.codexTokenCount(
            timestamp: iso1,
            model: model,
            last: (input: 20, cached: 0, output: 5))
        let secondTurn: [String: Any] = [
            "type": "event_msg",
            "timestamp": iso2,
            "payload": [
                "type": "task_started",
                "turn_id": "turn-b",
            ],
        ]
        let secondUsage = self.codexTokenCount(
            timestamp: iso2,
            model: model,
            last: (input: 30, cached: 500, output: 7))

        _ = try env.writeCodexSessionFile(
            day: day,
            filename: "active-partial.jsonl",
            contents: env.jsonl([sessionMeta, turnContext, firstTurn, firstUsage]))

        let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: day)
        _ = try env.writeCodexArchivedSessionFile(
            filename: "rollout-\(dayKey)T12-00-00-partial.jsonl",
            contents: env.jsonl([sessionMeta, turnContext, firstTurn, firstUsage, secondTurn, secondUsage]))

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
        let expectedCost = (CostUsagePricing.codexCostUSD(
            model: model,
            inputTokens: 20,
            cachedInputTokens: 0,
            outputTokens: 5) ?? 0)
            + (CostUsagePricing.codexCostUSD(
                model: model,
                inputTokens: 30,
                cachedInputTokens: 500,
                outputTokens: 7) ?? 0)

        #expect(report.data.count == 1)
        #expect(report.data[0].inputTokens == 50)
        #expect(report.data[0].cacheReadTokens == 500)
        #expect(report.data[0].outputTokens == 12)
        #expect(report.data[0].totalTokens == 62)
        #expect(report.data[0].modelBreakdowns?.first?.totalTokens == 62)
        #expect(abs((report.data[0].costUSD ?? 0) - expectedCost) < 0.000001)

        let repeated = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(1),
            options: options)
        #expect(repeated.data.count == 1)
        #expect(repeated.data[0].inputTokens == 50)
        #expect(repeated.data[0].cacheReadTokens == 500)
        #expect(repeated.data[0].outputTokens == 12)
        #expect(repeated.data[0].totalTokens == 62)
    }

    @Test
    func `codex active archive dedupe preserves identical same turn deltas`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 6, day: 27)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))
        let iso2 = env.isoString(for: day.addingTimeInterval(2))
        let model = "openai/gpt-5.5"
        let sessionMeta: [String: Any] = [
            "type": "session_meta",
            "payload": [
                "session_id": "sess-identical-delta-active-archive",
            ],
        ]
        let turnContext = self.codexTurnContext(timestamp: iso0, model: model)
        let firstTurn: [String: Any] = [
            "type": "event_msg",
            "timestamp": iso1,
            "payload": [
                "type": "task_started",
                "turn_id": "turn-a",
            ],
        ]
        let firstUsage = self.codexTokenCount(
            timestamp: iso1,
            model: model,
            last: (input: 20, cached: 0, output: 5))
        let repeatedUsage = self.codexTokenCount(
            timestamp: iso2,
            model: model,
            last: (input: 20, cached: 0, output: 5))

        _ = try env.writeCodexSessionFile(
            day: day,
            filename: "active-identical-delta.jsonl",
            contents: env.jsonl([sessionMeta, turnContext, firstTurn, firstUsage]))

        let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: day)
        _ = try env.writeCodexArchivedSessionFile(
            filename: "rollout-\(dayKey)T12-00-00-identical-delta.jsonl",
            contents: env.jsonl([sessionMeta, turnContext, firstTurn, firstUsage, repeatedUsage]))

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
        #expect(report.data[0].inputTokens == 40)
        #expect(report.data[0].outputTokens == 10)
        #expect(report.data[0].totalTokens == 50)

        let repeated = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(1),
            options: options)
        #expect(repeated.data.count == 1)
        #expect(repeated.data[0].inputTokens == 40)
        #expect(repeated.data[0].outputTokens == 10)
        #expect(repeated.data[0].totalTokens == 50)
    }

    @Test
    func `codex files without session metadata do not dedupe each other`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 6, day: 27)
        let model = "openai/gpt-5.5"
        let contents = try env.jsonl([
            self.codexTurnContext(timestamp: env.isoString(for: day), model: model),
            self.codexTokenCount(
                timestamp: env.isoString(for: day.addingTimeInterval(1)),
                model: model,
                last: (input: 10, cached: 100, output: 1)),
        ])

        _ = try env.writeCodexSessionFile(day: day, filename: "legacy-a.jsonl", contents: contents)
        _ = try env.writeCodexSessionFile(day: day, filename: "legacy-b.jsonl", contents: contents)

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
        #expect(report.data[0].inputTokens == 20)
        #expect(report.data[0].cacheReadTokens == 200)
        #expect(report.data[0].outputTokens == 2)
        #expect(report.data[0].totalTokens == 22)
    }

    @Test
    func `codex warm cache rechecks active archive row overlap`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 6, day: 28)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))
        let iso2 = env.isoString(for: day.addingTimeInterval(2))
        let iso3 = env.isoString(for: day.addingTimeInterval(3))
        let model = "openai/gpt-5.5"
        let sessionMeta: [String: Any] = [
            "type": "session_meta",
            "payload": [
                "session_id": "sess-warm-cache-active-archive",
            ],
        ]
        let turnContext = self.codexTurnContext(timestamp: iso0, model: model)
        let firstTurn: [String: Any] = [
            "type": "event_msg",
            "timestamp": iso1,
            "payload": ["type": "task_started", "turn_id": "turn-a"],
        ]
        let firstUsage = self.codexTokenCount(
            timestamp: iso1,
            model: model,
            last: (input: 10, cached: 100, output: 1))
        let secondTurn: [String: Any] = [
            "type": "event_msg",
            "timestamp": iso2,
            "payload": ["type": "task_started", "turn_id": "turn-b"],
        ]
        let secondUsage = self.codexTokenCount(
            timestamp: iso2,
            model: model,
            last: (input: 20, cached: 500, output: 5))
        let thirdTurn: [String: Any] = [
            "type": "event_msg",
            "timestamp": iso3,
            "payload": ["type": "task_started", "turn_id": "turn-c"],
        ]
        let thirdUsage = self.codexTokenCount(
            timestamp: iso3,
            model: model,
            last: (input: 5, cached: 50, output: 2))

        _ = try env.writeCodexSessionFile(
            day: day,
            filename: "active-warm-cache.jsonl",
            contents: env.jsonl([
                sessionMeta,
                turnContext,
                firstTurn,
                firstUsage,
            ]))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0

        let first = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        #expect(first.data.first?.inputTokens == 10)
        #expect(first.data.first?.cacheReadTokens == 100)
        #expect(first.data.first?.outputTokens == 1)

        _ = try env.writeCodexSessionFile(
            day: day,
            filename: "active-warm-cache.jsonl",
            contents: env.jsonl([
                sessionMeta,
                turnContext,
                firstTurn,
                firstUsage,
                secondTurn,
                secondUsage,
            ]))

        let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: day)
        _ = try env.writeCodexArchivedSessionFile(
            filename: "rollout-\(dayKey)T12-00-00-warm-cache.jsonl",
            contents: env.jsonl([
                sessionMeta,
                turnContext,
                firstTurn,
                firstUsage,
                secondTurn,
                secondUsage,
                thirdTurn,
                thirdUsage,
            ]))

        let second = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(1),
            options: options)

        #expect(second.data.count == 1)
        #expect(second.data[0].inputTokens == 35)
        #expect(second.data[0].cacheReadTokens == 650)
        #expect(second.data[0].outputTokens == 8)
        #expect(second.data[0].totalTokens == 43)

        var cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        for path in cache.files.keys where cache.files[path]?.sessionId == "sess-warm-cache-active-archive" {
            cache.files[path]?.codexRows = nil
        }
        CostUsageCacheIO.save(provider: .codex, cache: cache, cacheRoot: env.cacheRoot)

        let rowlessWarm = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(2),
            options: options)

        #expect(rowlessWarm.data.count == 1)
        #expect(rowlessWarm.data[0].inputTokens == 35)
        #expect(rowlessWarm.data[0].cacheReadTokens == 650)
        #expect(rowlessWarm.data[0].outputTokens == 8)
        #expect(rowlessWarm.data[0].totalTokens == 43)
    }

    @Test
    func `codex narrow warm overlap does not duplicate cached days outside scan window`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let olderDay = try env.makeLocalNoon(year: 2026, month: 6, day: 10)
        let day = try env.makeLocalNoon(year: 2026, month: 6, day: 28)
        let model = "openai/gpt-5.5"
        let sessionMeta: [String: Any] = [
            "type": "session_meta",
            "payload": ["session_id": "sess-narrow-warm-overlap"],
        ]
        let turnContext = self.codexTurnContext(timestamp: env.isoString(for: day), model: model)
        let sharedTurn: [String: Any] = [
            "type": "event_msg",
            "timestamp": env.isoString(for: day),
            "payload": ["type": "task_started", "turn_id": "turn-shared"],
        ]
        let sharedUsage = self.codexTokenCount(
            timestamp: env.isoString(for: day.addingTimeInterval(1)),
            model: model,
            last: (input: 10, cached: 0, output: 1))
        let olderTurn: [String: Any] = [
            "type": "event_msg",
            "timestamp": env.isoString(for: olderDay),
            "payload": ["type": "task_started", "turn_id": "turn-older"],
        ]
        let olderUsage = self.codexTokenCount(
            timestamp: env.isoString(for: olderDay.addingTimeInterval(1)),
            model: model,
            last: (input: 20, cached: 0, output: 2))
        let currentTurn: [String: Any] = [
            "type": "event_msg",
            "timestamp": env.isoString(for: day.addingTimeInterval(2)),
            "payload": ["type": "task_started", "turn_id": "turn-current"],
        ]
        let currentUsage = self.codexTokenCount(
            timestamp: env.isoString(for: day.addingTimeInterval(3)),
            model: model,
            last: (input: 5, cached: 0, output: 1))

        _ = try env.writeCodexSessionFile(
            day: day,
            filename: "active-narrow-warm-overlap.jsonl",
            contents: env.jsonl([sessionMeta, turnContext, sharedTurn, sharedUsage]))
        let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: day)
        let archiveRows = [
            sessionMeta,
            turnContext,
            sharedTurn,
            sharedUsage,
            olderTurn,
            olderUsage,
            currentTurn,
            currentUsage,
        ]
        let archiveURL = try env.writeCodexArchivedSessionFile(
            filename: "rollout-\(dayKey)T12-00-00-narrow-warm-overlap.jsonl",
            contents: env.jsonl(archiveRows))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0

        let wide = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: olderDay,
            until: day,
            now: day,
            options: options)
        #expect(wide.summary?.totalTokens == 39)

        let appendedTurnWithoutUsage: [String: Any] = [
            "type": "event_msg",
            "timestamp": env.isoString(for: day.addingTimeInterval(4)),
            "payload": ["type": "task_started", "turn_id": "turn-without-usage"],
        ]
        try env.jsonl(archiveRows + [appendedTurnWithoutUsage])
            .write(to: archiveURL, atomically: true, encoding: .utf8)

        let narrow = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(1),
            options: options)
        #expect(narrow.summary?.totalTokens == 17)

        let cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let archiveEntry = cache.files.first {
            URL(fileURLWithPath: $0.key).lastPathComponent == archiveURL.lastPathComponent
        }
        let archiveUsage = try #require(
            archiveEntry?.value,
            "cache keys: \(cache.files.keys.sorted())")
        let olderDayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: olderDay)
        let olderPacked = try #require(archiveUsage.days[olderDayKey]?.values.first)
        #expect(olderPacked == [20, 0, 2])
    }

    @Test
    func `codex narrow rowless rescan retains cached days outside scan window`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let olderDay = try env.makeLocalNoon(year: 2026, month: 6, day: 10)
        let day = try env.makeLocalNoon(year: 2026, month: 6, day: 28)
        let model = "openai/gpt-5.5"
        let sessionMeta: [String: Any] = [
            "type": "session_meta",
            "payload": ["session_id": "sess-narrow-rowless-rescan"],
        ]
        let currentContext = self.codexTurnContext(timestamp: env.isoString(for: day), model: model)
        let currentTurn: [String: Any] = [
            "type": "event_msg",
            "timestamp": env.isoString(for: day),
            "payload": ["type": "task_started", "turn_id": "turn-current"],
        ]
        let currentUsage = self.codexTokenCount(
            timestamp: env.isoString(for: day.addingTimeInterval(1)),
            model: model,
            last: (input: 10, cached: 0, output: 1))
        let olderContext = self.codexTurnContext(timestamp: env.isoString(for: olderDay), model: model)
        let olderTurn: [String: Any] = [
            "type": "event_msg",
            "timestamp": env.isoString(for: olderDay),
            "payload": ["type": "task_started", "turn_id": "turn-older"],
        ]
        let olderUsage = self.codexTokenCount(
            timestamp: env.isoString(for: olderDay.addingTimeInterval(1)),
            model: model,
            last: (input: 20, cached: 0, output: 2))

        _ = try env.writeCodexSessionFile(
            day: day,
            filename: "active-narrow-rowless-rescan.jsonl",
            contents: env.jsonl([sessionMeta, currentContext, currentTurn, currentUsage]))
        let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: day)
        let archiveURL = try env.writeCodexArchivedSessionFile(
            filename: "rollout-\(dayKey)T12-00-00-narrow-rowless-rescan.jsonl",
            contents: env.jsonl([
                sessionMeta,
                currentContext,
                currentTurn,
                currentUsage,
                olderContext,
                olderTurn,
                olderUsage,
            ]))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0

        let wide = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: olderDay,
            until: day,
            now: day,
            options: options)
        #expect(wide.summary?.totalTokens == 33)

        var cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let archivePath = try #require(cache.files.keys.first {
            URL(fileURLWithPath: $0).lastPathComponent == archiveURL.lastPathComponent
        })
        cache.files[archivePath]?.codexRows = nil
        CostUsageCacheIO.save(provider: .codex, cache: cache, cacheRoot: env.cacheRoot)

        let narrow = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(1),
            options: options)
        #expect(narrow.summary?.totalTokens == 11)

        cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let archiveUsage = try #require(cache.files[archivePath])
        let olderDayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: olderDay)
        let olderPacked = try #require(archiveUsage.days[olderDayKey]?.values.first)
        #expect(olderPacked == [20, 0, 2])
    }

    @Test
    func `codex daily report includes long lived sessions stored under older date partitions`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let fileDay = try env.makeLocalNoon(year: 2026, month: 2, day: 27)
        let reportDay = try env.makeLocalNoon(year: 2026, month: 3, day: 11)
        let model = "openai/gpt-5.2-codex"

        _ = try env.writeCodexSessionFile(
            day: fileDay,
            filename: "rollout-2026-02-27T11-29-28-cross-day.jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "payload": [
                        "id": "cross-day-session",
                    ],
                ],
                [
                    "type": "turn_context",
                    "timestamp": env.isoString(for: reportDay),
                    "payload": [
                        "model": model,
                    ],
                ],
                [
                    "type": "event_msg",
                    "timestamp": env.isoString(for: reportDay.addingTimeInterval(1)),
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "total_token_usage": [
                                "input_tokens": 100,
                                "cached_input_tokens": 20,
                                "output_tokens": 10,
                            ],
                            "model": model,
                        ],
                    ],
                ],
            ]))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0

        let report = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: reportDay,
            until: reportDay,
            now: reportDay,
            options: options)

        #expect(report.data.count == 1)
        #expect(report.data[0].inputTokens == 100)
        #expect(report.data[0].outputTokens == 10)
        #expect(report.data[0].totalTokens == 110)
    }

    @Test
    func `codex cold cache includes very old active date partition session`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let fileDay = try env.makeLocalNoon(year: 2026, month: 1, day: 1)
        let reportDay = try env.makeLocalNoon(year: 2026, month: 5, day: 18)
        let model = "openai/gpt-5.2-codex"

        let fileURL = try env.writeCodexSessionFile(
            day: fileDay,
            filename: "rollout-2026-01-01T11-29-28-active.jsonl",
            contents: env.jsonl([
                self.codexTurnContext(timestamp: env.isoString(for: fileDay), model: model),
                self.codexTokenCount(
                    timestamp: env.isoString(for: reportDay.addingTimeInterval(1)),
                    model: model,
                    last: (input: 70, cached: 20, output: 7)),
            ]))
        try FileManager.default.setAttributes([.modificationDate: reportDay], ofItemAtPath: fileURL.path)

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"))
        options.refreshMinIntervalSeconds = 0

        let report = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: reportDay,
            until: reportDay,
            now: reportDay,
            options: options)

        #expect(report.data.count == 1)
        #expect(report.data[0].totalTokens == 77)
    }

    @Test
    func `codex cold cache includes recent legacy file in mixed root`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let reportDay = try env.makeLocalNoon(year: 2026, month: 5, day: 18)
        let model = "openai/gpt-5.2-codex"
        _ = try env.writeCodexSessionFile(
            day: reportDay,
            filename: "partitioned.jsonl",
            contents: env.jsonl([
                self.codexTurnContext(timestamp: env.isoString(for: reportDay), model: model),
                self.codexTokenCount(
                    timestamp: env.isoString(for: reportDay.addingTimeInterval(1)),
                    model: model,
                    last: (input: 1, cached: 0, output: 1)),
            ]))

        let legacyDir = env.codexSessionsRoot.appendingPathComponent("project/subdir", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        let legacyURL = legacyDir.appendingPathComponent("legacy-active.jsonl")
        try env.jsonl([
            self.codexTurnContext(timestamp: env.isoString(for: reportDay), model: model),
            self.codexTokenCount(
                timestamp: env.isoString(for: reportDay.addingTimeInterval(2)),
                model: model,
                last: (input: 30, cached: 10, output: 3)),
        ]).write(to: legacyURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: reportDay], ofItemAtPath: legacyURL.path)

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"))
        options.refreshMinIntervalSeconds = 0

        let report = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: reportDay,
            until: reportDay,
            now: reportDay,
            options: options)

        #expect(report.data.count == 1)
        #expect(report.data[0].totalTokens == 35)
    }

    @Test
    func `codex forked child subtracts parent totals at fork timestamp`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let parentDay = try env.makeLocalNoon(year: 2026, month: 2, day: 27)
        let childDay = try env.makeLocalNoon(year: 2026, month: 3, day: 11)
        let parentTs0 = env.isoString(for: parentDay)
        let parentTs1 = env.isoString(for: parentDay.addingTimeInterval(1))
        let parentTs2 = env.isoString(for: parentDay.addingTimeInterval(2))
        let parentTs3 = env.isoString(for: parentDay.addingTimeInterval(3))
        let childForkTs = env.isoString(for: parentDay.addingTimeInterval(2.5))
        let childTs1 = env.isoString(for: childDay.addingTimeInterval(1))
        let childTs2 = env.isoString(for: childDay.addingTimeInterval(2))

        let model = "openai/gpt-5.2-codex"
        let parentSessionId = "sess-parent"
        let childSessionId = "sess-child"

        _ = try env.writeCodexSessionFile(
            day: parentDay,
            filename: "rollout-2026-02-27T11-29-28-\(parentSessionId).jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "payload": [
                        "id": parentSessionId,
                    ],
                ],
                [
                    "type": "turn_context",
                    "timestamp": parentTs0,
                    "payload": [
                        "model": model,
                    ],
                ],
                [
                    "type": "event_msg",
                    "timestamp": parentTs1,
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "total_token_usage": [
                                "input_tokens": 10,
                                "cached_input_tokens": 2,
                                "output_tokens": 1,
                            ],
                            "model": model,
                        ],
                    ],
                ],
                [
                    "type": "event_msg",
                    "timestamp": parentTs2,
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "total_token_usage": [
                                "input_tokens": 20,
                                "cached_input_tokens": 5,
                                "output_tokens": 2,
                            ],
                            "model": model,
                        ],
                    ],
                ],
                [
                    "type": "event_msg",
                    "timestamp": parentTs3,
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "total_token_usage": [
                                "input_tokens": 30,
                                "cached_input_tokens": 8,
                                "output_tokens": 3,
                            ],
                            "model": model,
                        ],
                    ],
                ],
            ]))

        _ = try env.writeCodexSessionFile(
            day: childDay,
            filename: "rollout-2026-03-11T11-30-27-\(childSessionId).jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "payload": [
                        "id": childSessionId,
                        "forked_from_id": parentSessionId,
                        "timestamp": childForkTs,
                    ],
                ],
                [
                    "type": "turn_context",
                    "timestamp": childDay.ISO8601Format(),
                    "payload": [
                        "model": model,
                    ],
                ],
                [
                    "type": "event_msg",
                    "timestamp": childTs1,
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "total_token_usage": [
                                "input_tokens": 20,
                                "cached_input_tokens": 5,
                                "output_tokens": 2,
                            ],
                            "model": model,
                        ],
                    ],
                ],
                [
                    "type": "event_msg",
                    "timestamp": childTs2,
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "total_token_usage": [
                                "input_tokens": 27,
                                "cached_input_tokens": 7,
                                "output_tokens": 4,
                            ],
                            "model": model,
                        ],
                    ],
                ],
            ]))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0
        options.forceRescan = true

        let report = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: childDay,
            until: childDay,
            now: childDay,
            options: options)

        let expectedCost = CostUsagePricing.codexCostUSD(
            model: "gpt-5.2-codex",
            inputTokens: 7,
            cachedInputTokens: 2,
            outputTokens: 2)

        #expect(report.data.count == 1)
        #expect(report.data[0].inputTokens == 7)
        #expect(report.data[0].outputTokens == 2)
        #expect(report.data[0].totalTokens == 9)
        #expect(abs((report.data[0].costUSD ?? 0) - (expectedCost ?? 0)) < 0.000001)
    }

    @Test
    func `codex forked child skips cumulative totals when parent session is missing`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let parentDay = try env.makeLocalNoon(year: 2026, month: 2, day: 27)
        let childDay = try env.makeLocalNoon(year: 2026, month: 3, day: 11)
        let model = "openai/gpt-5.2-codex"
        let missingParentSessionId = "sess-parent-deleted"
        let childSessionId = "sess-child-deleted-parent"
        let forkTs = env.isoString(for: parentDay.addingTimeInterval(2.5))

        _ = try env.writeCodexSessionFile(
            day: childDay,
            filename: "rollout-2026-03-11T11-30-27-\(childSessionId).jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "payload": [
                        "id": childSessionId,
                        "forked_from_id": missingParentSessionId,
                        "timestamp": forkTs,
                    ],
                ],
                self.codexTurnContext(timestamp: env.isoString(for: childDay), model: model),
                self.codexTokenCount(
                    timestamp: env.isoString(for: childDay.addingTimeInterval(1)),
                    model: model,
                    total: (input: 1_000_000, cached: 100_000, output: 10000)),
                self.codexTokenCount(
                    timestamp: env.isoString(for: childDay.addingTimeInterval(2)),
                    model: model,
                    total: (input: 1_000_120, cached: 100_010, output: 10020)),
                self.codexTokenCount(
                    timestamp: env.isoString(for: childDay.addingTimeInterval(3)),
                    model: model,
                    total: (input: 1_000_140, cached: 100_012, output: 10023),
                    last: (input: 20, cached: 2, output: 3)),
            ]))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0
        options.forceRescan = true

        let report = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: childDay,
            until: childDay,
            now: childDay,
            options: options)

        #expect(report.data.count == 1)
        #expect(report.data[0].inputTokens == 20)
        #expect(report.data[0].outputTokens == 3)
        #expect(report.data[0].totalTokens == 23)
    }

    @Test
    func `codex fork with total usage ignores replayed last snapshots`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 3, day: 11)
        let iso0 = env.isoString(for: day)
        let model = "openai/gpt-5.4"

        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "rollout-\(iso0)-child-session.jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "timestamp": iso0,
                    "payload": [
                        "id": "child-session",
                        "forked_from_id": "parent-session",
                        "timestamp": iso0,
                    ],
                ],
                self.codexTurnContext(timestamp: iso0, model: model),
                self.codexTokenCount(
                    timestamp: env.isoString(for: day.addingTimeInterval(1)),
                    model: model,
                    total: (input: 1000, cached: 900, output: 100),
                    last: (input: 1000, cached: 900, output: 100)),
                self.codexTokenCount(
                    timestamp: env.isoString(for: day.addingTimeInterval(2)),
                    model: model,
                    total: (input: 1100, cached: 920, output: 110),
                    last: (input: 40, cached: 20, output: 5)),
                self.codexTokenCount(
                    timestamp: env.isoString(for: day.addingTimeInterval(3)),
                    model: model,
                    total: (input: 1100, cached: 920, output: 110),
                    last: (input: 40, cached: 20, output: 5)),
            ]))
        let range = CostUsageScanner.CostUsageDayRange(since: day, until: day)
        let parsed = CostUsageScanner.parseCodexFile(
            fileURL: fileURL,
            range: range,
            inheritedTotalsResolver: { parentSessionId, forkedAt in
                #expect(parentSessionId == "parent-session")
                #expect(forkedAt == iso0)
                return .resolved(.init(input: 1000, cached: 900, output: 100))
            })

        let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: day)
        let normalized = CostUsagePricing.normalizeCodexModel(model)
        let packed = parsed.days[dayKey]?[normalized] ?? []
        #expect(packed.count >= 3)
        #expect(packed[0] == 100)
        #expect(packed[1] == 20)
        #expect(packed[2] == 10)
        #expect(parsed.rows.count == 1)
        #expect(parsed.rows.first?.input == 100)
        #expect(parsed.rows.first?.cached == 20)
        #expect(parsed.rows.first?.output == 10)
    }

    @Test
    func `codex fork skips last usage when parent baseline is unresolved`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 3, day: 11)
        let iso0 = env.isoString(for: day)
        let model = "openai/gpt-5.4"

        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "rollout-\(iso0)-missing-parent.jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "timestamp": iso0,
                    "payload": [
                        "id": "child-session",
                        "forked_from_id": "missing-parent",
                        "timestamp": iso0,
                    ],
                ],
                self.codexTurnContext(timestamp: iso0, model: model),
                self.codexTokenCount(
                    timestamp: env.isoString(for: day.addingTimeInterval(1)),
                    model: model,
                    total: (input: 1000, cached: 900, output: 100),
                    last: (input: 1000, cached: 900, output: 100)),
            ]))
        let range = CostUsageScanner.CostUsageDayRange(since: day, until: day)
        let parsed = CostUsageScanner.parseCodexFile(
            fileURL: fileURL,
            range: range,
            inheritedTotalsResolver: { parentSessionId, _ in
                #expect(parentSessionId == "missing-parent")
                return .unresolved
            })

        let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: day)
        let normalized = CostUsagePricing.normalizeCodexModel(model)
        #expect(parsed.days[dayKey]?[normalized] == nil)
        #expect(parsed.rows.isEmpty)
    }

    @Test
    func `codex unresolved fork ignores duplicated total and last replay after prefix`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 3, day: 11)
        let iso0 = env.isoString(for: day)
        let model = "openai/gpt-5.4"

        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "rollout-\(iso0)-missing-parent-replay.jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "timestamp": iso0,
                    "payload": [
                        "id": "child-session",
                        "forked_from_id": "missing-parent",
                        "timestamp": iso0,
                    ],
                ],
                self.codexTurnContext(timestamp: iso0, model: model),
                self.codexTokenCount(
                    timestamp: env.isoString(for: day.addingTimeInterval(1)),
                    model: model,
                    total: (input: 1000, cached: 900, output: 100)),
                self.codexTokenCount(
                    timestamp: env.isoString(for: day.addingTimeInterval(2)),
                    model: model,
                    total: (input: 1020, cached: 905, output: 105),
                    last: (input: 20, cached: 5, output: 5)),
                self.codexTokenCount(
                    timestamp: env.isoString(for: day.addingTimeInterval(3)),
                    model: model,
                    total: (input: 1020, cached: 905, output: 105),
                    last: (input: 20, cached: 5, output: 5)),
                self.codexTokenCount(
                    timestamp: env.isoString(for: day.addingTimeInterval(4)),
                    model: model,
                    total: (input: 1030, cached: 907, output: 108),
                    last: (input: 10, cached: 2, output: 3)),
            ]))
        let range = CostUsageScanner.CostUsageDayRange(since: day, until: day)
        let parsed = CostUsageScanner.parseCodexFile(
            fileURL: fileURL,
            range: range,
            inheritedTotalsResolver: { parentSessionId, _ in
                #expect(parentSessionId == "missing-parent")
                return .unresolved
            })

        let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: day)
        let normalized = CostUsagePricing.normalizeCodexModel(model)
        let packed = try #require(parsed.days[dayKey]?[normalized])
        #expect(packed[0] == 30)
        #expect(packed[1] == 7)
        #expect(packed[2] == 8)
        #expect(parsed.rows.count == 2)
    }

    @Test
    func `codex empty fork parent id still counts cumulative totals`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 3, day: 11)
        let model = "openai/gpt-5.2-codex"
        let sessionId = "sess-empty-fork-parent"

        _ = try env.writeCodexSessionFile(
            day: day,
            filename: "rollout-2026-03-11T11-30-27-\(sessionId).jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "payload": [
                        "id": sessionId,
                        "forked_from_id": "",
                        "timestamp": env.isoString(for: day),
                    ],
                ],
                self.codexTurnContext(timestamp: env.isoString(for: day.addingTimeInterval(1)), model: model),
                self.codexTokenCount(
                    timestamp: env.isoString(for: day.addingTimeInterval(2)),
                    model: model,
                    total: (input: 100, cached: 10, output: 5)),
                self.codexTokenCount(
                    timestamp: env.isoString(for: day.addingTimeInterval(3)),
                    model: model,
                    total: (input: 125, cached: 12, output: 8)),
            ]))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0
        options.forceRescan = true

        let report = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)

        #expect(report.data.count == 1)
        #expect(report.data[0].inputTokens == 125)
        #expect(report.data[0].outputTokens == 8)
        #expect(report.data[0].totalTokens == 133)
    }

    @Test
    func `codex forked child inherits counted parent totals when totals diverge`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let parentDay = try env.makeLocalNoon(year: 2026, month: 2, day: 27)
        let childDay = try env.makeLocalNoon(year: 2026, month: 3, day: 11)
        let model = "openai/gpt-5.2-codex"
        let parentSessionId = "sess-parent-diverged"
        let childSessionId = "sess-child-diverged"
        let forkTs = env.isoString(for: parentDay.addingTimeInterval(2.5))

        _ = try env.writeCodexSessionFile(
            day: parentDay,
            filename: "rollout-2026-02-27T11-29-28-\(parentSessionId).jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "payload": [
                        "id": parentSessionId,
                    ],
                ],
                self.codexTurnContext(timestamp: env.isoString(for: parentDay), model: model),
                self.codexTokenCount(
                    timestamp: env.isoString(for: parentDay.addingTimeInterval(1)),
                    model: model,
                    total: (input: 100, cached: 0, output: 0),
                    last: (input: 100, cached: 0, output: 0)),
                self.codexTokenCount(
                    timestamp: env.isoString(for: parentDay.addingTimeInterval(2)),
                    model: model,
                    total: (input: 1000, cached: 0, output: 0),
                    last: (input: 40, cached: 0, output: 0)),
            ]))

        _ = try env.writeCodexSessionFile(
            day: childDay,
            filename: "rollout-2026-03-11T11-30-27-\(childSessionId).jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "payload": [
                        "id": childSessionId,
                        "forked_from_id": parentSessionId,
                        "timestamp": forkTs,
                    ],
                ],
                self.codexTurnContext(timestamp: env.isoString(for: childDay), model: model),
                self.codexTokenCount(
                    timestamp: env.isoString(for: childDay.addingTimeInterval(1)),
                    model: model,
                    total: (input: 140, cached: 0, output: 0)),
                self.codexTokenCount(
                    timestamp: env.isoString(for: childDay.addingTimeInterval(2)),
                    model: model,
                    total: (input: 170, cached: 0, output: 0)),
            ]))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0
        options.forceRescan = true

        let report = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: childDay,
            until: childDay,
            now: childDay,
            options: options)

        #expect(report.data.count == 1)
        #expect(report.data[0].inputTokens == 30)
        #expect(report.data[0].totalTokens == 30)
    }

    @Test
    func `codex forked child subtracts inherited replay from last token usage`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let parentDay = try env.makeLocalNoon(year: 2026, month: 2, day: 27)
        let childDay = try env.makeLocalNoon(year: 2026, month: 3, day: 11)
        let parentTs0 = env.isoString(for: parentDay)
        let parentTs1 = env.isoString(for: parentDay.addingTimeInterval(1))
        let parentTs2 = env.isoString(for: parentDay.addingTimeInterval(2))
        let childTs1 = env.isoString(for: childDay.addingTimeInterval(1))
        let childTs2 = env.isoString(for: childDay.addingTimeInterval(2))
        let childTs3 = env.isoString(for: childDay.addingTimeInterval(3))

        let model = "openai/gpt-5.2-codex"
        let parentSessionId = "sess-parent-last"
        let childSessionId = "sess-child-last"
        let forkTs = env.isoString(for: parentDay.addingTimeInterval(2.5))

        _ = try env.writeCodexSessionFile(
            day: parentDay,
            filename: "rollout-2026-02-27T11-29-28-\(parentSessionId).jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "payload": [
                        "id": parentSessionId,
                    ],
                ],
                [
                    "type": "turn_context",
                    "timestamp": parentTs0,
                    "payload": [
                        "model": model,
                    ],
                ],
                [
                    "type": "event_msg",
                    "timestamp": parentTs1,
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "total_token_usage": [
                                "input_tokens": 10,
                                "cached_input_tokens": 2,
                                "output_tokens": 1,
                            ],
                            "model": model,
                        ],
                    ],
                ],
                [
                    "type": "event_msg",
                    "timestamp": parentTs2,
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "total_token_usage": [
                                "input_tokens": 20,
                                "cached_input_tokens": 5,
                                "output_tokens": 2,
                            ],
                            "model": model,
                        ],
                    ],
                ],
            ]))

        _ = try env.writeCodexSessionFile(
            day: childDay,
            filename: "rollout-2026-03-11T11-30-27-\(childSessionId).jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "payload": [
                        "id": childSessionId,
                        "forked_from_id": parentSessionId,
                        "timestamp": forkTs,
                    ],
                ],
                [
                    "type": "turn_context",
                    "timestamp": childDay.ISO8601Format(),
                    "payload": [
                        "model": model,
                    ],
                ],
                [
                    "type": "event_msg",
                    "timestamp": childTs1,
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "last_token_usage": [
                                "input_tokens": 10,
                                "cached_input_tokens": 2,
                                "output_tokens": 1,
                            ],
                            "model": model,
                        ],
                    ],
                ],
                [
                    "type": "event_msg",
                    "timestamp": childTs2,
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "last_token_usage": [
                                "input_tokens": 10,
                                "cached_input_tokens": 3,
                                "output_tokens": 1,
                            ],
                            "model": model,
                        ],
                    ],
                ],
                [
                    "type": "event_msg",
                    "timestamp": childTs3,
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "last_token_usage": [
                                "input_tokens": 7,
                                "cached_input_tokens": 2,
                                "output_tokens": 2,
                            ],
                            "model": model,
                        ],
                    ],
                ],
            ]))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0
        options.forceRescan = true

        let report = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: childDay,
            until: childDay,
            now: childDay,
            options: options)

        let expectedCost = CostUsagePricing.codexCostUSD(
            model: model,
            inputTokens: 7,
            cachedInputTokens: 2,
            outputTokens: 2)

        #expect(report.data.count == 1)
        #expect(report.data[0].inputTokens == 7)
        #expect(report.data[0].outputTokens == 2)
        #expect(report.data[0].totalTokens == 9)
        #expect(abs((report.data[0].costUSD ?? 0) - (expectedCost ?? 0)) < 0.000001)
    }

    @Test
    // swiftlint:disable:next function_body_length
    func `codex forked child ignores replayed parent prefix sequence`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let parentDay = try env.makeLocalNoon(year: 2026, month: 2, day: 27)
        let childDay = try env.makeLocalNoon(year: 2026, month: 3, day: 11)
        let model = "openai/gpt-5.2-codex"
        let parentSessionId = "sess-parent-prefix"
        let childSessionId = "sess-child-prefix"
        let forkTs = env.isoString(for: parentDay.addingTimeInterval(5))

        let parentEvents: [[String: Any]] = [
            [
                "type": "session_meta",
                "payload": [
                    "id": parentSessionId,
                ],
            ],
            [
                "type": "turn_context",
                "timestamp": env.isoString(for: parentDay),
                "payload": [
                    "model": model,
                ],
            ],
            [
                "type": "event_msg",
                "timestamp": env.isoString(for: parentDay.addingTimeInterval(1)),
                "payload": [
                    "type": "token_count",
                    "info": [
                        "total_token_usage": [
                            "input_tokens": 10,
                            "cached_input_tokens": 2,
                            "output_tokens": 1,
                        ],
                        "model": model,
                    ],
                ],
            ],
            [
                "type": "event_msg",
                "timestamp": env.isoString(for: parentDay.addingTimeInterval(2)),
                "payload": [
                    "type": "token_count",
                    "info": [
                        "total_token_usage": [
                            "input_tokens": 20,
                            "cached_input_tokens": 5,
                            "output_tokens": 2,
                        ],
                        "model": model,
                    ],
                ],
            ],
            [
                "type": "event_msg",
                "timestamp": env.isoString(for: parentDay.addingTimeInterval(3)),
                "payload": [
                    "type": "token_count",
                    "info": [
                        "total_token_usage": [
                            "input_tokens": 30,
                            "cached_input_tokens": 8,
                            "output_tokens": 3,
                        ],
                        "model": model,
                    ],
                ],
            ],
        ]
        _ = try env.writeCodexSessionFile(
            day: parentDay,
            filename: "rollout-2026-02-27T11-29-28-\(parentSessionId).jsonl",
            contents: env.jsonl(parentEvents))

        let childEvents: [[String: Any]] = [
            [
                "type": "session_meta",
                "payload": [
                    "id": childSessionId,
                    "forked_from_id": parentSessionId,
                    "timestamp": forkTs,
                ],
            ],
            [
                "type": "turn_context",
                "timestamp": env.isoString(for: childDay),
                "payload": [
                    "model": model,
                ],
            ],
            [
                "type": "event_msg",
                "timestamp": env.isoString(for: childDay.addingTimeInterval(1)),
                "payload": [
                    "type": "token_count",
                    "info": [
                        "total_token_usage": [
                            "input_tokens": 10,
                            "cached_input_tokens": 2,
                            "output_tokens": 1,
                        ],
                        "model": model,
                    ],
                ],
            ],
            [
                "type": "event_msg",
                "timestamp": env.isoString(for: childDay.addingTimeInterval(2)),
                "payload": [
                    "type": "token_count",
                    "info": [
                        "total_token_usage": [
                            "input_tokens": 20,
                            "cached_input_tokens": 5,
                            "output_tokens": 2,
                        ],
                        "model": model,
                    ],
                ],
            ],
            [
                "type": "event_msg",
                "timestamp": env.isoString(for: childDay.addingTimeInterval(3)),
                "payload": [
                    "type": "token_count",
                    "info": [
                        "total_token_usage": [
                            "input_tokens": 30,
                            "cached_input_tokens": 8,
                            "output_tokens": 3,
                        ],
                        "model": model,
                    ],
                ],
            ],
            [
                "type": "event_msg",
                "timestamp": env.isoString(for: childDay.addingTimeInterval(4)),
                "payload": [
                    "type": "token_count",
                    "info": [
                        "total_token_usage": [
                            "input_tokens": 30,
                            "cached_input_tokens": 8,
                            "output_tokens": 3,
                        ],
                        "model": model,
                    ],
                ],
            ],
            [
                "type": "event_msg",
                "timestamp": env.isoString(for: childDay.addingTimeInterval(5)),
                "payload": [
                    "type": "token_count",
                    "info": [
                        "total_token_usage": [
                            "input_tokens": 35,
                            "cached_input_tokens": 9,
                            "output_tokens": 4,
                        ],
                        "model": model,
                    ],
                ],
            ],
            [
                "type": "event_msg",
                "timestamp": env.isoString(for: childDay.addingTimeInterval(6)),
                "payload": [
                    "type": "token_count",
                    "info": [
                        "total_token_usage": [
                            "input_tokens": 42,
                            "cached_input_tokens": 11,
                            "output_tokens": 5,
                        ],
                        "model": model,
                    ],
                ],
            ],
        ]
        _ = try env.writeCodexSessionFile(
            day: childDay,
            filename: "rollout-2026-03-11T11-30-27-\(childSessionId).jsonl",
            contents: env.jsonl(childEvents))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0
        options.forceRescan = true

        let report = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: childDay,
            until: childDay,
            now: childDay,
            options: options)

        let expectedCost = CostUsagePricing.codexCostUSD(
            model: "gpt-5.2-codex",
            inputTokens: 12,
            cachedInputTokens: 3,
            outputTokens: 2)

        #expect(report.data.count == 1)
        #expect(report.data[0].inputTokens == 12)
        #expect(report.data[0].outputTokens == 2)
        #expect(report.data[0].totalTokens == 14)
        #expect(abs((report.data[0].costUSD ?? 0) - (expectedCost ?? 0)) < 0.000001)
    }

    @Test
    // swiftlint:disable:next function_body_length
    func `codex forked child subtracts inherited replay even when session meta appears late`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let parentDay = try env.makeLocalNoon(year: 2026, month: 2, day: 27)
        let childDay = try env.makeLocalNoon(year: 2026, month: 3, day: 11)
        let model = "openai/gpt-5.2-codex"
        let parentSessionId = "sess-parent-late-meta"
        let childSessionId = "sess-child-late-meta"
        let forkTs = env.isoString(for: parentDay.addingTimeInterval(5))

        let parentEvents: [[String: Any]] = [
            [
                "type": "session_meta",
                "payload": [
                    "id": parentSessionId,
                ],
            ],
            [
                "type": "turn_context",
                "timestamp": env.isoString(for: parentDay),
                "payload": [
                    "model": model,
                ],
            ],
            [
                "type": "event_msg",
                "timestamp": env.isoString(for: parentDay.addingTimeInterval(1)),
                "payload": [
                    "type": "token_count",
                    "info": [
                        "total_token_usage": [
                            "input_tokens": 10,
                            "cached_input_tokens": 2,
                            "output_tokens": 1,
                        ],
                        "model": model,
                    ],
                ],
            ],
            [
                "type": "event_msg",
                "timestamp": env.isoString(for: parentDay.addingTimeInterval(2)),
                "payload": [
                    "type": "token_count",
                    "info": [
                        "total_token_usage": [
                            "input_tokens": 20,
                            "cached_input_tokens": 5,
                            "output_tokens": 2,
                        ],
                        "model": model,
                    ],
                ],
            ],
            [
                "type": "event_msg",
                "timestamp": env.isoString(for: parentDay.addingTimeInterval(3)),
                "payload": [
                    "type": "token_count",
                    "info": [
                        "total_token_usage": [
                            "input_tokens": 30,
                            "cached_input_tokens": 8,
                            "output_tokens": 3,
                        ],
                        "model": model,
                    ],
                ],
            ],
        ]
        _ = try env.writeCodexSessionFile(
            day: parentDay,
            filename: "rollout-2026-02-27T11-29-28-\(parentSessionId).jsonl",
            contents: env.jsonl(parentEvents))

        let childEvents: [[String: Any]] = [
            [
                "type": "turn_context",
                "timestamp": env.isoString(for: childDay),
                "payload": [
                    "model": model,
                ],
            ],
            [
                "type": "event_msg",
                "timestamp": env.isoString(for: childDay.addingTimeInterval(1)),
                "payload": [
                    "type": "token_count",
                    "info": [
                        "total_token_usage": [
                            "input_tokens": 10,
                            "cached_input_tokens": 2,
                            "output_tokens": 1,
                        ],
                        "model": model,
                    ],
                ],
            ],
            [
                "type": "event_msg",
                "timestamp": env.isoString(for: childDay.addingTimeInterval(2)),
                "payload": [
                    "type": "token_count",
                    "info": [
                        "total_token_usage": [
                            "input_tokens": 20,
                            "cached_input_tokens": 5,
                            "output_tokens": 2,
                        ],
                        "model": model,
                    ],
                ],
            ],
            [
                "type": "event_msg",
                "timestamp": env.isoString(for: childDay.addingTimeInterval(3)),
                "payload": [
                    "type": "token_count",
                    "info": [
                        "total_token_usage": [
                            "input_tokens": 30,
                            "cached_input_tokens": 8,
                            "output_tokens": 3,
                        ],
                        "model": model,
                    ],
                ],
            ],
            [
                "type": "session_meta",
                "payload": [
                    "id": childSessionId,
                    "forked_from_id": parentSessionId,
                    "timestamp": forkTs,
                ],
            ],
            [
                "type": "event_msg",
                "timestamp": env.isoString(for: childDay.addingTimeInterval(4)),
                "payload": [
                    "type": "token_count",
                    "info": [
                        "total_token_usage": [
                            "input_tokens": 35,
                            "cached_input_tokens": 9,
                            "output_tokens": 4,
                        ],
                        "model": model,
                    ],
                ],
            ],
            [
                "type": "event_msg",
                "timestamp": env.isoString(for: childDay.addingTimeInterval(5)),
                "payload": [
                    "type": "token_count",
                    "info": [
                        "total_token_usage": [
                            "input_tokens": 42,
                            "cached_input_tokens": 11,
                            "output_tokens": 5,
                        ],
                        "model": model,
                    ],
                ],
            ],
        ]
        _ = try env.writeCodexSessionFile(
            day: childDay,
            filename: "rollout-2026-03-11T11-30-27-\(childSessionId).jsonl",
            contents: env.jsonl(childEvents))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0
        options.forceRescan = true

        let report = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: childDay,
            until: childDay,
            now: childDay,
            options: options)

        let expectedCost = CostUsagePricing.codexCostUSD(
            model: "gpt-5.2-codex",
            inputTokens: 12,
            cachedInputTokens: 3,
            outputTokens: 2)

        #expect(report.data.count == 1)
        #expect(report.data[0].inputTokens == 12)
        #expect(report.data[0].outputTokens == 2)
        #expect(report.data[0].totalTokens == 14)
        #expect(abs((report.data[0].costUSD ?? 0) - (expectedCost ?? 0)) < 0.000001)
    }

    @Test
    func `codex forked child resolves parent when parent session file is a symlink`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let parentDay = try env.makeLocalNoon(year: 2026, month: 2, day: 27)
        let childDay = try env.makeLocalNoon(year: 2026, month: 3, day: 11)
        let model = "openai/gpt-5.2-codex"
        let parentSessionId = "sess-parent-symlink"
        let childSessionId = "sess-child-symlink"
        let forkTs = env.isoString(for: parentDay.addingTimeInterval(3))

        let parentContents = try env.jsonl([
            [
                "type": "session_meta",
                "payload": [
                    "id": parentSessionId,
                ],
            ],
            [
                "type": "turn_context",
                "timestamp": env.isoString(for: parentDay),
                "payload": [
                    "model": model,
                ],
            ],
            [
                "type": "event_msg",
                "timestamp": env.isoString(for: parentDay.addingTimeInterval(1)),
                "payload": [
                    "type": "token_count",
                    "info": [
                        "total_token_usage": [
                            "input_tokens": 10,
                            "cached_input_tokens": 2,
                            "output_tokens": 1,
                        ],
                        "model": model,
                    ],
                ],
            ],
            [
                "type": "event_msg",
                "timestamp": env.isoString(for: parentDay.addingTimeInterval(2)),
                "payload": [
                    "type": "token_count",
                    "info": [
                        "total_token_usage": [
                            "input_tokens": 20,
                            "cached_input_tokens": 5,
                            "output_tokens": 2,
                        ],
                        "model": model,
                    ],
                ],
            ],
        ])

        let parentTarget = env.root.appendingPathComponent("parent-target.jsonl", isDirectory: false)
        try parentContents.write(to: parentTarget, atomically: true, encoding: .utf8)

        let comps = Calendar.current.dateComponents([.year, .month, .day], from: parentDay)
        let parentDir = env.codexSessionsRoot
            .appendingPathComponent(String(format: "%04d", comps.year ?? 1970), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", comps.month ?? 1), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", comps.day ?? 1), isDirectory: true)
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        let parentLink = parentDir.appendingPathComponent(
            "rollout-2026-02-27T11-29-28-\(parentSessionId).jsonl",
            isDirectory: false)
        try FileManager.default.createSymbolicLink(at: parentLink, withDestinationURL: parentTarget)

        _ = try env.writeCodexSessionFile(
            day: childDay,
            filename: "rollout-2026-03-11T11-30-27-\(childSessionId).jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "payload": [
                        "id": childSessionId,
                        "forked_from_id": parentSessionId,
                        "timestamp": forkTs,
                    ],
                ],
                [
                    "type": "turn_context",
                    "timestamp": env.isoString(for: childDay),
                    "payload": [
                        "model": model,
                    ],
                ],
                [
                    "type": "event_msg",
                    "timestamp": env.isoString(for: childDay.addingTimeInterval(1)),
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "total_token_usage": [
                                "input_tokens": 20,
                                "cached_input_tokens": 5,
                                "output_tokens": 2,
                            ],
                            "model": model,
                        ],
                    ],
                ],
                [
                    "type": "event_msg",
                    "timestamp": env.isoString(for: childDay.addingTimeInterval(2)),
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "total_token_usage": [
                                "input_tokens": 27,
                                "cached_input_tokens": 7,
                                "output_tokens": 4,
                            ],
                            "model": model,
                        ],
                    ],
                ],
            ]))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0
        options.forceRescan = true

        let report = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: childDay,
            until: childDay,
            now: childDay,
            options: options)

        let expectedCost = CostUsagePricing.codexCostUSD(
            model: "gpt-5.2-codex",
            inputTokens: 7,
            cachedInputTokens: 2,
            outputTokens: 2)

        #expect(report.data.count == 1)
        #expect(report.data[0].inputTokens == 7)
        #expect(report.data[0].outputTokens == 2)
        #expect(report.data[0].totalTokens == 9)
        #expect(abs((report.data[0].costUSD ?? 0) - (expectedCost ?? 0)) < 0.000001)
    }

    @Test
    // swiftlint:disable:next function_body_length
    func `codex forked child resolves parent by exact session meta id`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let parentDay = try env.makeLocalNoon(year: 2026, month: 2, day: 27)
        let childDay = try env.makeLocalNoon(year: 2026, month: 3, day: 11)
        let model = "openai/gpt-5.2-codex"
        let wantedParentSessionId = "sess-parent-exact"
        let wrongParentSessionId = "sess-parent-exact-extra"
        let childSessionId = "sess-child-exact"
        let forkTs = env.isoString(for: parentDay.addingTimeInterval(3))

        _ = try env.writeCodexSessionFile(
            day: parentDay,
            filename: "rollout-2026-02-27T11-29-28-\(wrongParentSessionId).jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "payload": [
                        "id": wrongParentSessionId,
                    ],
                ],
                [
                    "type": "turn_context",
                    "timestamp": env.isoString(for: parentDay),
                    "payload": [
                        "model": model,
                    ],
                ],
                [
                    "type": "event_msg",
                    "timestamp": env.isoString(for: parentDay.addingTimeInterval(1)),
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "total_token_usage": [
                                "input_tokens": 1000,
                                "cached_input_tokens": 100,
                                "output_tokens": 100,
                            ],
                            "model": model,
                        ],
                    ],
                ],
            ]))

        _ = try env.writeCodexSessionFile(
            day: parentDay,
            filename: "rollout-2026-02-27T11-29-29-\(wantedParentSessionId).jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "payload": [
                        "id": wantedParentSessionId,
                    ],
                ],
                [
                    "type": "turn_context",
                    "timestamp": env.isoString(for: parentDay),
                    "payload": [
                        "model": model,
                    ],
                ],
                [
                    "type": "event_msg",
                    "timestamp": env.isoString(for: parentDay.addingTimeInterval(1)),
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "total_token_usage": [
                                "input_tokens": 20,
                                "cached_input_tokens": 5,
                                "output_tokens": 2,
                            ],
                            "model": model,
                        ],
                    ],
                ],
                [
                    "type": "event_msg",
                    "timestamp": env.isoString(for: parentDay.addingTimeInterval(2)),
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "total_token_usage": [
                                "input_tokens": 30,
                                "cached_input_tokens": 8,
                                "output_tokens": 3,
                            ],
                            "model": model,
                        ],
                    ],
                ],
            ]))

        _ = try env.writeCodexSessionFile(
            day: childDay,
            filename: "rollout-2026-03-11T11-30-27-\(childSessionId).jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "payload": [
                        "id": childSessionId,
                        "forked_from_id": wantedParentSessionId,
                        "timestamp": forkTs,
                    ],
                ],
                [
                    "type": "turn_context",
                    "timestamp": env.isoString(for: childDay),
                    "payload": [
                        "model": model,
                    ],
                ],
                [
                    "type": "event_msg",
                    "timestamp": env.isoString(for: childDay.addingTimeInterval(1)),
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "total_token_usage": [
                                "input_tokens": 35,
                                "cached_input_tokens": 9,
                                "output_tokens": 4,
                            ],
                            "model": model,
                        ],
                    ],
                ],
                [
                    "type": "event_msg",
                    "timestamp": env.isoString(for: childDay.addingTimeInterval(2)),
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "total_token_usage": [
                                "input_tokens": 42,
                                "cached_input_tokens": 11,
                                "output_tokens": 5,
                            ],
                            "model": model,
                        ],
                    ],
                ],
            ]))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0
        options.forceRescan = true

        let report = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: childDay,
            until: childDay,
            now: childDay,
            options: options)

        let expectedCost = CostUsagePricing.codexCostUSD(
            model: "gpt-5.2-codex",
            inputTokens: 12,
            cachedInputTokens: 3,
            outputTokens: 2)

        #expect(report.data.count == 1)
        #expect(report.data[0].inputTokens == 12)
        #expect(report.data[0].outputTokens == 2)
        #expect(report.data[0].totalTokens == 14)
        #expect(abs((report.data[0].costUSD ?? 0) - (expectedCost ?? 0)) < 0.000001)
    }

    @Test
    func `codex forked child compares parent snapshots by parsed timestamp`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let parentDay = try env.makeLocalNoon(year: 2026, month: 2, day: 27)
        let childDay = try env.makeLocalNoon(year: 2026, month: 3, day: 11)
        let model = "openai/gpt-5.2-codex"
        let parentSessionId = "sess-parent-timestamp"
        let childSessionId = "sess-child-timestamp"

        _ = try env.writeCodexSessionFile(
            day: parentDay,
            filename: "rollout-2026-02-27T11-29-28-\(parentSessionId).jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "payload": [
                        "id": parentSessionId,
                    ],
                ],
                [
                    "type": "turn_context",
                    "timestamp": "2026-02-27T23:59:58Z",
                    "payload": [
                        "model": model,
                    ],
                ],
                [
                    "type": "event_msg",
                    "timestamp": "2026-02-27T23:59:59Z",
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "total_token_usage": [
                                "input_tokens": 20,
                                "cached_input_tokens": 5,
                                "output_tokens": 2,
                            ],
                            "model": model,
                        ],
                    ],
                ],
                [
                    "type": "event_msg",
                    "timestamp": "2026-02-28T00:00:01Z",
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "total_token_usage": [
                                "input_tokens": 100,
                                "cached_input_tokens": 20,
                                "output_tokens": 10,
                            ],
                            "model": model,
                        ],
                    ],
                ],
            ]))

        _ = try env.writeCodexSessionFile(
            day: childDay,
            filename: "rollout-2026-03-11T11-30-27-\(childSessionId).jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "payload": [
                        "id": childSessionId,
                        "forked_from_id": parentSessionId,
                        "timestamp": "2026-02-28T08:00:00+08:00",
                    ],
                ],
                [
                    "type": "turn_context",
                    "timestamp": env.isoString(for: childDay),
                    "payload": [
                        "model": model,
                    ],
                ],
                [
                    "type": "event_msg",
                    "timestamp": env.isoString(for: childDay.addingTimeInterval(1)),
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "total_token_usage": [
                                "input_tokens": 25,
                                "cached_input_tokens": 7,
                                "output_tokens": 4,
                            ],
                            "model": model,
                        ],
                    ],
                ],
                [
                    "type": "event_msg",
                    "timestamp": env.isoString(for: childDay.addingTimeInterval(2)),
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "total_token_usage": [
                                "input_tokens": 30,
                                "cached_input_tokens": 10,
                                "output_tokens": 6,
                            ],
                            "model": model,
                        ],
                    ],
                ],
            ]))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0
        options.forceRescan = true

        let report = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: childDay,
            until: childDay,
            now: childDay,
            options: options)

        let expectedCost = CostUsagePricing.codexCostUSD(
            model: model,
            inputTokens: 10,
            cachedInputTokens: 5,
            outputTokens: 4)

        #expect(report.data.count == 1)
        #expect(report.data[0].inputTokens == 10)
        #expect(report.data[0].outputTokens == 4)
        #expect(report.data[0].totalTokens == 14)
        #expect(abs((report.data[0].costUSD ?? 0) - (expectedCost ?? 0)) < 0.000001)
    }

    @Test
    func `codex first refresh keeps unrelated archived sessions out of cache`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let reportDay = try env.makeLocalNoon(year: 2026, month: 3, day: 11)
        let archivedDay = try env.makeLocalNoon(year: 2025, month: 1, day: 1)
        let model = "openai/gpt-5.2-codex"

        _ = try env.writeCodexSessionFile(
            day: reportDay,
            filename: "rollout-2026-03-11T11-30-27-session-recent.jsonl",
            contents: env.jsonl([
                [
                    "type": "turn_context",
                    "timestamp": env.isoString(for: reportDay),
                    "payload": [
                        "model": model,
                    ],
                ],
                [
                    "type": "event_msg",
                    "timestamp": env.isoString(for: reportDay.addingTimeInterval(1)),
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "last_token_usage": [
                                "input_tokens": 7,
                                "cached_input_tokens": 2,
                                "output_tokens": 2,
                            ],
                            "model": model,
                        ],
                    ],
                ],
            ]))

        let archivedURL = try env.writeCodexArchivedSessionFile(
            filename: "rollout-2025-01-01T12-00-00-session-archived.jsonl",
            contents: env.jsonl([
                [
                    "type": "turn_context",
                    "timestamp": env.isoString(for: archivedDay),
                    "payload": [
                        "model": model,
                    ],
                ],
                [
                    "type": "event_msg",
                    "timestamp": env.isoString(for: archivedDay.addingTimeInterval(1)),
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "last_token_usage": [
                                "input_tokens": 100,
                                "cached_input_tokens": 10,
                                "output_tokens": 5,
                            ],
                            "model": model,
                        ],
                    ],
                ],
            ]))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0

        let report = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: reportDay,
            until: reportDay,
            now: reportDay,
            options: options)

        let cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)

        #expect(report.data.count == 1)
        #expect(cache.files.keys.contains { $0.hasSuffix("session-recent.jsonl") })
        #expect(!cache.files.keys.contains(archivedURL.path))
    }

    @Test
    func `codex root switch reloads long lived sessions from older partitions`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        func writeSessionFile(
            root: URL,
            day: Date,
            filename: String,
            contents: String) throws -> URL
        {
            let comps = Calendar.current.dateComponents([.year, .month, .day], from: day)
            let dir = root
                .appendingPathComponent(String(format: "%04d", comps.year ?? 1970), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", comps.month ?? 1), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", comps.day ?? 1), isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(filename, isDirectory: false)
            try contents.write(to: url, atomically: true, encoding: .utf8)
            return url
        }

        let fileDay = try env.makeLocalNoon(year: 2026, month: 2, day: 27)
        let reportDay = try env.makeLocalNoon(year: 2026, month: 3, day: 11)
        let model = "openai/gpt-5.2-codex"
        let otherSessionsRoot = env.root
            .appendingPathComponent("other-codex-home", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: otherSessionsRoot, withIntermediateDirectories: true)

        let oldRootURL = try env.writeCodexSessionFile(
            day: reportDay,
            filename: "rollout-2026-03-11T11-30-27-session-old-root.jsonl",
            contents: env.jsonl([
                [
                    "type": "turn_context",
                    "timestamp": env.isoString(for: reportDay),
                    "payload": [
                        "model": model,
                    ],
                ],
                [
                    "type": "event_msg",
                    "timestamp": env.isoString(for: reportDay.addingTimeInterval(1)),
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "last_token_usage": [
                                "input_tokens": 7,
                                "cached_input_tokens": 2,
                                "output_tokens": 2,
                            ],
                            "model": model,
                        ],
                    ],
                ],
            ]))

        _ = try writeSessionFile(
            root: otherSessionsRoot,
            day: fileDay,
            filename: "rollout-2026-02-27T11-30-27-session-new-root.jsonl",
            contents: env.jsonl([
                [
                    "type": "turn_context",
                    "timestamp": env.isoString(for: reportDay),
                    "payload": [
                        "model": model,
                    ],
                ],
                [
                    "type": "event_msg",
                    "timestamp": env.isoString(for: reportDay.addingTimeInterval(1)),
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "last_token_usage": [
                                "input_tokens": 10,
                                "cached_input_tokens": 5,
                                "output_tokens": 4,
                            ],
                            "model": model,
                        ],
                    ],
                ],
            ]))

        var firstOptions = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot)
        firstOptions.refreshMinIntervalSeconds = 0

        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: reportDay,
            until: reportDay,
            now: reportDay,
            options: firstOptions)

        var secondOptions = CostUsageScanner.Options(
            codexSessionsRoot: otherSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot)
        secondOptions.refreshMinIntervalSeconds = 0

        let secondReport = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: reportDay,
            until: reportDay,
            now: reportDay,
            options: secondOptions)

        let cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)

        #expect(secondReport.data.count == 1)
        #expect(secondReport.data[0].inputTokens == 10)
        #expect(secondReport.data[0].outputTokens == 4)
        #expect(secondReport.data[0].totalTokens == 14)
        #expect(!cache.files.keys.contains(oldRootURL.path))
    }

    @Test
    func `claude daily report parses usage and caches`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2025, month: 12, day: 20)
        let iso0 = env.isoString(for: day)

        let assistant: [String: Any] = [
            "type": "assistant",
            "timestamp": iso0,
            "message": [
                "model": "claude-sonnet-4-20250514",
                "usage": [
                    "input_tokens": 200,
                    "cache_creation_input_tokens": 50,
                    "cache_read_input_tokens": 25,
                    "output_tokens": 80,
                ],
            ],
        ]
        _ = try env.writeClaudeProjectFile(
            relativePath: "project-a/session-a.jsonl",
            contents: env.jsonl([assistant]))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: nil,
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0

        let report = CostUsageScanner.loadDailyReport(
            provider: .claude,
            since: day,
            until: day,
            now: day,
            options: options)
        #expect(report.data.count == 1)
        #expect(report.data[0].modelsUsed == ["claude-sonnet-4-20250514"])
        #expect(report.data[0].inputTokens == 200)
        #expect(report.data[0].cacheCreationTokens == 50)
        #expect(report.data[0].cacheReadTokens == 25)
        #expect(report.data[0].outputTokens == 80)
        #expect(report.data[0].totalTokens == 355)
        #expect(report.data[0].modelBreakdowns == [
            CostUsageDailyReport.ModelBreakdown(
                modelName: "claude-sonnet-4-20250514",
                costUSD: report.data[0].costUSD,
                totalTokens: 355),
        ])
        #expect((report.data[0].costUSD ?? 0) > 0)
    }

    @Test
    func `codex daily report preserves full sorted model breakdowns`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2025, month: 12, day: 23)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))
        let iso2 = env.isoString(for: day.addingTimeInterval(2))
        let iso3 = env.isoString(for: day.addingTimeInterval(3))
        let iso4 = env.isoString(for: day.addingTimeInterval(4))
        let iso5 = env.isoString(for: day.addingTimeInterval(5))
        let iso6 = env.isoString(for: day.addingTimeInterval(6))
        let iso7 = env.isoString(for: day.addingTimeInterval(7))

        let events: [[String: Any]] = [
            [
                "type": "turn_context",
                "timestamp": iso0,
                "payload": ["model": "openai/gpt-5.2-pro"],
            ],
            [
                "type": "event_msg",
                "timestamp": iso1,
                "payload": [
                    "type": "token_count",
                    "info": [
                        "last_token_usage": [
                            "input_tokens": 100,
                            "cached_input_tokens": 0,
                            "output_tokens": 10,
                        ],
                    ],
                ],
            ],
            [
                "type": "turn_context",
                "timestamp": iso2,
                "payload": ["model": "openai/gpt-5.3-codex"],
            ],
            [
                "type": "event_msg",
                "timestamp": iso3,
                "payload": [
                    "type": "token_count",
                    "info": [
                        "last_token_usage": [
                            "input_tokens": 30,
                            "cached_input_tokens": 0,
                            "output_tokens": 10,
                        ],
                    ],
                ],
            ],
            [
                "type": "turn_context",
                "timestamp": iso4,
                "payload": ["model": "openai/gpt-5.2-codex"],
            ],
            [
                "type": "event_msg",
                "timestamp": iso5,
                "payload": [
                    "type": "token_count",
                    "info": [
                        "last_token_usage": [
                            "input_tokens": 20,
                            "cached_input_tokens": 0,
                            "output_tokens": 10,
                        ],
                    ],
                ],
            ],
            [
                "type": "turn_context",
                "timestamp": iso6,
                "payload": ["model": "openai/gpt-5.3-codex-spark"],
            ],
            [
                "type": "event_msg",
                "timestamp": iso7,
                "payload": [
                    "type": "token_count",
                    "info": [
                        "last_token_usage": [
                            "input_tokens": 10,
                            "cached_input_tokens": 0,
                            "output_tokens": 5,
                        ],
                    ],
                ],
            ],
        ]

        _ = try env.writeCodexSessionFile(
            day: day,
            filename: "session.jsonl",
            contents: env.jsonl(events))

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
        #expect(report.data[0].modelBreakdowns?.map(\.modelName) == [
            "gpt-5.2-pro",
            "gpt-5.3-codex",
            "gpt-5.2-codex",
            "gpt-5.3-codex-spark",
        ])
        #expect(report.data[0].modelBreakdowns?.map(\.totalTokens) == [110, 40, 30, 15])
    }

    @Test
    func `codex force rescan finds stale nested legacy sessions`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let legacyRoot = env.root.appendingPathComponent("legacy-codex-sessions", isDirectory: true)
        let nestedDir = legacyRoot.appendingPathComponent("project/subdir", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: legacyRoot
                .appendingPathComponent("2026", isDirectory: true)
                .appendingPathComponent("05", isDirectory: true)
                .appendingPathComponent("18", isDirectory: true),
            withIntermediateDirectories: true)

        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 18)
        let fileURL = nestedDir.appendingPathComponent("session.jsonl", isDirectory: false)
        try env.jsonl([
            self.codexTurnContext(timestamp: env.isoString(for: day), model: "openai/gpt-5.5"),
            self.codexTokenCount(
                timestamp: env.isoString(for: day.addingTimeInterval(1)),
                model: "openai/gpt-5.5",
                last: (input: 40, cached: 10, output: 4)),
        ]).write(to: fileURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: day.addingTimeInterval(-10 * 24 * 60 * 60)],
            ofItemAtPath: fileURL.path)

        var options = CostUsageScanner.Options(
            codexSessionsRoot: legacyRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot)
        options.forceRescan = true

        let report = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)

        #expect(report.data.count == 1)
        #expect(report.data[0].totalTokens == 44)
    }

    private static func modelsDevCatalog(
        model: String,
        input: Double,
        output: Double,
        cacheRead: Double) throws -> ModelsDevCatalog
    {
        let json = """
        {
          "openai": {
            "id": "openai",
            "name": "OpenAI",
            "models": {
              "\(model)": {
                "id": "\(model)",
                "cost": {
                  "input": \(input),
                  "output": \(output),
                  "cache_read": \(cacheRead)
                }
              }
            }
          }
        }
        """
        return try JSONDecoder().decode(ModelsDevCatalog.self, from: Data(json.utf8))
    }

    private static func sha256Hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

// swiftlint:enable type_body_length
