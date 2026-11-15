import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct SpendDashboardProjectlessTests {
    @Test
    func `each category has consecutive ranks and preserves every ledger amount and identity`() throws {
        let group = try Self.group(projects: [
            Self.project(name: "work", path: "/fixtures/work", cost: 30, tokens: 300),
            Self.project(name: "Planning", path: "/fixtures/chat-a", cost: 20, tokens: 200, isProjectless: true),
            Self.project(name: "tools", path: "/fixtures/tools", cost: 10, tokens: 100),
            Self.project(name: "Planning", path: "/fixtures/chat-b", cost: 5, tokens: 50, isProjectless: true),
        ])
        let projects = spendDashboardProjectRows(group.projects, isProjectless: false)
        let chats = spendDashboardProjectRows(group.projects, isProjectless: true)

        #expect(projects.map(\.rank) == [1, 2])
        #expect(chats.map(\.rank) == [1, 2])
        #expect(projects.map(\.path) == ["/fixtures/work", "/fixtures/tools"])
        #expect(chats.map(\.path) == ["/fixtures/chat-a", "/fixtures/chat-b"])
        let allChatsAreProjectless = chats.allSatisfy(\.isProjectless)
        #expect(allChatsAreProjectless)
        let displayed = projects + chats
        #expect(Set(displayed.map(\.id)) == Set(group.projects.map(\.id)))
        #expect(displayed.compactMap(\.totalCost).reduce(0, +) == 65)
        #expect(displayed.compactMap(\.totalTokens).reduce(0, +) == 650)
        for row in displayed {
            let original = try #require(group.projects.first { $0.id == row.id })
            #expect(row.totalCost == original.totalCost)
            #expect(row.totalTokens == original.totalTokens)
            #expect(row.providerName == original.providerName)
        }
        // Display ranking must not mutate the combined ledger ranking.
        #expect(group.projects.map(\.rank) == [1, 2, 3, 4])
        #expect(spendDashboardAvailableDetailSections(hasProjects: true, hasSessions: true, hasChats: true)
            == [.providers, .projects, .chats, .sessions])
    }

    @Test
    func `identical paths require unanimous classification regardless of record order`() throws {
        let chat = Self.project(name: "Planning", path: "/fixtures/shared", cost: 3, tokens: 30, isProjectless: true)
        let project = Self.project(name: "work", path: "/fixtures/shared", cost: 2, tokens: 20)
        for records in [[chat, project], [project, chat]] {
            let rows = try Self.group(projects: records).projects
            let row = try #require(rows.first)
            #expect(rows.count == 1)
            #expect(!row.isProjectless)
            #expect(row.projectName == "work")
            #expect(row.id == "codex-a:path:/fixtures/shared")
            #expect(row.totalCost == 5)
            #expect(row.totalTokens == 50)
        }
        let unanimous = try Self.group(projects: [chat, chat]).projects
        #expect(unanimous.count == 1)
        #expect(unanimous.first?.isProjectless == true)
        #expect(unanimous.first?.totalCost == 6)
    }

    @Test
    func `same named distinct paths remain separate and disambiguate only inside their category`() throws {
        let group = try Self.group(projects: [
            Self.project(name: "Planning", path: "/fixtures/work", cost: 30),
            Self.project(name: "Planning", path: "/fixtures/chat-a", cost: 20, isProjectless: true),
            Self.project(name: "Planning", path: "/fixtures/chat-b", cost: 10, isProjectless: true),
        ])
        #expect(Set(group.projects.map(\.id)).count == 3)
        let projects = spendDashboardProjectRows(group.projects, isProjectless: false)
        let chats = spendDashboardProjectRows(group.projects, isProjectless: true)
        #expect(projects.allSatisfy { !$0.needsPathDisambiguation(in: group.projects) })
        #expect(chats.allSatisfy { $0.needsPathDisambiguation(in: chats) })
        #expect(chats.allSatisfy { $0.displayIdentity(hidePersonalInfo: false).path != nil })
        let renamed = Self.row(name: "A new title", path: "/fixtures/chat-a", isProjectless: true)
        #expect(renamed.id == chats[0].id)
        #expect(Self.row(name: "Planning", path: "/fixtures/chat-a").id == chats[0].id)
    }

    @Test
    func `classification stays scoped to each source even for identical paths`() throws {
        let inputs = [
            Self.input(id: "codex-a", projects: [
                Self.project(name: "Planning", path: "/fixtures/shared", cost: 2, isProjectless: true),
            ]),
            Self.input(id: "codex-b", projects: [
                Self.project(name: "work", path: "/fixtures/shared", cost: 3),
            ]),
        ]
        let group = try #require(Self.model(inputs: inputs).groups.first)
        #expect(group.projects.count == 2)
        #expect(group.projects.first { $0.sourceID == "codex-a" }?.isProjectless == true)
        #expect(group.projects.first { $0.sourceID == "codex-b" }?.isProjectless == false)
        #expect(group.projects.compactMap(\.totalCost).reduce(0, +) == 5)
    }

    @Test
    func `unpriced or incomplete project usage marks only that project as a floor`() throws {
        let rows = try Self.group(projects: [
            Self.project(name: "a", path: "/fixtures/a", cost: 4, tokens: 900, unpricedRequestCount: 2),
            Self.project(name: "b", path: "/fixtures/b", cost: 6, tokens: 100),
        ]).projects
        let a = try #require(rows.first { $0.projectName == "a" })
        let b = try #require(rows.first { $0.projectName == "b" })
        #expect(a.totalCost == 4 && a.costIsLowerBound && !a.tokensAreLowerBound)
        #expect(!b.costIsLowerBound && !b.tokensAreLowerBound)
        // $4 + $6 is not the complete denominator, so the bars compare the complete token counts.
        let shares = spendDashboardProjectShares(rows)
        #expect(shares?.basis == .tokens)
        #expect(shares?.values == [a.id: 0.9, b.id: 0.1])
    }

    @Test
    func `independent chat fallback and privacy labels are localized without exposing paths`() {
        for (language, fallback, maskedChat, maskedProject) in [
            ("en", "Independent chat", "Chat 1", "Project 1"),
            ("zh-Hans", "独立聊天", "聊天 1", "项目 1"),
        ] {
            CodexBarLocalizationOverride.$appLanguage.withValue(language) {
                let chat = Self.row(name: "Private thread title", path: "/fixtures/private", isProjectless: true)
                #expect(chat.displayIdentity(hidePersonalInfo: false).name == "Private thread title")
                #expect(chat.displayIdentity(hidePersonalInfo: true).name == maskedChat)
                #expect(chat.displayIdentity(hidePersonalInfo: true).path == nil)
                #expect(Self.row(name: "work").displayIdentity(hidePersonalInfo: true).name == maskedProject)
                for name in ["Independent chat", "  "] {
                    let row = Self.row(name: name, isProjectless: true)
                    #expect(row.displayIdentity(hidePersonalInfo: false).name == fallback)
                }
                let plural = Self.row(name: "Independent chats", isProjectless: true)
                #expect(plural.displayIdentity(hidePersonalInfo: false).name == L("Independent chats"))
                #expect(plural.displayIdentity(hidePersonalInfo: true).name == maskedChat)
                #expect(SpendDashboardDetailSection.chats.title == (language == "en" ? "Independent chats" : "独立聊天"))
            }
        }
    }

    private static func row(
        name: String,
        path: String = "/fixtures/work",
        isProjectless: Bool = false) -> SpendDashboardModel.ProjectRow
    {
        SpendDashboardModel.ProjectRow(
            rank: 1,
            provider: .codex,
            providerName: "Codex",
            sourceID: "codex-a",
            projectName: name,
            path: path,
            totalTokens: 10,
            totalCost: 1,
            isProjectless: isProjectless)
    }

    private static func project(
        name: String,
        path: String,
        cost: Double?,
        tokens: Int? = 10,
        isProjectless: Bool = false,
        unpricedRequestCount: Int? = nil) -> CostUsageProjectBreakdown
    {
        CostUsageProjectBreakdown(
            name: name,
            path: path,
            totalTokens: tokens,
            totalCostUSD: cost,
            daily: [self.entry(cost: cost, tokens: tokens, unpricedRequestCount: unpricedRequestCount)],
            modelBreakdowns: nil,
            isProjectless: isProjectless)
    }

    private static func entry(
        cost: Double?,
        tokens: Int?,
        unpricedRequestCount: Int? = nil) -> CostUsageDailyReport.Entry
    {
        CostUsageDailyReport.Entry(
            date: "2026-07-16",
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: tokens,
            costUSD: cost,
            modelsUsed: nil,
            modelBreakdowns: nil,
            unpricedRequestCount: unpricedRequestCount)
    }

    private static func input(
        id: String = "codex-a",
        projects: [CostUsageProjectBreakdown]) -> SpendDashboardModel.ProviderInput
    {
        SpendDashboardModel.ProviderInput(
            id: id,
            provider: .codex,
            displayName: "Codex",
            snapshot: CostUsageTokenSnapshot(
                sessionTokens: nil,
                sessionCostUSD: nil,
                last30DaysTokens: nil,
                last30DaysCostUSD: nil,
                historyDays: 30,
                daily: [self.entry(cost: 10, tokens: 100)],
                projects: projects,
                updatedAt: self.now))
    }

    private static func group(projects: [CostUsageProjectBreakdown]) throws -> SpendDashboardModel.CurrencyGroup {
        try #require(self.model(inputs: [self.input(projects: projects)]).groups.first)
    }

    private static func model(inputs: [SpendDashboardModel.ProviderInput]) -> SpendDashboardModel {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return SpendDashboardModel.build(inputs: inputs, requestedDays: 30, now: self.now, calendar: calendar)
    }

    private static let now = Date(timeIntervalSince1970: 1_784_179_200) // 2026-07-16 00:00:00 UTC
}
