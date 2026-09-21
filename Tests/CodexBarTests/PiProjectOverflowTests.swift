import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct PiProjectOverflowTests {
    @Test(arguments: [false, true])
    func `native and Pi project model overflow remains unknown after later valid rows`(sameDay: Bool) async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let firstDay = try #require(calendar.date(from: DateComponents(
            year: 2026, month: 4, day: 6, hour: 12)))
        let secondDay = try #require(calendar.date(byAdding: .day, value: 1, to: firstDay))
        let lastDay = try #require(calendar.date(byAdding: .day, value: 2, to: firstDay))
        let now = lastDay.addingTimeInterval(60)
        let large = 1 << 62
        let model = "fictional-shared-project-model"
        let controlModel = "fictional-independent-project-model"
        try self.writeNative(env, date: firstDay, name: "large", model: model, input: large)
        try self.writeNative(env, date: lastDay, name: "later", model: model, input: 7)
        try self.writeNative(env, date: lastDay, name: "control", model: controlModel, input: 3)
        let piDay = sameDay ? firstDay : secondDay
        _ = try env.writePiSessionFile(
            relativePath: "project-overflow.jsonl",
            contents: env.jsonl([[
                "type": "message", "id": "pi-large", "timestamp": env.isoString(for: piDay),
                "message": [
                    "role": "assistant", "provider": "openai-codex", "model": model,
                    "usage": ["input": large, "output": 0, "totalTokens": large],
                ],
            ]]))
        let omp = env.root.appendingPathComponent("empty-omp", isDirectory: true)
        try FileManager.default.createDirectory(at: omp, withIntermediateDirectories: true)
        let environment = ["HOME": env.root.path]
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"),
            calendar: calendar)
        options.refreshMinIntervalSeconds = 0
        let piOptions = PiSessionCostScanner.Options(
            piSessionsRoot: env.piSessionsRoot,
            ompSessionsRoot: omp,
            cacheRoot: env.cacheRoot,
            calendar: calendar,
            refreshMinIntervalSeconds: 0,
            environment: environment)

        let native = try await CostUsageFetcher.loadTokenResult(
            provider: .codex,
            environment: environment,
            now: now,
            historyDays: 3,
            allowPricingRefresh: false,
            refreshPricingInBackground: false,
            includePiSessions: false,
            scannerOptions: options,
            piScannerOptions: piOptions)
        #expect(native.snapshot.historyCoverageIsEstablished)
        #expect(native.snapshot.last30DaysTokens == large + 10)
        #expect(native.snapshot.projects.count == 1)
        #expect(native.snapshot.projects.first?.path == nil)
        let pi = try PiSessionCostScanner.loadDailyReportResultCancellable(
            provider: .codex,
            since: firstDay,
            until: now,
            now: now,
            options: piOptions,
            checkCancellation: nil)
        #expect(pi.isComplete)
        #expect(pi.report.summary?.totalTokens == large)
        #expect(pi.report.summary?.totalCostUSD == nil)

        let fresh = try await CostUsageFetcher.loadTokenResult(
            provider: .codex,
            environment: environment,
            now: now,
            historyDays: 3,
            allowPricingRefresh: false,
            refreshPricingInBackground: false,
            includePiSessions: true,
            scannerOptions: options,
            piScannerOptions: piOptions)
        try self.expectOverflowProjection(fresh.snapshot, model: model, controlModel: controlModel)

        let cachedValue = await CostUsageFetcher.loadCachedCodexTokenSnapshotResult(
            now: now.addingTimeInterval(1),
            historyDays: 3,
            includePiSessions: true,
            scannerOptions: options,
            environment: environment,
            piScannerOptions: piOptions)
        let cached = try #require(cachedValue)
        try self.expectOverflowProjection(cached.snapshot, model: model, controlModel: controlModel)
        #expect(cached.snapshot.projects == fresh.snapshot.projects)
    }

    private func expectOverflowProjection(
        _ snapshot: CostUsageTokenSnapshot,
        model: String,
        controlModel: String) throws
    {
        #expect(snapshot.sessionTokens == 10)
        #expect(snapshot.last30DaysTokens == nil)
        let project = try #require(snapshot.projects.first { $0.path == nil })
        #expect(project.name == CostUsageProjectBreakdown.unknownProjectName)
        #expect(project.totalTokens == nil)
        let overflowed = try #require(project.modelBreakdowns?.first { $0.modelName == model })
        #expect(overflowed.totalTokens == nil)
        let unaffected = try #require(project.modelBreakdowns?.first { $0.modelName == controlModel })
        #expect(unaffected.totalTokens == 3)
        let source = try #require(project.sources.first { $0.path == nil })
        #expect(source.totalTokens == nil)
        let sourceModel = try #require(source.modelBreakdowns?.first { $0.modelName == model })
        #expect(sourceModel.totalTokens == nil)
    }

    private func writeNative(
        _ env: CostUsageTestEnvironment,
        date: Date,
        name: String,
        model: String,
        input: Int) throws
    {
        // Deliberately omit cwd: both native history and Pi must meet in the unknown-project bucket.
        _ = try env.writeCodexSessionFile(
            day: date,
            filename: "project-overflow-\(name).jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta", "timestamp": env.isoString(for: date),
                    "payload": ["id": "synthetic-project-overflow-\(name)"],
                ],
                [
                    "type": "turn_context", "timestamp": env.isoString(for: date),
                    "payload": ["model": model],
                ],
                [
                    "type": "event_msg", "timestamp": env.isoString(for: date.addingTimeInterval(1)),
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "model": model,
                            "last_token_usage": ["input_tokens": input, "cached_input_tokens": 0, "output_tokens": 0],
                        ],
                    ],
                ],
            ]))
    }
}
