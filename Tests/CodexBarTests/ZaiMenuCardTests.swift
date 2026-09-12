import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct ZaiMenuCardTests {
    @MainActor
    @Test
    func `submenu only hides zai inline cost summary details`() throws {
        let model = try Self.costSummaryModel(style: .costSubmenu)

        #expect(model.providerDetails.map(\.title) == ["Quota details"])
    }

    @MainActor
    @Test
    func `inline style keeps zai inline cost summary details`() throws {
        let model = try Self.costSummaryModel(style: .inlineSummary)

        #expect(model.providerDetails.map(\.title) == ["Quota details", "Hourly tokens", "Daily tokens"])
    }

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

    @MainActor
    @Test
    func `model localizes zai usage sections in simplified chinese`() throws {
        let model = try CodexBarLocalizationOverride.$appLanguage.withValue("zh-Hans") {
            try Self.costSummaryModel(style: .inlineSummary)
        }

        #expect(model.providerDetails.map(\.title) == ["配额详情", "每小时 token", "每日 token"])
        #expect(model.providerDetails[0].rows[0].label == "Token 配额")
        #expect(model.providerDetails[0].rows[0].value == "已使用 3%")
        #expect(model.providerDetails[1].rows[0].label == "GLM-5.3")
        #expect(model.providerDetails[1].chart?.title == "每小时 token")
        #expect(model.providerDetails[1].chart?.unit == "token")
    }

    @Test
    func `model localizes zai quota values and periodic reset in simplified chinese`() throws {
        let now = Date()
        let details = try ProviderDetailSection(title: "Quota details", rows: [
            .init(label: "Token quota", value: "45% used"),
            .init(label: "Session token quota", value: "0% used"),
            .init(label: "MCP quota", value: "6.4% used", secondaryValue: "1000 limit · 936 remaining"),
            .init(label: "Credit quota", value: "12% used", secondaryValue: "1000 limit"),
            .init(label: "Session credit quota", value: "13% used", secondaryValue: "936 remaining"),
            .init(label: "Quota rate", value: "Peak", secondaryValue: "off-peak in 2h 30m"),
            .init(label: "Quota rate", value: "Off-peak", secondaryValue: "peak now"),
            .init(label: "search-prime", value: "64"),
        ])
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 0, windowMinutes: 300, resetsAt: nil, resetDescription: "5-hour"),
            secondary: RateWindow(
                usedPercent: 45,
                windowMinutes: 10080,
                resetsAt: now.addingTimeInterval(3 * 24 * 60 * 60),
                resetDescription: nil),
            extraRateWindows: [NamedRateWindow(
                id: "zai-mcp",
                title: "MCP",
                window: RateWindow(usedPercent: 6.4, windowMinutes: nil, resetsAt: nil, resetDescription: "MCP"))],
            details: [details],
            updatedAt: now,
            identity: ProviderIdentitySnapshot(
                providerID: .zai,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: "Pro"))
        let metadata = try #require(ProviderDefaults.metadata[.zai])

        let model = CodexBarLocalizationOverride.$appLanguage.withValue("zh-Hans") {
            UsageMenuCardView.Model.make(.init(
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
        }

        #expect(model.metrics.first?.title == "5 小时")
        #expect(model.metrics.first?.resetText == "每 5 小时重置")
        let rows = try #require(model.providerDetails.first?.rows)
        #expect(rows[0].value == "已使用 45%")
        #expect(rows[1].label == "会话 Token 配额")
        #expect(rows[1].value == "已使用 0%")
        #expect(rows[2].label == "MCP 配额")
        #expect(rows[2].value == "已使用 6.4%")
        #expect(rows[2].secondaryValue == "上限 1000 · 剩余 936")
        #expect(rows[3].label == "额度配额")
        #expect(rows[3].secondaryValue == "上限 1000")
        #expect(rows[4].label == "会话额度配额")
        #expect(rows[4].secondaryValue == "剩余 936")
        #expect(rows[5].label == "配额费率")
        #expect(rows[5].value == "高峰")
        #expect(rows[5].secondaryValue == "非高峰 2 小时 30 分钟后")
        #expect(rows[6].value == "非高峰")
        #expect(rows[6].secondaryValue == "高峰 现在")
        #expect(rows[7].label == "search-prime")
    }

    @MainActor
    private static func costSummaryModel(style: CostSummaryDisplayStyle) throws -> UsageMenuCardView.Model {
        let settings = testSettingsStore(suiteName: "ZaiMenuCardTests-cost-summary-\(style.rawValue)")
        settings.costUsageEnabled = true
        settings.costSummaryDisplayStyle = style
        let now = Date()
        let details = try [
            ProviderDetailSection(
                title: "Quota details",
                rows: [.init(label: "Token quota", value: "3% used")]),
            ProviderDetailSection(
                title: "Hourly tokens",
                rows: [.init(label: "GLM-5.3", value: "18002346")],
                chart: .init(
                    kind: .bars,
                    title: "Hourly tokens",
                    unit: "tokens",
                    points: [.init(label: "2026-08-16 10:00", value: 18_002_346)])),
            ProviderDetailSection(
                title: "Daily tokens",
                rows: [.init(label: "GLM-5.3", value: "20883920")],
                chart: .init(
                    kind: .bars,
                    title: "Daily tokens",
                    unit: "tokens",
                    points: [.init(label: "2026-08-16", value: 20_883_920)])),
        ]
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 3, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            details: details,
            updatedAt: now,
            identity: ProviderIdentitySnapshot(
                providerID: .zai,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: "Pro"))
        let metadata = try #require(ProviderDefaults.metadata[.zai])

        return UsageMenuCardView.Model.make(.init(
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
            usageBarsShowUsed: true,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            costSummaryInlineEnabled: settings.costSummaryShowsInline(for: .zai),
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))
    }
}
