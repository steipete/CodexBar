import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct MenuCardNeuralWattTests {
    @Test
    func `model shows prepaid balance as pay as you go`() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = try await NeuralWattPluginTestSupport.fetch(
            Data(#"""
            {"balance":{"credits_remaining_usd":51,"total_credits_usd":77.04,"credits_used_usd":26.04,
                        "accounting_method":"energy"},
             "usage":{"current_month":{"cost_usd":12.34,"energy_kwh":0.25}}}
            """#.utf8),
            now: now)
        let metadata = try #require(ProviderDefaults.metadata[.neuralwatt])

        let model = UsageMenuCardView.Model.make(.init(
            provider: .neuralwatt,
            metadata: metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
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

        #expect(model.metrics.isEmpty)
        let prepaid = try #require(model.providerCost)
        #expect(prepaid.title == "Pay-as-you-go")
        #expect(prepaid.spendLine.replacingOccurrences(of: "\u{00A0}", with: "") == "Balance: $51.00")
        #expect(model.creditsText == nil)
    }

    @Test
    func `model shows subscription quota and separate prepaid balance`() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let body: [String: Any] = [
            "balance": ["credits_remaining_usd": 0, "total_credits_usd": 0, "accounting_method": "energy"],
            "subscription": [
                "plan": "pro", "status": "active", "billing_interval": "month", "auto_renew": true,
                "current_period_start": ISO8601DateFormatter().string(from: now.addingTimeInterval(-10 * 86400)),
                "current_period_end": ISO8601DateFormatter().string(from: now.addingTimeInterval(20 * 86400)),
                "kwh_included": 10, "kwh_used": 2.5, "kwh_remaining": 7.5, "in_overage": false,
            ],
        ]
        let snapshot = try await NeuralWattPluginTestSupport.fetch(
            JSONSerialization.data(withJSONObject: body), now: now)
        let metadata = try #require(ProviderDefaults.metadata[.neuralwatt])

        let model = UsageMenuCardView.Model.make(.init(
            provider: .neuralwatt,
            metadata: metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: true,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        let primary = try #require(model.metrics.first)
        #expect(primary.title == "Subscription")
        #expect(primary.percent == 25)
        #expect(primary.detailText == "2.50 / 10 kWh")
        #expect(primary.statusText == nil)
        #expect(primary.resetText == "Resets in 20d")
        #expect(model.providerCost?.spendLine.replacingOccurrences(of: "\u{00A0}", with: "") == "Balance: $0.00")
    }
}
