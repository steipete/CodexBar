import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct ClaudeWeeklyProductBreakdownTests {
    /// Redacted `seven_day_breakdown` from a claude.ai `/api/organizations/{org}/usage` response (Max plan).
    static let fixture = #"""
    {"as_of":"2026-11-23T21:18:29.513999+00:00","window_started_at":"2026-11-17T10:00:00.494918+00:00",
     "rows":[{"key":"claude_code","display_name":"Claude Code","percent":96,"percent_of_limit":68},
             {"key":"chat","display_name":"Chats","percent":1,"percent_of_limit":1},
             {"key":"cowork","display_name":"Cowork","percent":3,"percent_of_limit":2},
             {"key":"other","display_name":"Other","percent":0,"percent_of_limit":0}]}
    """#

    @Test
    func `web and OAuth decode the same weekly product shares`() throws {
        let data = Self.usageData(Self.fixture)
        let web = try ClaudeWebAPIFetcher._parseUsageResponseForTesting(data)
        let oauth = try ClaudeUsageFetcher._mapOAuthUsageForTesting(data)
        let breakdown = try #require(web.weeklyProductBreakdown)
        #expect(oauth.weeklyProductBreakdown == breakdown)
        #expect(breakdown.products.map(\.key) == ["claude_code", "chat", "cowork", "other"])
        #expect(breakdown.products.map(\.sharePercent) == [96, 1, 3, 0])
        #expect(web.weeklyPercentUsed == 71)
    }

    @Test
    func `nonzero shares become one detail section sorted by share`() throws {
        let section = try #require(Self.snapshot(Self.fixture).details.first { $0.title == "Usage breakdown" })
        #expect(section.rows.map(\.label) == ["Claude Code", "Cowork", "Chats"])
        #expect(section.rows.map(\.value) == ["96%", "3%", "1%"])
        #expect(section.rows.map(\.id) == ["claude_code", "cowork", "chat"].map { "claude.product.\($0)" })
    }

    @Test
    func `a missing display name falls back to the product key`() throws {
        let block = #"{"rows":[{"key":"claude_code","percent":100},{"key":"chat","display_name":" ","percent":0}]}"#
        let breakdown = try #require(ClaudeWebAPIFetcher._parseUsageResponseForTesting(Self.usageData(block))
            .weeklyProductBreakdown)
        #expect(breakdown.products.map(\.name) == ["claude_code", "chat"])
    }

    @Test(arguments: [
        nil, "null", "{}", "[]", #"{"rows":null}"#, #"{"rows":{}}"#,
        #"{"rows":[]}"#,
        #"{"rows":[{"display_name":"Chats","percent":100}]}"#,
        #"{"rows":[{"key":" ","display_name":"Chats","percent":100}]}"#,
        #"{"rows":[{"key":"chat","display_name":"Chats","percent":"100"}]}"#,
        #"{"rows":[{"key":"chat","display_name":"Chats","percent":true}]}"#,
        #"{"rows":[{"key":"chat","display_name":"Chats","percent":101}]}"#,
        #"{"rows":[{"key":"chat","percent":104},{"key":"cowork","percent":-4}]}"#,
        #"{"rows":[{"key":"chat","percent":60},{"key":"cowork","percent":30}]}"#,
        #"{"rows":[{"key":"chat","percent":0},{"key":"cowork","percent":0}]}"#,
    ] as [String?])
    func `absent or malformed breakdowns leave the weekly window alone`(block: String?) throws {
        let data = Self.usageData(block)
        let web = try ClaudeWebAPIFetcher._parseUsageResponseForTesting(data)
        let oauth = try ClaudeUsageFetcher._mapOAuthUsageForTesting(data)
        #expect(web.weeklyProductBreakdown == nil)
        #expect(oauth.weeklyProductBreakdown == nil)
        #expect(web.weeklyPercentUsed == 71)
        #expect(oauth.secondary?.usedPercent == 71)
        #expect(try !Self.snapshot(block).details.contains { $0.title == "Usage breakdown" })
    }

    @Test
    func `shares are not shown without the weekly window they split`() throws {
        let usage = try ClaudeUsageFetcher._mapOAuthUsageForTesting(Self.usageData(Self.fixture))
        let snapshot = ClaudeOAuthFetchStrategy._snapshotForTesting(from: ClaudeUsageSnapshot(
            primary: usage.primary,
            secondary: nil,
            opus: nil,
            weeklyProductBreakdown: usage.weeklyProductBreakdown,
            updatedAt: usage.updatedAt,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: nil,
            rawText: nil))
        #expect(snapshot.details.isEmpty)
    }

    @MainActor
    @Test
    func `menu card lists the shares beneath the weekly bar`() throws {
        let now = Date(timeIntervalSince1970: 1_795_468_709)
        let model = try Self.menuModel(snapshot: Self.snapshot(Self.fixture), now: now)
        #expect(model.metrics.map(\.id).contains("secondary"))
        let section = try #require(model.providerDetails.first)
        #expect(model.providerDetails.count == 1)
        #expect(section.title == "Usage breakdown")
        #expect(section.rows.map(\.value) == ["96%", "3%", "1%"])
    }

    static func usageData(_ block: String?) -> Data {
        let field = block.map { #", "seven_day_breakdown": \#($0)"# } ?? ""
        return Data(#"""
        {"five_hour":{"utilization":7,"resets_at":"2026-11-24T01:00:00.000000+00:00"},
         "seven_day":{"utilization":71,"resets_at":"2026-11-24T10:00:00.000000+00:00"}\#(field)}
        """#.utf8)
    }

    static func snapshot(_ block: String?) throws -> UsageSnapshot {
        let usage = try ClaudeWebAPIFetcher._parseUsageResponseForTesting(Self.usageData(block))
        let updatedAt = Date(timeIntervalSince1970: 1_795_468_709)
        return ClaudeOAuthFetchStrategy._snapshotForTesting(from: ClaudeUsageSnapshot(
            primary: usage.sessionPercentUsed.map {
                RateWindow(usedPercent: $0, windowMinutes: 300, resetsAt: usage.sessionResetsAt, resetDescription: nil)
            },
            secondary: usage.weeklyPercentUsed.map {
                RateWindow(usedPercent: $0, windowMinutes: 10080, resetsAt: usage.weeklyResetsAt, resetDescription: nil)
            },
            opus: nil,
            weeklyProductBreakdown: usage.weeklyProductBreakdown,
            updatedAt: updatedAt,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: "Max",
            rawText: nil))
    }

    @MainActor
    static func menuModel(snapshot: UsageSnapshot, now: Date) throws -> UsageMenuCardView.Model {
        try UsageMenuCardView.Model.make(.init(
            provider: .claude,
            metadata: #require(ProviderDefaults.metadata[.claude]),
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: "Max"),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: true,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: true,
            usesLiveSubtitle: false,
            now: now))
    }
}
