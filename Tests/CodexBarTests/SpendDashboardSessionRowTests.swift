import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct SpendDashboardSessionRowTests {
    @Test
    func `sessions rank by cost and carry thread names and projects`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let sessions = [
            Self.session(id: "cheap", cost: 1, tokens: 10),
            Self.session(id: "unpriced", cost: nil, tokens: 999),
            Self.session(
                id: "expensive",
                cost: 5,
                tokens: 50,
                title: "Fix the icon",
                projectPath: "/Users/example/Projects/example-app"),
        ]
        let model = SpendDashboardModel.build(
            inputs: [Self.sessionInput(sessions: sessions)],
            requestedDays: 90,
            now: Self.now,
            calendar: calendar)

        let rows = try #require(model.groups.first?.sessions)
        #expect(rows.map(\.sessionID) == ["expensive", "cheap", "unpriced"])
        #expect(rows.map(\.rank) == [1, 2, 3])
        #expect(rows[0].title == "Fix the icon")
        #expect(rows[0].projectName == "example-app")
        #expect(rows[0].projectPath == "/Users/example/Projects/example-app")
        #expect(rows[0].providerName == "Codex")
        #expect(rows[1].title == nil)
    }

    @Test
    func `sessions keep the most expensive rows up to the display limit`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let count = SpendDashboardModel.sessionRowLimit + 5
        let sessions = (1...count).map { Self.session(id: "s\($0)", cost: Double($0), tokens: $0) }
        let model = SpendDashboardModel.build(
            inputs: [Self.sessionInput(sessions: sessions)],
            requestedDays: 90,
            now: Self.now,
            calendar: calendar)

        let rows = try #require(model.groups.first?.sessions)
        #expect(rows.count == SpendDashboardModel.sessionRowLimit)
        #expect(rows.first?.sessionID == "s\(count)")
        #expect(rows.last?.sessionID == "s6")
    }

    @Test
    func `session privacy masks thread names and projects but keeps model and date`() {
        let row = SpendDashboardModel.SessionRow(
            id: "codex:019f79b9-1790-7921-8d6f-258a1e92b191",
            rank: 1,
            sessionID: "019f79b9-1790-7921-8d6f-258a1e92b191",
            sourceID: "codex",
            provider: .codex,
            providerName: "Codex",
            title: "private thread name",
            projectName: "private-project",
            projectPath: "/Users/example/Projects/private-project",
            lastActivity: Self.now,
            totalTokens: 10,
            totalCost: 1,
            modelName: "gpt-5.4")
        let date = SpendActivityDateFormatting.mediumDateString(Self.now)
        let masked = L("Session %@", "019f...1e92b191")

        let visible = row.displayIdentity(hidePersonalInfo: false)
        #expect(visible.name == "private thread name")
        #expect(visible.path == "/Users/example/Projects/private-project")
        #expect(row.displaySubtitle(hidePersonalInfo: false) == "private-project · gpt-5.4 · \(date)")

        let hidden = row.displayIdentity(hidePersonalInfo: true)
        #expect(hidden.name == masked)
        #expect(hidden.path == nil)
        #expect(row.displaySubtitle(hidePersonalInfo: true) == "gpt-5.4 · \(date)")
    }

    @Test
    func `untitled sessions fall back to the short session ID`() {
        let row = SpendDashboardModel.SessionRow(
            id: "codex:019f79b9-1790-7921-8d6f-258a1e92b191",
            rank: 1,
            sessionID: "019f79b9-1790-7921-8d6f-258a1e92b191",
            sourceID: "codex",
            provider: .codex,
            providerName: "Codex",
            title: nil,
            projectName: nil,
            projectPath: nil,
            lastActivity: Self.now,
            totalTokens: 10,
            totalCost: 1,
            modelName: nil)

        #expect(row.displayIdentity(hidePersonalInfo: false).name == L("Session %@", "019f...1e92b191"))
        #expect(row.displaySubtitle(hidePersonalInfo: false)
            == SpendActivityDateFormatting.mediumDateString(Self.now))
    }

    private static func sessionInput(sessions: [CostUsageSessionBreakdown]) -> SpendDashboardModel.ProviderInput {
        SpendDashboardModel.ProviderInput(
            id: "codex",
            provider: .codex,
            displayName: "Codex",
            snapshot: CostUsageTokenSnapshot(
                sessionTokens: nil,
                sessionCostUSD: nil,
                last30DaysTokens: nil,
                last30DaysCostUSD: nil,
                currencyCode: "USD",
                historyDays: 90,
                daily: [
                    CostUsageDailyReport.Entry(
                        date: "2026-07-16",
                        inputTokens: nil,
                        outputTokens: nil,
                        totalTokens: 10,
                        costUSD: 1,
                        modelsUsed: nil,
                        modelBreakdowns: nil),
                ],
                sessions: sessions,
                updatedAt: self.now))
    }

    private static func session(
        id: String,
        cost: Double?,
        tokens: Int,
        title: String? = nil,
        projectPath: String? = nil) -> CostUsageSessionBreakdown
    {
        CostUsageSessionBreakdown(
            sessionID: id,
            lastActivity: self.now,
            inputTokens: tokens,
            cachedInputTokens: nil,
            outputTokens: 0,
            totalTokens: tokens,
            requestCount: 1,
            costUSD: cost,
            modelBreakdowns: [],
            projectPath: projectPath,
            projectName: projectPath.map { URL(fileURLWithPath: $0).lastPathComponent },
            title: title)
    }

    private static let now = Date(timeIntervalSince1970: 1_784_179_200) // 2026-07-16 00:00:00 UTC
}
