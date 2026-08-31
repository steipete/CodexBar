import Foundation
import Testing
@testable import CodexBarCore

extension CostUsageClaudeResolverTests {
    @Test
    func `parser preserves complete rows days and decoded model bytes against scalar pricing`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let catalog = try Self.catalog()
        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 1)
        let range = CostUsageScanner.CostUsageDayRange(since: day, until: day, calendar: .current)
        let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: day, calendar: .current)
        let models = [
            "claude-test-known", "claude-test-unknown", "claude-sonnet-4-5-20250929", "claude-sonnet-4-5",
            "anthropic.anthropic.example", "anthropic.example", "claude-test-caf\u{e9}", "claude-test-cafe\u{301}",
            " \tclaude-test-known\n", "CLAUDE-test-known", "openai/collision", "collision", "claude-test-zero",
        ]
        var expectedRows: [CostUsageScanner.ClaudeUsageRow] = []
        var expectedDays: [String: [String: [Int]]] = [:]
        var events: [[String: Any]] = []
        for (index, model) in (models + models).enumerated() {
            let timestamp = day.addingTimeInterval(Double(index))
            let input = 199_990 + index
            let output = index + 1
            let cost = CostUsagePricing.claudeCostUSD(
                model: model,
                inputTokens: input,
                cacheReadInputTokens: 3,
                cacheCreationInputTokens: 4,
                cacheCreationInputTokens1h: 2,
                outputTokens: output,
                pricingDate: timestamp,
                modelsDevCatalog: catalog)
            let nanos = cost.map { Int(($0 * 1_000_000_000).rounded()) } ?? 0
            let stored = CostUsagePricing.normalizeClaudeModel(model)
            expectedRows.append(CostUsageScanner.ClaudeUsageRow(
                dayKey: dayKey,
                model: stored,
                sessionId: nil,
                messageId: nil,
                requestId: nil,
                timestampUnixMs: Int64((timestamp.timeIntervalSince1970 * 1000).rounded()),
                isSidechain: false,
                pathRole: .parent,
                input: input,
                cacheRead: 3,
                cacheCreate: 4,
                cacheCreate1h: 2,
                output: output,
                costNanos: nanos,
                costPriced: cost != nil))
            let packedKey = CostUsagePricing.normalizeClaudeModel(stored)
            let components = [input, 3, 4, output, nanos, 1, cost == nil ? 0 : 1, 2]
            let previous = expectedDays[dayKey]?[packedKey] ?? Array(repeating: 0, count: 8)
            expectedDays[dayKey, default: [:]][packedKey] = zip(previous, components).map(+)
            events.append([
                "type": "assistant", "timestamp": env.isoString(for: timestamp),
                "message": ["model": model, "usage": [
                    "input_tokens": input, "output_tokens": output, "cache_read_input_tokens": 3,
                    "cache_creation_input_tokens": 4,
                    "cache_creation": ["ephemeral_5m_input_tokens": 2, "ephemeral_1h_input_tokens": 2],
                ]],
            ])
        }
        let content = try env.jsonl(events).replacingOccurrences(
            of: "claude-test-known", with: #"claude-\u0074est-known"#)
        let file = try env.writeClaudeProjectFile(relativePath: "project/session.jsonl", contents: content)
        let parsed = CostUsageScanner.parseClaudeFile(
            fileURL: file, range: range, providerFilter: .all, modelsDevCatalog: catalog)
        #expect(parsed.parsedBytes == Int64(content.utf8.count))
        #expect(parsed.rows == expectedRows)
        #expect(parsed.rows.map { Array($0.model.utf8) } == expectedRows.map { Array($0.model.utf8) })
        #expect(parsed.days == expectedDays)
        #expect(parsed.days[dayKey]?["example"] != nil)
        #expect(parsed.rows.contains { $0.model == "anthropic.example" })
    }

    @Test
    func `raw dated parsing and stored report identity retain distinct catalog prices`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 1)
        let catalog = try Self.catalog()
        #expect(ModelsDevCache.save(catalog: catalog, fetchedAt: day, cacheRoot: env.cacheRoot))
        let rawModels = ["claude-sonnet-4-5-20250929", "claude-sonnet-4-5"]
        let file = try env.writeClaudeProjectFile(relativePath: "project/session.jsonl", contents: env.jsonl(
            rawModels.map { model in
                ["type": "assistant", "timestamp": env.isoString(for: day), "message": [
                    "model": model, "usage": ["input_tokens": 100, "output_tokens": 0],
                ]]
            }))
        let options = CostUsageScanner.Options(claudeProjectsRoots: [env.claudeProjectsRoot], cacheRoot: env.cacheRoot)
        let work = CostUsageScanner.ClaudeScanWorkRecorder()
        let report = try CostUsageScanner.withClaudeScanWorkRecorderForTesting(work) {
            try CostUsageScanner.loadDailyReportCancellable(
                provider: .claude, since: day, until: day, now: day, options: options, checkCancellation: nil)
        }
        let cache = CostUsageClaudeCacheIO.load(provider: .claude, cacheRoot: env.cacheRoot)
        #expect(cache.files.count == 1)
        let cachedPath = try #require(cache.files.keys.first)
        #expect(URL(fileURLWithPath: cachedPath).resolvingSymlinksInPath() == file.resolvingSymlinksInPath())
        let rows = try #require(cache.files[cachedPath]?.claudeRows)
        #expect(rows.map(\.model) == ["claude-sonnet-4-5", "claude-sonnet-4-5"])
        #expect(rows.map(\.costNanos) == rawModels.map {
            Int(((Self.scalar(catalog, model: $0) ?? 0) * 1_000_000_000).rounded())
        })
        #expect(rows[0].costNanos != rows[1].costNanos)
        #expect(report.summary?.totalCostUSD == Self.scalar(catalog, model: rawModels[1]).map { $0 + $0 })
        #expect(work.snapshot().catalogModelLookups == 2)
        #expect(work.snapshot().normalizationCacheMisses == 2)
        #expect(work.snapshot().repricedRows == 2)
    }
}
