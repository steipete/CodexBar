import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct MiniMaxUsageSummaryPresentationTests {
    private static let now = ISO8601DateFormatter().date(from: "2026-11-08T04:00:00Z")!

    @Test
    func `web token counts use generic details and honor the optional usage setting`() throws {
        let snapshot = try self.snapshot()
        let shown = try self.model(snapshot: snapshot, showOptionalUsage: true)
        let section = try #require(shown.providerDetails.first { $0.title == "Tokens" })

        #expect(section.rows.contains { $0.label == "Today tokens" && $0.value == 1200.formatted() })
        #expect(section.rows.contains { $0.label == "30d tokens" && $0.value == 1400.formatted() })
        #expect(section.rows.contains {
            $0.label == "Cache read tokens" && $0.value == 400.formatted()
                && $0.secondaryValue == "Included in input tokens"
        })
        #expect(section.chart?.points.map(\.value) == [200, 1200])
        #expect(shown.inlineUsageDashboard == nil)

        let hidden = try self.model(snapshot: snapshot, showOptionalUsage: false)
        #expect(hidden.providerDetails.allSatisfy { $0.title != "Tokens" })
        #expect(!hidden.metrics.isEmpty)
    }

    @Test(arguments: [false, true], [false, true])
    func `historical token visibility preserves quota details`(optionalUsage: Bool, inline: Bool) throws {
        let snapshot = try self.snapshot()
        let model = try self.model(
            snapshot: snapshot,
            showOptionalUsage: optionalUsage,
            costSummaryInlineEnabled: inline)

        #expect(model.providerDetails.contains { $0.title == "Tokens" } == (optionalUsage && inline))
        let quota = try #require(model.providerDetails.first { $0.title == "Quota services" })
        #expect(quota.rows.count == 1)
        #expect(!model.metrics.isEmpty)
        #expect(snapshot.toUsageSnapshot().details.contains { $0.title == "Tokens" })
    }

    @Test
    func `snapshot enrichment preserves token statistics without adding estimated cost`() throws {
        let snapshot = try self.snapshot()
        let summary = try #require(snapshot.usageSummary)
        #expect(snapshot.withBillingSummary(nil).usageSummary == summary)
        #expect(snapshot.withPlanNameIfMissing("Plus").usageSummary == summary)
        #expect(snapshot.withSubscriptionMetadata(.init(
            planName: "Plus",
            subscriptionExpiresAt: nil,
            subscriptionRenewsAt: nil)).usageSummary == summary)
        #expect(snapshot.toUsageSnapshot().providerCost == nil)
        #expect(snapshot.toUsageSnapshot().details.contains { $0.title == "Tokens" })
    }

    private func snapshot() throws -> MiniMaxUsageSnapshot {
        let summary = try MiniMaxUsageSummaryParser.parse(data: Data("""
        {"base_resp":{"status_code":0},"last_update_time":"11-08 12:00",
         "date_model_usage":[
          {"date":"2026-11-07","total_token":200},
          {"date":"2026-11-08","total_token":1200,"total_input_token":1000,
           "total_output_token":200,"total_cache_read_token":400,"total_cache_create_token":0}]}
        """.utf8), now: Self.now)
        return MiniMaxUsageSnapshot(
            planName: nil,
            availablePrompts: nil,
            currentPrompts: nil,
            remainingPrompts: nil,
            windowMinutes: 300,
            usedPercent: 4,
            resetsAt: nil,
            updatedAt: Self.now,
            services: [MiniMaxServiceUsage(
                serviceType: "general",
                windowType: "5 hours",
                timeRange: "2026-11-08",
                usage: 4,
                limit: 100,
                percent: 4,
                resetsAt: nil,
                resetDescription: "Fixture reset")],
            usageSummary: summary)
    }

    private func model(
        snapshot: MiniMaxUsageSnapshot,
        showOptionalUsage: Bool,
        costSummaryInlineEnabled: Bool = true) throws -> UsageMenuCardView.Model
    {
        let metadata = try #require(ProviderDefaults.metadata[.minimax])
        return UsageMenuCardView.Model.make(.init(
            provider: .minimax,
            metadata: metadata,
            snapshot: snapshot.toUsageSnapshot(),
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
            costSummaryInlineEnabled: costSummaryInlineEnabled,
            showOptionalCreditsAndExtraUsage: showOptionalUsage,
            hidePersonalInfo: false,
            now: Self.now))
    }
}
