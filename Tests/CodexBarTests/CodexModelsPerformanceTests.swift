import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
@Suite(.serialized)
struct CodexModelsPerformanceTests {
    @Test
    func `workspace scale snapshot build stays within end to end budget`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-workspace-performance-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        let cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)

        let options = CostUsageScanner.Options(codexSessionsRoot: sessionsRoot, cacheRoot: cacheRoot)
        let end = Date(timeIntervalSince1970: 1_784_160_000)
        let currentDay = end.addingTimeInterval(-24 * 60 * 60)
        let previousDay = currentDay.addingTimeInterval(-30 * 24 * 60 * 60)
        let currentDayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: currentDay)
        let previousDayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: previousDay)
        var cache = CostUsageCache()
        cache.roots = CostUsageScanner.codexRootsFingerprint(options: options)

        for projectIndex in 0..<30 {
            let project = root.appendingPathComponent("project-\(projectIndex)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: project.appendingPathComponent(".git", isDirectory: true),
                withIntermediateDirectories: true)
            for sessionIndex in 0..<8 {
                let sessionID = "project-\(projectIndex)-session-\(sessionIndex)"
                cache.files[sessionsRoot.appendingPathComponent("\(sessionID).jsonl").path] = self.workspaceUsage(
                    sessionID: sessionID,
                    cwd: project.path,
                    currentDay: currentDay,
                    currentDayKey: currentDayKey,
                    previousDay: previousDay,
                    previousDayKey: previousDayKey,
                    seed: projectIndex * 8 + sessionIndex)
            }
        }

        func build() throws -> CodexLocalProjectUsageSnapshot {
            try CodexLocalProjectUsageIndexer.buildSnapshotFromCostCache(
                now: end,
                historyDays: 30,
                since: previousDay.addingTimeInterval(24 * 60 * 60),
                until: end,
                options: options,
                cacheOverride: cache,
                catalogOverride: .empty)
        }

        _ = try build()
        let clock = ContinuousClock()
        var durations: [Duration] = []
        var snapshot: CodexLocalProjectUsageSnapshot?
        for _ in 0..<3 {
            let start = clock.now
            snapshot = try build()
            durations.append(start.duration(to: clock.now))
        }

        let measured = try #require(snapshot)
        // Best-of-three, not the median: the fastest run is the one least interrupted by other
        // work on the machine, which is what a regression guard should measure.
        let fastest = try #require(durations.min())
        #expect(fastest < TestTimingBudget.scaled(.seconds(2)))
        #expect(measured.projects.count == 30)
        #expect(measured.sessions.count == 240)
        #expect((measured.total.totalTokens ?? 0) > 0)
        #expect((measured.modelsAnalytics?.allWorkspaces.rows.count ?? 0) == 4)
        #expect((measured.modelsAnalytics?.workspaces.count ?? 0) == 30)
        #expect(measured.modelsAnalytics?.workspaces.values.allSatisfy { $0.rows.count == 4 } == true)
        #expect(measured.modelsAnalytics?.allWorkspaces.comparison(.tokens) != .unavailable)
    }

    // swiftlint:disable:next function_parameter_count
    private func workspaceUsage(
        sessionID: String,
        cwd: String,
        currentDay: Date,
        currentDayKey: String,
        previousDay: Date,
        previousDayKey: String,
        seed: Int) -> CostUsageFileUsage
    {
        let models = (0..<4).map { "model-\($0)" }
        var days: [String: [String: [Int]]] = [:]
        var rows: [CostUsageScanner.CodexUsageRow] = []
        for (index, model) in models.enumerated() {
            let input = 100 + seed + index
            let cached = input / 4
            let output = input / 5
            days[currentDayKey, default: [:]][model] = [input, cached, output]
            days[previousDayKey, default: [:]][model] = [input - 1, cached, output]
            rows.append(CostUsageScanner.CodexUsageRow(
                day: currentDayKey,
                model: model,
                turnID: "current-\(index)",
                eventIndex: index * 2,
                timestampUnixMs: Int64(currentDay.timeIntervalSince1970 * 1000) + Int64(index),
                input: input,
                cached: cached,
                output: output,
                knownCostNanos: Int64(input * 1000),
                unpricedTokens: 0,
                pricingModel: model,
                pricingMode: "standard"))
            rows.append(CostUsageScanner.CodexUsageRow(
                day: previousDayKey,
                model: model,
                turnID: "previous-\(index)",
                eventIndex: index * 2 + 1,
                timestampUnixMs: Int64(previousDay.timeIntervalSince1970 * 1000) + Int64(index),
                input: input - 1,
                cached: cached,
                output: output,
                knownCostNanos: Int64((input - 1) * 1000),
                unpricedTokens: 0,
                pricingModel: model,
                pricingMode: "standard"))
        }
        return CostUsageFileUsage(
            mtimeUnixMs: 1,
            size: 1,
            days: days,
            parsedBytes: 1,
            lastModel: models.last,
            lastTotals: nil,
            lastCountedTotals: nil,
            lastRawTotalsBaseline: nil,
            hasDivergentTotals: nil,
            lastCodexTurnID: nil,
            sessionId: sessionID,
            forkedFromId: nil,
            codexSession: CostUsageCodexSessionMetadata(
                sessionId: sessionID,
                forkedFromId: nil,
                cwd: cwd,
                title: nil,
                startedAtUnixMs: Int64(previousDay.timeIntervalSince1970 * 1000),
                latestActivityUnixMs: Int64(currentDay.timeIntervalSince1970 * 1000)),
            codexCostNanos: nil,
            codexPrioritySurchargeNanos: nil,
            codexStandardCostNanos: nil,
            codexPriorityCostNanos: nil,
            codexStandardTokens: nil,
            codexPriorityTokens: nil,
            codexTurnIDs: nil,
            codexRows: rows,
            claudeRows: nil)
            .refreshingCodexWorkspaceUsageFingerprint()
    }
}
