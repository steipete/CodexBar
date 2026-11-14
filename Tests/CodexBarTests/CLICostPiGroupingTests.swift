import CodexBarCore
import Foundation
import Testing
@testable import CodexBarCLI

struct CLICostPiGroupingTests {
    @Test
    func `renders pi session grouped cost text`() {
        let sessionDate = Date(timeIntervalSince1970: 1_750_000_000)
        let snapshot = Self.snapshot(sessions: [
            CostUsageSessionBreakdown(
                sessionID: "2f9c1d4e-7a3b-4c6d-9e8f-0a1b2c3d4e5f",
                lastActivity: sessionDate,
                inputTokens: 1200,
                cachedInputTokens: 200,
                outputTokens: 300,
                totalTokens: 1500,
                requestCount: 4,
                costUSD: 1.5,
                modelBreakdowns: [.init(modelName: "gpt-5.4", costUSD: 1.5, totalTokens: 1500)],
                projectPath: "/Users/test/projects/alpha",
                projectName: "alpha",
                title: "Refactor parser"),
        ])

        let output = CodexBarCLI.renderCostText(provider: .pi, snapshot: snapshot, groupBy: .session, useColor: false)
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "$ ", with: "$")

        #expect(output.hasPrefix("Pi Cost (API-rate estimate)\n"))
        #expect(output.contains("Conversations (Last 30 days):"))
        #expect(output.contains("Session 2f9c...2c3d4e5f: $1.50 · 1.5K tokens · 4 requests"))
        #expect(output.contains(UsageFormatter.costEstimateHint(provider: .pi)))
        #expect(!output.contains("Not a subscription bill or plan value"))
    }

    @Test
    func `renders pi project grouped cost text`() {
        let snapshot = Self.snapshot(projects: [
            CostUsageProjectBreakdown(
                name: "alpha",
                path: "/Users/test/projects/alpha",
                totalTokens: 7000,
                totalCostUSD: 7.5,
                daily: [],
                modelBreakdowns: nil),
            CostUsageProjectBreakdown(
                name: CostUsageProjectBreakdown.unknownProjectName,
                path: nil,
                totalTokens: 2000,
                totalCostUSD: nil,
                daily: [],
                modelBreakdowns: nil),
        ])

        let output = CodexBarCLI.renderCostText(provider: .pi, snapshot: snapshot, groupBy: .project, useColor: false)
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "$ ", with: "$")

        #expect(output.hasPrefix("Pi Cost (API-rate estimate)\n"))
        #expect(output.contains("Projects (Last 30 days):"))
        #expect(output.contains("alpha: $7.50 · 7K tokens\n  /Users/test/projects/alpha"))
        #expect(output.contains("Unknown project: — · 2K tokens"))
        #expect(!output.contains("  - "))
        #expect(output.hasSuffix(UsageFormatter.costEstimateHint(provider: .pi)))
    }

    @Test
    func `pi cost payload includes project rollups without sessions`() throws {
        let snapshot = Self.snapshot(
            projects: [
                CostUsageProjectBreakdown(
                    name: "alpha",
                    path: "/Users/test/projects/alpha",
                    totalTokens: 40,
                    totalCostUSD: 0.04,
                    daily: [],
                    modelBreakdowns: nil),
            ],
            sessions: [
                CostUsageSessionBreakdown(
                    sessionID: "alpha-session",
                    lastActivity: Date(timeIntervalSince1970: 1_750_000_000),
                    inputTokens: 30,
                    cachedInputTokens: nil,
                    outputTokens: 10,
                    totalTokens: 40,
                    requestCount: 2,
                    costUSD: 0.04,
                    modelBreakdowns: []),
            ])

        let payload = CodexBarCLI.makeCostPayload(provider: .pi, snapshot: snapshot, error: nil)
        #expect(payload.projects.map(\.name) == ["alpha"])
        #expect(payload.projects.first?.path == "/Users/test/projects/alpha")
        #expect(payload.projects.first?.sources.isEmpty == true)
        let json = try #require(String(data: JSONEncoder().encode(payload), encoding: .utf8))
        #expect(json.contains("\"projects\""))
        #expect(!json.contains("\"sessions\""))
    }

    @Test
    func `native session grouping omission warning is skipped when pi is selected`() {
        for provider in [UsageProvider.codex, .claude] {
            #expect(CodexBarCLI.sessionGroupingPiOmissionWarning(
                provider: provider,
                selectedProviders: [provider],
                groupBy: .session,
                format: .text,
                includePiSessions: true) != nil)
            #expect(CodexBarCLI.sessionGroupingPiOmissionWarning(
                provider: provider,
                selectedProviders: [provider, .pi],
                groupBy: .session,
                format: .text,
                includePiSessions: true) == nil)
        }
    }

    @Test
    func `standalone pi session grouping never warns about omitted pi usage`() {
        #expect(CodexBarCLI.sessionGroupingPiOmissionWarning(
            provider: .pi,
            selectedProviders: [.pi],
            groupBy: .session,
            format: .text,
            includePiSessions: true) == nil)
    }

    private static func snapshot(
        projects: [CostUsageProjectBreakdown] = [],
        sessions: [CostUsageSessionBreakdown] = []) -> CostUsageTokenSnapshot
    {
        CostUsageTokenSnapshot(
            sessionTokens: 1500,
            sessionCostUSD: 1.5,
            last30DaysTokens: 9000,
            last30DaysCostUSD: 9.5,
            historyDays: 30,
            daily: [],
            projects: projects,
            sessions: sessions,
            updatedAt: Date(timeIntervalSince1970: 0))
    }
}
