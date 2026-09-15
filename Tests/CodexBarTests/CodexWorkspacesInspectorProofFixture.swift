import Foundation
@testable import CodexBar
@testable import CodexBarCore

enum CodexWorkspacesInspectorProofFixture {
    static func snapshot(
        for configuration: CodexWorkspacesInspectorModel.Configuration) -> CodexLocalProjectUsageSnapshot
    {
        let rows: [(id: String, name: String, tokens: Int)] = if configuration.codexHomePath?
            .hasSuffix("second-profile") == true
        {
            [("harbor", "Harbor demo", 2900)]
        } else if configuration.historyDays <= 7 {
            [("atlas", "Atlas demo", 1000)]
        } else {
            [("atlas", "Atlas demo", 8000), ("borealis", "Borealis demo", 3000)]
        }
        let now = Date(timeIntervalSince1970: 1_789_257_600)
        let sessions = rows.map { row in
            CodexLocalSessionUsage(
                id: "session-\(row.id)",
                projectId: row.id,
                displayTitle: "Build \(row.name)",
                cwd: "/Demo/\(row.name)",
                startedAt: now,
                latestActivity: now,
                totals: self.totals(row.tokens),
                costEstimate: .init(knownUSD: Double(row.tokens) / 10000),
                topModel: "gpt-4.1",
                daily: [self.day(row.tokens)])
        }
        let projects = zip(rows, sessions).map { row, session in
            CodexLocalProjectUsage(
                id: row.id,
                displayName: row.name,
                path: session.cwd,
                totals: session.totals,
                costEstimate: session.costEstimate,
                sessionCount: 1,
                latestActivity: now,
                topModel: session.topModel,
                topSessions: [session],
                modelBreakdowns: [],
                daily: session.daily)
        }
        let total = rows.reduce(0) { $0 + $1.tokens }
        return CodexLocalProjectUsageSnapshot(
            updatedAt: now,
            historyDays: configuration.historyDays,
            scopeSignature: configuration.scopeSignature,
            rootsFingerprint: [:],
            indexedFileCount: sessions.count,
            skippedFileCount: 0,
            total: self.totals(total),
            projects: projects,
            sessions: sessions,
            daily: [self.day(total)])
            .hidingPersonalInformation(configuration.hidePersonalInfo)
    }

    private static func totals(_ count: Int) -> CodexLocalUsageTotals {
        .init(inputTokens: count, cachedInputTokens: 0, outputTokens: 0, totalTokens: count)
    }

    private static func day(_ count: Int) -> CodexLocalUsageDailyPoint {
        .init(day: "2026-09-12", totalTokens: count, estimatedCostUSD: Double(count) / 10000)
    }
}
