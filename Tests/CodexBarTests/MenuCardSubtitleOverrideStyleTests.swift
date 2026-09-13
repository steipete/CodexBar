import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct MenuCardSubtitleOverrideStyleTests {
    private static func model() throws -> UsageMenuCardView.Model {
        let metadata = try #require(ProviderDefaults.metadata[.grok])
        let now = Date()
        return UsageMenuCardView.Model.make(.init(
            provider: .grok,
            metadata: metadata,
            snapshot: UsageSnapshot(primary: nil, secondary: nil, tertiary: nil, updatedAt: now, identity: nil),
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
    }

    @Test
    func `applied subtitle keeps its requested text and style`() throws {
        let base = try Self.model()
        let loading = base.applyingSubtitle(text: "Switching Codex to Account 2…", style: .loading)
        #expect(loading.subtitleText == "Switching Codex to Account 2…")
        #expect(loading.subtitleStyle == .loading)
        #expect(base.applyingSubtitle(text: "Boom", style: .error).subtitleStyle == .error)
        #expect(loading.metrics.map(\.id) == base.metrics.map(\.id))
    }
}
