import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CostUsageScannerClaudeCacheUpgradeTests {
    @Test(arguments: [UsageProvider.claude, .vertexai])
    func `cold restart rebuilds inflated proxy caches and replaces prior report semantics`(
        provider: UsageProvider) throws
    {
        let env = try CostUsageTestEnvironment()
        defer {
            CostUsageScanner.evictClaudeReportMemoForTesting(provider: provider, cacheRoot: env.cacheRoot)
            env.cleanup()
        }
        let day = try env.makeLocalNoon(year: 2025, month: 12, day: 21)
        let otherProvider: UsageProvider = provider == .claude ? .vertexai : .claude
        let chunks = [7, 19, 19].map { self.chunk(env: env, day: day, provider: provider, output: $0) }
        let sourceURL = try env.writeClaudeProjectFile(
            relativePath: "project/proxy-session.jsonl",
            contents: env.jsonl(chunks + [self.chunk(env: env, day: day, provider: otherProvider, output: 100)]))
        let sourceData = try Data(contentsOf: sourceURL)
        let sourceStamp = try #require(CostUsageClaudeFileStamp.read(at: sourceURL))
        var options = CostUsageScanner.Options(
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot)
        options.claudeLogProviderFilter = provider == .claude ? .excludeVertexAI : .vertexAIOnly
        options.refreshMinIntervalSeconds = 60

        let (fresh, _) = self.recordedLoad(provider: provider, day: day, options: options)
        try self.expectCorrectReport(fresh)
        let dayKey = try #require(fresh.data.first?.date)
        let model = try #require(fresh.data.first?.modelsUsed?.first)
        let cacheURL = CostUsageClaudeCacheIO.cacheFileURL(provider: provider, cacheRoot: env.cacheRoot)
        let memoURL = CostUsageClaudeReportMemo.reportMemoFileURL(cacheFileURL: cacheURL)
        var memo = try JSONDecoder().decode(PersistedReportMemo.self, from: Data(contentsOf: memoURL))
        let initialMemoKey = memo.reportKey
        let initialInventory = memo.sourceInventory
        let legacyCache = try self.seedLegacyCache(at: cacheURL, day: day)
        let path = try #require(legacyCache.usage.files.keys.first)
        let legacyCacheStamp = try #require(CostUsageClaudeFileStamp.read(at: cacheURL))
        memo.reportKey = self.replacingCacheStamp(in: initialMemoKey, with: legacyCacheStamp)
        memo.report = self.inflatedReport(dayKey: dayKey, model: model)
        try JSONEncoder().encode(memo).write(to: memoURL)

        // A current-semantics control proves this exact inventory/key would bypass the legacy cache.
        CostUsageScanner.evictClaudeReportMemoForTesting(provider: provider, cacheRoot: env.cacheRoot)
        let (control, controlWork) = self.recordedLoad(provider: provider, day: day, options: options)
        #expect(control.summary?.totalTokens == 495)
        #expect(try abs(#require(control.summary?.totalCostUSD) - 0.001215) < 0.000000001)
        #expect(controlWork == CostUsageScanner.ClaudeScanWorkMetrics())

        memo.reportSemanticsVersion = 1
        try JSONEncoder().encode(memo).write(to: memoURL)
        let seededMemo = try JSONDecoder().decode(PersistedReportMemo.self, from: Data(contentsOf: memoURL))
        #expect(seededMemo.version == 1)
        #expect(seededMemo.reportSemanticsVersion == 1)
        #expect(seededMemo.reportKey == memo.reportKey)
        #expect(seededMemo.sourceInventory == initialInventory)
        #expect(seededMemo.sourceInventory[path] == sourceStamp)
        #expect(seededMemo.reportKey.cacheArtifactStamp == CostUsageClaudeFileStamp.read(at: cacheURL))
        #expect(legacyCache.usage.version == 1)
        #expect(legacyCache.sourceFileIDs[path] == sourceStamp.fileID)
        #expect(legacyCache.usage.files[path]?.size == sourceStamp.size)
        #expect(legacyCache.usage.files[path]?.mtimeUnixMs == sourceStamp.mtimeUnixMs)
        #expect(legacyCache.usage.files[path]?.parsedBytes == sourceStamp.size)
        #expect(legacyCache.usage.files[path]?.claudeRows?.map(\.output) == [7, 19, 19])
        #expect(try Data(contentsOf: sourceURL) == sourceData)
        #expect(CostUsageClaudeFileStamp.read(at: sourceURL) == sourceStamp)

        CostUsageScanner.evictClaudeReportMemoForTesting(provider: provider, cacheRoot: env.cacheRoot)
        let (upgraded, work) = self.recordedLoad(provider: provider, day: day, options: options)
        try self.expectCorrectReport(upgraded)
        #expect(upgraded.data == fresh.data)
        #expect(upgraded.summary == fresh.summary)
        #expect(work.cacheDecodes == 1)
        #expect(work.transcriptParses == 1)
        #expect(work.incrementalTranscriptParses == 0)
        #expect(work.cacheEncodes == 1)

        let savedCache = try JSONDecoder().decode(CostUsageClaudeCache.self, from: Data(contentsOf: cacheURL))
        let savedMemo = try JSONDecoder().decode(PersistedReportMemo.self, from: Data(contentsOf: memoURL))
        #expect(savedCache.usage.version == 3)
        #expect(savedCache.usage.files.count == 1)
        #expect(savedCache.usage.files[path]?.claudeRows?.map(\.output) == [19])
        #expect(savedCache.usage.days == [dayKey: [model: [50, 100, 0, 19, 465_000, 1, 1, 0]]])
        #expect(savedCache.sourceFileIDs[path] == sourceStamp.fileID)
        #expect(savedMemo.version == CostUsageClaudeReportMemo.persistedVersion)
        #expect(savedMemo.reportSemanticsVersion == 4)
        #expect(savedMemo.reportSemanticsVersion == CostUsageClaudeReportMemo.reportSemanticsVersion)
        #expect(savedMemo.sourceInventory == initialInventory)
        #expect(savedMemo.reportKey.cacheArtifactStamp == CostUsageClaudeFileStamp.read(at: cacheURL))
        #expect(savedMemo.report.data == upgraded.data)
        #expect(savedMemo.report.summary == upgraded.summary)
        let savedCacheStamp = CostUsageClaudeFileStamp.read(at: cacheURL)
        let savedMemoStamp = CostUsageClaudeFileStamp.read(at: memoURL)

        CostUsageScanner.evictClaudeReportMemoForTesting(provider: provider, cacheRoot: env.cacheRoot)
        let (restarted, restartWork) = self.recordedLoad(provider: provider, day: day, options: options)
        #expect(restarted.data == upgraded.data)
        #expect(restarted.summary == upgraded.summary)
        #expect(restartWork == CostUsageScanner.ClaudeScanWorkMetrics())
        #expect(CostUsageClaudeFileStamp.read(at: cacheURL) == savedCacheStamp)
        #expect(CostUsageClaudeFileStamp.read(at: memoURL) == savedMemoStamp)
        #expect(try Data(contentsOf: sourceURL) == sourceData)
        #expect(CostUsageClaudeFileStamp.read(at: sourceURL) == sourceStamp)
    }

    @Test
    func `version two reports reprice GPT usage without rereading unchanged transcripts`() throws {
        let env = try CostUsageTestEnvironment()
        defer {
            CostUsageScanner.evictClaudeReportMemoForTesting(provider: .claude, cacheRoot: env.cacheRoot)
            env.cleanup()
        }
        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 16)
        let model = "gpt-5.6-sol"
        #expect(try ModelsDevCache.save(
            catalog: CostUsagePricingClaudeThresholdTests.catalog(),
            fetchedAt: day,
            cacheRoot: env.cacheRoot))
        let source = try env.writeClaudeProjectFile(
            relativePath: "project/gpt-session.jsonl",
            contents: env.jsonl([[
                "type": "assistant",
                "timestamp": env.isoString(for: day),
                "sessionId": "gpt-session",
                "message": ["id": "gpt-response", "model": model, "usage": [
                    "input_tokens": 72999,
                    "cache_read_input_tokens": 199_000,
                    "output_tokens": 100,
                ]],
            ]]))
        let sourceData = try Data(contentsOf: source)
        let sourceStamp = CostUsageClaudeFileStamp.read(at: source)
        var options = CostUsageScanner.Options(
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 60
        let (fresh, _) = self.recordedLoad(provider: .claude, day: day, options: options)
        #expect(try abs(#require(fresh.summary?.totalCostUSD) - 0.196148) < 1e-10)
        let dayKey = try #require(fresh.data.first?.date)
        let cacheURL = CostUsageClaudeCacheIO.cacheFileURL(provider: .claude, cacheRoot: env.cacheRoot)
        let memoURL = CostUsageClaudeReportMemo.reportMemoFileURL(cacheFileURL: cacheURL)
        var cache = try JSONDecoder().decode(CostUsageClaudeCache.self, from: Data(contentsOf: cacheURL))
        let path = try #require(cache.usage.files.keys.first)
        let row = try #require(cache.usage.files[path]?.claudeRows?.first)
        cache.usage.files[path]?.claudeRows = [CostUsageScanner.ClaudeUsageRow(
            dayKey: row.dayKey,
            model: row.model,
            sessionId: row.sessionId,
            messageId: row.messageId,
            requestId: row.requestId,
            timestampUnixMs: row.timestampUnixMs,
            isSidechain: row.isSidechain,
            pathRole: row.pathRole,
            input: row.input,
            cacheRead: row.cacheRead,
            cacheCreate: row.cacheCreate,
            cacheCreate1h: row.cacheCreate1h,
            output: row.output,
            costNanos: 611_593_000,
            costPriced: true)]
        cache.usage.days[dayKey]?[model]?[4] = 611_593_000
        #expect(cache.usage.version == 3)
        try JSONEncoder().encode(cache).write(to: cacheURL)
        let cacheStamp = try #require(CostUsageClaudeFileStamp.read(at: cacheURL))
        var memo = try JSONDecoder().decode(PersistedReportMemo.self, from: Data(contentsOf: memoURL))
        memo.reportKey = self.replacingCacheStamp(in: memo.reportKey, with: cacheStamp)
        memo.report = CostUsageDailyReport(
            data: [CostUsageDailyReport.Entry(
                date: dayKey,
                inputTokens: 72999,
                outputTokens: 100,
                cacheReadTokens: 199_000,
                cacheCreationTokens: 0,
                totalTokens: 272_099,
                costUSD: 0.611593,
                modelsUsed: [model],
                modelBreakdowns: [CostUsageDailyReport.ModelBreakdown(
                    modelName: model,
                    costUSD: 0.611593,
                    totalTokens: 272_099)])],
            summary: CostUsageDailyReport.Summary(
                totalInputTokens: 72999,
                totalOutputTokens: 100,
                cacheReadTokens: 199_000,
                cacheCreationTokens: 0,
                totalTokens: 272_099,
                totalCostUSD: 0.611593))
        try JSONEncoder().encode(memo).write(to: memoURL)
        CostUsageScanner.evictClaudeReportMemoForTesting(provider: .claude, cacheRoot: env.cacheRoot)
        let (control, controlWork) = self.recordedLoad(provider: .claude, day: day, options: options)
        #expect(control.summary?.totalCostUSD == 0.611593)
        #expect(controlWork == CostUsageScanner.ClaudeScanWorkMetrics())

        memo.reportSemanticsVersion = 2
        try JSONEncoder().encode(memo).write(to: memoURL)
        CostUsageScanner.evictClaudeReportMemoForTesting(provider: .claude, cacheRoot: env.cacheRoot)
        let (upgraded, work) = self.recordedLoad(provider: .claude, day: day, options: options)
        #expect(upgraded.data == fresh.data)
        #expect(upgraded.summary == fresh.summary)
        #expect(work.cacheDecodes == 1)
        #expect(work.transcriptParses == 0)
        #expect(work.cacheEncodes == 0)
        #expect(work.repricedRows == 1)
        #expect(CostUsageClaudeFileStamp.read(at: cacheURL) == cacheStamp)
        #expect(CostUsageClaudeFileStamp.read(at: source) == sourceStamp)
        #expect(try Data(contentsOf: source) == sourceData)
        let savedMemo = try JSONDecoder().decode(PersistedReportMemo.self, from: Data(contentsOf: memoURL))
        #expect(savedMemo.reportSemanticsVersion == 4)
        CostUsageScanner.evictClaudeReportMemoForTesting(provider: .claude, cacheRoot: env.cacheRoot)
        let (restarted, restartWork) = self.recordedLoad(provider: .claude, day: day, options: options)
        #expect(restarted.data == upgraded.data)
        #expect(restarted.summary == upgraded.summary)
        #expect(restartWork == CostUsageScanner.ClaudeScanWorkMetrics())
    }

    @Test
    func `schema two caches reparse preliminary proxy records once after a cold restart`() throws {
        let env = try CostUsageTestEnvironment()
        defer {
            CostUsageScanner.evictClaudeReportMemoForTesting(provider: .claude, cacheRoot: env.cacheRoot)
            env.cleanup()
        }
        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 16)
        let model = "gpt-5.6-sol"
        #expect(try ModelsDevCache.save(
            catalog: CostUsagePricingClaudeThresholdTests.catalog(),
            fetchedAt: day,
            cacheRoot: env.cacheRoot))
        let source = try env.writeClaudeProjectFile(relativePath: "project/incomplete.jsonl", contents: env.jsonl([[
            "type": "assistant",
            "timestamp": env.isoString(for: day),
            "sessionId": "proxy-session",
            "message": ["id": "preliminary", "model": model, "stop_reason": NSNull(), "usage": [
                "input_tokens": 161_200,
                "output_tokens": 0,
            ]],
        ]]))
        let sourceData = try Data(contentsOf: source)
        let sourceStamp = CostUsageClaudeFileStamp.read(at: source)
        var options = CostUsageScanner.Options(
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 60
        let (fresh, _) = self.recordedLoad(provider: .claude, day: day, options: options)
        let dayKey = try #require(fresh.data.first?.date)
        #expect(fresh.data.first?.incompleteRequestCount == 1)
        #expect(fresh.summary?.totalCostUSD == nil)
        let cacheURL = CostUsageClaudeCacheIO.cacheFileURL(provider: .claude, cacheRoot: env.cacheRoot)
        let memoURL = CostUsageClaudeReportMemo.reportMemoFileURL(cacheFileURL: cacheURL)
        var cache = try JSONDecoder().decode(CostUsageClaudeCache.self, from: Data(contentsOf: cacheURL))
        let path = try #require(cache.usage.files.keys.first)
        let row = try #require(cache.usage.files[path]?.claudeRows?.first)
        cache.usage.version = 2
        cache.usage.files[path]?.claudeRows = [CostUsageScanner.ClaudeUsageRow(
            dayKey: row.dayKey,
            model: row.model,
            sessionId: row.sessionId,
            messageId: row.messageId,
            requestId: row.requestId,
            timestampUnixMs: row.timestampUnixMs,
            isSidechain: row.isSidechain,
            pathRole: row.pathRole,
            input: row.input,
            cacheRead: row.cacheRead,
            cacheCreate: row.cacheCreate,
            cacheCreate1h: row.cacheCreate1h,
            output: row.output,
            costNanos: 322_400_000,
            costPriced: true)]
        cache.usage.days = [dayKey: [model: [161_200, 0, 0, 0, 322_400_000, 1, 1, 0]]]
        let legacyData = try JSONEncoder().encode(cache)
        #expect(try #require(String(data: legacyData, encoding: .utf8)).contains("isIncomplete") == false)
        try legacyData.write(to: cacheURL)
        var memo = try JSONDecoder().decode(PersistedReportMemo.self, from: Data(contentsOf: memoURL))
        memo.reportKey = try self.replacingCacheStamp(
            in: memo.reportKey,
            with: #require(CostUsageClaudeFileStamp.read(at: cacheURL)))
        memo.report = CostUsageDailyReport(
            data: [.init(
                date: dayKey,
                inputTokens: 161_200,
                outputTokens: 0,
                totalTokens: 161_200,
                costUSD: 0.3224,
                modelsUsed: [model],
                modelBreakdowns: [
                    .init(modelName: model, costUSD: 0.3224, totalTokens: 161_200),
                ])],
            summary: .init(totalInputTokens: 161_200, totalOutputTokens: 0, totalTokens: 161_200, totalCostUSD: 0.3224))
        try JSONEncoder().encode(memo).write(to: memoURL)
        CostUsageScanner.evictClaudeReportMemoForTesting(provider: .claude, cacheRoot: env.cacheRoot)
        let (control, controlWork) = self.recordedLoad(provider: .claude, day: day, options: options)
        #expect(control.summary?.totalCostUSD == 0.3224)
        #expect(controlWork == CostUsageScanner.ClaudeScanWorkMetrics())

        memo.reportSemanticsVersion = 3
        try JSONEncoder().encode(memo).write(to: memoURL)
        CostUsageScanner.evictClaudeReportMemoForTesting(provider: .claude, cacheRoot: env.cacheRoot)
        let (upgraded, work) = self.recordedLoad(provider: .claude, day: day, options: options)
        #expect(upgraded.data == fresh.data)
        #expect(upgraded.summary == fresh.summary)
        #expect(work.cacheDecodes == 1)
        #expect(work.transcriptParses == 1)
        #expect(work.cacheEncodes == 1)
        let savedCache = try JSONDecoder().decode(CostUsageClaudeCache.self, from: Data(contentsOf: cacheURL))
        #expect(savedCache.usage.version == 3)
        #expect(savedCache.usage.files[path]?.claudeRows?.first?.isIncomplete == true)
        let savedMemo = try JSONDecoder().decode(PersistedReportMemo.self, from: Data(contentsOf: memoURL))
        #expect(savedMemo.reportSemanticsVersion == 4)
        CostUsageScanner.evictClaudeReportMemoForTesting(provider: .claude, cacheRoot: env.cacheRoot)
        let (restarted, restartWork) = self.recordedLoad(provider: .claude, day: day, options: options)
        #expect(restarted.data == upgraded.data)
        #expect(restartWork == CostUsageScanner.ClaudeScanWorkMetrics())
        #expect(try Data(contentsOf: source) == sourceData)
        #expect(CostUsageClaudeFileStamp.read(at: source) == sourceStamp)
    }

    private struct PersistedReportMemo: Codable {
        var version: Int
        var reportSemanticsVersion: Int
        var sourceInventory: [String: CostUsageClaudeFileStamp]
        var reportKey: CostUsageClaudeReportMemoKey
        var report: CostUsageDailyReport
    }

    private func seedLegacyCache(at cacheURL: URL, day: Date) throws -> CostUsageClaudeCache {
        var cache = try JSONDecoder().decode(CostUsageClaudeCache.self, from: Data(contentsOf: cacheURL))
        let path = try #require(cache.usage.files.keys.first)
        let finalRow = try #require(cache.usage.files[path]?.claudeRows?.first)
        let rows = [7, 19, 19].map { output in
            CostUsageScanner.ClaudeUsageRow(
                dayKey: finalRow.dayKey,
                model: finalRow.model,
                sessionId: finalRow.sessionId,
                messageId: finalRow.messageId,
                requestId: nil,
                timestampUnixMs: Int64(day.addingTimeInterval(Double(output)).timeIntervalSince1970 * 1000),
                isSidechain: false,
                pathRole: .parent,
                input: 50,
                cacheRead: 100,
                cacheCreate: 0,
                cacheCreate1h: 0,
                output: output,
                costNanos: 180_000 + output * 15000,
                costPriced: true)
        }
        cache.usage.version = 1
        cache.usage.files[path]?.claudeRows = rows
        // Schema 1 retained and summed each cumulative proxy snapshot.
        cache.usage.days = [finalRow.dayKey: [finalRow.model: [150, 300, 0, 45, 1_215_000, 3, 3, 0]]]
        try JSONEncoder().encode(cache).write(to: cacheURL)
        return cache
    }

    private func replacingCacheStamp(
        in key: CostUsageClaudeReportMemoKey,
        with stamp: CostUsageClaudeFileStamp) -> CostUsageClaudeReportMemoKey
    {
        CostUsageClaudeReportMemoKey(
            provider: key.provider,
            providerFilter: key.providerFilter,
            sinceKey: key.sinceKey,
            untilKey: key.untilKey,
            scanSinceKey: key.scanSinceKey,
            scanUntilKey: key.scanUntilKey,
            timeZoneIdentifier: key.timeZoneIdentifier,
            roots: key.roots,
            cacheArtifactStamp: stamp,
            pricingArtifactStamp: key.pricingArtifactStamp)
    }

    private func inflatedReport(dayKey: String, model: String) -> CostUsageDailyReport {
        CostUsageDailyReport(
            data: [CostUsageDailyReport.Entry(
                date: dayKey,
                inputTokens: 150,
                outputTokens: 45,
                cacheReadTokens: 300,
                cacheCreationTokens: 0,
                totalTokens: 495,
                costUSD: 0.001215,
                modelsUsed: [model],
                modelBreakdowns: [CostUsageDailyReport.ModelBreakdown(
                    modelName: model,
                    costUSD: 0.001215,
                    totalTokens: 495)])],
            summary: CostUsageDailyReport.Summary(
                totalInputTokens: 150,
                totalOutputTokens: 45,
                cacheReadTokens: 300,
                cacheCreationTokens: 0,
                totalTokens: 495,
                totalCostUSD: 0.001215))
    }

    private func expectCorrectReport(_ report: CostUsageDailyReport) throws {
        #expect(report.data.count == 1)
        let entry = try #require(report.data.first)
        #expect(entry.inputTokens == 50)
        #expect(entry.cacheReadTokens == 100)
        #expect(entry.cacheCreationTokens == 0)
        #expect(entry.outputTokens == 19)
        #expect(entry.totalTokens == 169)
        #expect(try abs(#require(entry.costUSD) - 0.000465) < 0.000000001)
        #expect(report.summary?.totalTokens == 169)
        #expect(try abs(#require(report.summary?.totalCostUSD) - 0.000465) < 0.000000001)
    }

    private func recordedLoad(
        provider: UsageProvider,
        day: Date,
        options: CostUsageScanner.Options) -> (CostUsageDailyReport, CostUsageScanner.ClaudeScanWorkMetrics)
    {
        let recorder = CostUsageScanner.ClaudeScanWorkRecorder()
        let report = CostUsageScanner.withClaudeScanWorkRecorderForTesting(recorder) {
            CostUsageScanner.loadDailyReport(provider: provider, since: day, until: day, now: day, options: options)
        }
        return (report, recorder.snapshot())
    }

    private func chunk(
        env: CostUsageTestEnvironment,
        day: Date,
        provider: UsageProvider,
        output: Int) -> [String: Any]
    {
        [
            "type": "assistant",
            "timestamp": env.isoString(for: day.addingTimeInterval(Double(output))),
            "sessionId": "\(provider.rawValue)-session",
            "metadata": ["provider": provider == .vertexai ? "vertexai" : "anthropic"],
            "message": [
                "id": "\(provider.rawValue)-response",
                "model": "claude-sonnet-4-20250514",
                "usage": [
                    "input_tokens": 50,
                    "cache_read_input_tokens": 100,
                    "output_tokens": output,
                ],
            ],
        ]
    }
}
