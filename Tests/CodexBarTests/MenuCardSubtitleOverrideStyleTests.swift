import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct MenuCardSubtitleOverrideStyleTests {
    private static func model(liveSubtitle: Bool = false, refreshing: Bool = false) throws -> UsageMenuCardView.Model {
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
            isRefreshing: refreshing,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            usesLiveSubtitle: liveSubtitle,
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

    @MainActor
    @Test
    func `applied subtitle wins over the live refresh monitor`() throws {
        let live = try Self.model(liveSubtitle: true)
        let refreshing = try Self.model(liveSubtitle: true, refreshing: true)
        let monitor = MenuCardRefreshMonitor(
            resolveModel: { _ in refreshing },
            isProviderRefreshActive: { _ in false })

        // A live card follows the monitor's current provider status...
        #expect(MenuCardLiveSubtitle.resolve(model: live, refreshMonitor: monitor).text == refreshing.subtitleText)

        // ...but explicit switch feedback must not be replaced by it.
        let overridden = live.applyingSubtitle(text: "Switching Codex to Account 2…", style: .loading)
        let resolved = MenuCardLiveSubtitle.resolve(model: overridden, refreshMonitor: monitor)
        #expect(resolved.text == "Switching Codex to Account 2…")
        #expect(resolved.style == .loading)
    }
}
