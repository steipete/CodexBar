import Foundation
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

struct CLICostProjectCoverageTests {
    @Test(arguments: [false, true])
    func `project text labels incomplete coverage with or without project rows`(hasProjects: Bool) {
        let snapshot = Self.snapshot(
            hasProjects: hasProjects,
            coverageEstablished: false).reporting(.allTime)

        let output = Self.render(snapshot)

        #expect(output.contains(Self.partialHistoryMessage))
        #expect(output.contains("Projects (All):"))
        if hasProjects {
            #expect(output.contains(Self.projectLines))
        } else {
            #expect(!output.contains("client-a:"))
        }
    }

    @Test
    func `project text labels a partial read after coverage was established`() {
        let snapshot = Self.snapshot(
            hasProjects: true,
            coverageEstablished: true,
            scanIsPartial: true)

        let output = Self.render(snapshot)

        #expect(output.contains(Self.partialHistoryMessage))
        #expect(output.contains(Self.projectLines))
    }

    @Test
    func `complete project text preserves amounts paths and source rows`() {
        let output = Self.render(Self.snapshot(hasProjects: true, coverageEstablished: true))

        #expect(output == """
        Codex API-equivalent estimate (not billed)
        Projects (Last 30 days):
        \(Self.projectLines)
        Not a subscription bill or plan value · local usage × public API prices
        """)
    }

    @Test
    func `complete empty project text preserves its dash`() {
        let output = Self.render(Self.snapshot(hasProjects: false, coverageEstablished: true))

        #expect(output == """
        Codex API-equivalent estimate (not billed)
        Projects (Last 30 days):
        —
        Not a subscription bill or plan value · local usage × public API prices
        """)
    }

    @Test
    func `claude project text uses the claude header and hint`() {
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: 3000,
            last30DaysCostUSD: 3.0,
            historyDays: 30,
            historyCoverageIsEstablished: true,
            daily: [],
            projects: [
                Self.claudeProject(name: "alpha", path: "/Users/test/projects/alpha", tokens: 2000, cost: 2.0),
                Self.claudeProject(
                    name: CostUsageProjectBreakdown.unknownProjectName, path: nil, tokens: 1000, cost: 1.0),
            ],
            updatedAt: Date(timeIntervalSince1970: 0))

        let output = CodexBarCLI.renderCostText(
            provider: .claude,
            snapshot: snapshot,
            groupBy: .project,
            useColor: false)
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "$ ", with: "$")

        #expect(output == """
        Claude Cost (API-rate estimate)
        Projects (Last 30 days):
        alpha: $2.00 \u{B7} 2K tokens
          /Users/test/projects/alpha
        Unknown project: $1.00 \u{B7} 1K tokens
        Estimated from local Claude logs at API rates; token totals include cache read/write tokens and may \
        differ from Claude Code /status.
        """)
    }

    private static func claudeProject(
        name: String,
        path: String?,
        tokens: Int,
        cost: Double) -> CostUsageProjectBreakdown
    {
        CostUsageProjectBreakdown(
            name: name,
            path: path,
            totalTokens: tokens,
            totalCostUSD: cost,
            daily: [],
            modelBreakdowns: nil,
            sources: [CostUsageProjectSourceBreakdown(
                name: name,
                path: path,
                totalTokens: tokens,
                totalCostUSD: cost,
                daily: [],
                modelBreakdowns: nil)])
    }

    private static let partialHistoryMessage = "Partial local history · recorded token subtotal"

    private static let projectLines = """
    client-a: $7.50 · 7K tokens
      /synthetic/client-a
      - client-a: $5.25 · 5K tokens
        /synthetic/client-a
      - client-a: $2.25 · 2K tokens
        /synthetic/worktrees/abcd/client-a
    """

    private static func render(_ snapshot: CostUsageTokenSnapshot) -> String {
        CodexBarCLI.renderCostText(
            provider: .codex,
            snapshot: snapshot,
            groupBy: .project,
            useColor: false)
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "$ ", with: "$")
    }

    private static func snapshot(
        hasProjects: Bool,
        coverageEstablished: Bool,
        scanIsPartial: Bool = false) -> CostUsageTokenSnapshot
    {
        CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: hasProjects ? 7000 : nil,
            last30DaysCostUSD: hasProjects ? 7.5 : nil,
            historyDays: 30,
            historyCoverageIsEstablished: coverageEstablished,
            historyScanIsPartial: scanIsPartial,
            daily: [],
            projects: hasProjects ? [CostUsageProjectBreakdown(
                name: "client-a",
                path: "/synthetic/client-a",
                totalTokens: 7000,
                totalCostUSD: 7.5,
                daily: [],
                modelBreakdowns: nil,
                sources: [
                    CostUsageProjectSourceBreakdown(
                        name: "client-a",
                        path: "/synthetic/client-a",
                        totalTokens: 5000,
                        totalCostUSD: 5.25,
                        daily: [],
                        modelBreakdowns: nil),
                    CostUsageProjectSourceBreakdown(
                        name: "client-a",
                        path: "/synthetic/worktrees/abcd/client-a",
                        totalTokens: 2000,
                        totalCostUSD: 2.25,
                        daily: [],
                        modelBreakdowns: nil),
                ])] : [],
            updatedAt: Date(timeIntervalSince1970: 0))
    }
}
