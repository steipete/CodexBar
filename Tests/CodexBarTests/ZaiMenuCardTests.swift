import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct ZaiMenuCardTests {
    @Test
    func `zai metrics titles are 5-hour weekly and MCP when session token limit present`() throws {
        let now = Date()
        let details = try ProviderDetailSection(title: "Quota details", rows: [
            .init(label: "Token quota", value: "9% used"),
            .init(label: "Session token quota", value: "75% used", secondaryValue: "1000 limit · 250 remaining"),
            .init(label: "MCP quota", value: "50% used", secondaryValue: "100 limit · 50 remaining"),
        ])
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 75, windowMinutes: 300, resetsAt: nil, resetDescription: "5-hour"),
            secondary: RateWindow(
                usedPercent: 9,
                windowMinutes: 10080,
                resetsAt: nil,
                resetDescription: "1 week window"),
            extraRateWindows: [NamedRateWindow(
                id: "zai-mcp",
                title: "MCP",
                window: RateWindow(usedPercent: 50, windowMinutes: nil, resetsAt: nil, resetDescription: "MCP"))],
            details: [details],
            updatedAt: now,
            identity: ProviderIdentitySnapshot(
                providerID: .zai,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: "pro"))
        let metadata = try #require(ProviderDefaults.metadata[.zai])

        let model = UsageMenuCardView.Model.make(.init(
            provider: .zai,
            metadata: metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        #expect(model.metrics.map(\.title) == ["5-hour", "Weekly", "MCP"])
        let rows = try #require(model.providerDetails.first?.rows)
        let session = try #require(rows.first(where: { $0.label == "Session token quota" }))
        #expect(session.value == "75% used")
        #expect(session.secondaryValue == "1000 limit · 250 remaining")
        let mcp = try #require(rows.first(where: { $0.label == "MCP quota" }))
        #expect(mcp.value == "50% used")
        #expect(mcp.secondaryValue == "100 limit · 50 remaining")
    }
}
