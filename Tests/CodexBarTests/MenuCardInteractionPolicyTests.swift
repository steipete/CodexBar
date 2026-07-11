import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct MenuCardInteractionPolicyTests {
    @Test
    func `cursor request details become scrollable after the visible threshold`() throws {
        let now = Date()
        let requests = (0..<8).map { index in
            CursorRecentRequest(
                timestamp: now.addingTimeInterval(Double(-index)),
                model: "gpt-5.5",
                tokens: 1000,
                requests: 1)
        }
        let summary = CursorRangeUsageSummary(
            rangeKind: .billingCycle,
            range: CursorRecentRequestRange(start: now.addingTimeInterval(-3600), end: now),
            tokens: 8000,
            requests: 8,
            requestCostSummary: nil,
            recentRequests: requests)
        let snapshot = UsageSnapshot(primary: nil, secondary: nil, cursorRangeSummaries: [summary], updatedAt: now)
        let metadata = try #require(ProviderDefaults.metadata[.cursor])
        let model = UsageMenuCardView.Model.make(.init(
            provider: .cursor,
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

        #expect(StatusItemController.menuCardInteractionPolicy(for: model) == .scrollableContent)
    }

    @Test
    func `expanded cursor request details remain scrollable for one row`() throws {
        let now = Date()
        let request = CursorRecentRequest(
            timestamp: now,
            model: "claude-3-7-sonnet",
            tokens: 1000,
            requests: 1,
            tokenBreakdown: CursorRecentRequestTokenBreakdown(
                inputTokens: 400,
                outputTokens: 300,
                cacheReadTokens: 200,
                cacheWriteTokens: 100,
                totalTokens: 1000,
                confidence: .exactBreakdown))
        let summary = CursorRangeUsageSummary(
            rangeKind: .billingCycle,
            range: CursorRecentRequestRange(start: now.addingTimeInterval(-3600), end: now),
            tokens: 1000,
            requests: 1,
            requestCostSummary: nil,
            recentRequests: [request])
        let snapshot = UsageSnapshot(primary: nil, secondary: nil, cursorRangeSummaries: [summary], updatedAt: now)
        let metadata = try #require(ProviderDefaults.metadata[.cursor])
        let model = UsageMenuCardView.Model.make(.init(
            provider: .cursor,
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

        #expect(StatusItemController.menuCardInteractionPolicy(for: model) == .scrollableContent)
    }
}
