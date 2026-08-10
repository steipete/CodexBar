#if canImport(JavaScriptCore)
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct Sub2APIMenuCardModelTests {
    @Test
    func `subscription amounts share the percentage row`() async throws {
        let now = Date(timeIntervalSince1970: 1_720_440_000)
        let json = """
        {
          "mode": "unrestricted",
          "subscription": {
            "daily_usage_usd": 12,
            "weekly_usage_usd": 70,
            "monthly_usage_usd": 280,
            "daily_limit_usd": 120,
            "weekly_limit_usd": 700,
            "monthly_limit_usd": 2800
          }
        }
        """
        let snapshot = try await Self.snapshot(json, now: now)
        let metadata = try #require(ProviderDefaults.metadata[.sub2api])

        let model = UsageMenuCardView.Model.make(.init(
            provider: .sub2api,
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

        let primary = try #require(model.metrics.first { $0.id == "primary" })
        let secondary = try #require(model.metrics.first { $0.id == "secondary" })
        let tertiary = try #require(model.metrics.first { $0.id == "tertiary" })

        #expect(primary.resetText == "$12.00 / $120.00")
        #expect(primary.title == "Daily quota")
        #expect(primary.detailText == nil)
        #expect(secondary.resetText == "$70.00 / $700.00")
        #expect(secondary.detailText == nil)
        #expect(tertiary.resetText == "$280.00 / $2,800.00")
        #expect(tertiary.detailText == nil)
    }

    @Test
    func `plan balance and per key totals render without overloading identity`() async throws {
        let now = Date(timeIntervalSince1970: 1_720_440_000)
        let json = """
        {
          "mode": "unrestricted",
          "planName": "Enterprise",
          "balance": 42.5,
          "unit": "USD",
          "usage": {
            "today": { "requests": 4, "total_tokens": 1200, "actual_cost": 1.25 },
            "total": { "requests": 40, "total_tokens": 12000, "actual_cost": 25 }
          }
        }
        """
        let snapshot = try await Self.snapshot(json, now: now)
        let metadata = try #require(ProviderDefaults.metadata[.sub2api])

        let model = UsageMenuCardView.Model.make(.init(
            provider: .sub2api,
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

        #expect(model.planText == "Enterprise")
        #expect(model.usageNotes.isEmpty)
        let usage = try #require(model.providerDetails.first)
        #expect(usage.title == "Usage")
        #expect(usage.rows.map(\.label) == ["Balance", "Today", "Total"])
        #expect(usage.rows[1].value == "4 requests")
        #expect(usage.rows[1].secondaryValue == "1,200 tokens · Cost: $1.25")
        #expect(usage.rows[2].value == "40 requests")
        #expect(usage.rows[2].secondaryValue == "12,000 tokens · Cost: $25.00")
    }

    @Test
    func `usage summary and quota labels follow the selected language`() async throws {
        let now = Date(timeIntervalSince1970: 1_720_440_000)
        let json = """
        {
          "mode": "unrestricted",
          "subscription": {
            "daily_usage_usd": 12,
            "weekly_usage_usd": 70,
            "monthly_usage_usd": 280,
            "daily_limit_usd": 120,
            "weekly_limit_usd": 700,
            "monthly_limit_usd": 2800
          },
          "usage": {
            "today": { "requests": 4, "total_tokens": 1200, "actual_cost": 1.25 },
            "total": { "requests": 40, "total_tokens": 12000, "actual_cost": 25 }
          }
        }
        """
        let snapshot = try await Self.snapshot(json, now: now)
        let metadata = try #require(ProviderDefaults.metadata[.sub2api])

        let model = CodexBarLocalizationOverride.$appLanguage.withValue("zh-Hans") {
            UsageMenuCardView.Model.make(.init(
                provider: .sub2api,
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

        #expect(model.metrics.map(\.title) == ["每日配额", "每周", "每月"])
        let usage = try #require(model.providerDetails.first)
        #expect(usage.title == "用量")
        #expect(usage.rows.map(\.label) == ["余额", "今天", "总计"])
        #expect(usage.rows[1].value == "4 请求")
        #expect(usage.rows[1].secondaryValue == "1,200 token · 费用: $1.25")
    }

    @Test
    func `extra window amount renders as detail instead of reset`() async throws {
        let now = Date(timeIntervalSince1970: 1_720_440_000)
        let json = """
        {
          "mode": "quota_limited",
          "rate_limits": [
            {
              "window": "7d",
              "limit": 200,
              "used": 40,
              "remaining": 160
            }
          ]
        }
        """
        let snapshot = try await Self.snapshot(json, now: now)
        let metadata = try #require(ProviderDefaults.metadata[.sub2api])

        let model = UsageMenuCardView.Model.make(.init(
            provider: .sub2api,
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

        let weekly = try #require(model.metrics.first { $0.id == "7d" })
        #expect(weekly.resetText == nil)
        #expect(weekly.detailText == "$40.00 / $200.00")
    }

    private static func snapshot(_ body: String, now: Date) async throws -> UsageSnapshot {
        let runtime = try ProviderPluginRuntime(
            bundledPlugin: "sub2api",
            transport: ProviderHTTPTransportHandler { request in
                let response = try #require(HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]))
                return (Data(body.utf8), response)
            })
        return try await runtime.fetchUsage(
            settings: [Sub2APISettingsReader.baseURLEnvironmentKey: "https://api.example.com"],
            secrets: [Sub2APISettingsReader.apiKeyEnvironmentKey: "fixture-key"],
            now: now)
    }
}
#endif
