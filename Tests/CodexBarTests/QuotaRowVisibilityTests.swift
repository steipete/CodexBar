import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct QuotaRowVisibilityTests {
    private static func snapshot(now: Date) -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(usedPercent: 20, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 40, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            extraRateWindows: [
                NamedRateWindow(
                    id: "claude-weekly-scoped-fable",
                    title: "Fable only",
                    window: RateWindow(
                        usedPercent: 12,
                        windowMinutes: 10080,
                        resetsAt: nil,
                        resetDescription: nil)),
                NamedRateWindow(
                    id: "claude-weekly-scoped-design",
                    title: "Design only",
                    window: RateWindow(
                        usedPercent: 55,
                        windowMinutes: 10080,
                        resetsAt: nil,
                        resetDescription: nil)),
            ],
            updatedAt: now)
    }

    private static func model(
        hiddenQuotaRowIDs: Set<String>,
        now: Date) throws -> UsageMenuCardView.Model
    {
        let metadata = try #require(ProviderDefaults.metadata[.claude])
        return UsageMenuCardView.Model.make(.init(
            provider: .claude,
            metadata: metadata,
            snapshot: Self.snapshot(now: now),
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
            showOptionalCreditsAndExtraUsage: true,
            hiddenQuotaRowIDs: hiddenQuotaRowIDs,
            hidePersonalInfo: false,
            now: now))
    }

    @Test
    func `hidden quota rows are dropped from the menu metrics`() throws {
        let now = Date()

        let allVisible = try Self.model(hiddenQuotaRowIDs: [], now: now)
        #expect(allVisible.metrics.map(\.id).contains("claude-weekly-scoped-fable"))
        #expect(allVisible.metrics.map(\.id).contains("claude-weekly-scoped-design"))

        let hidden = try Self.model(hiddenQuotaRowIDs: ["claude-weekly-scoped-fable"], now: now)
        #expect(hidden.metrics.map(\.id).contains("claude-weekly-scoped-fable") == false)
        // Only the hidden row disappears; the other lanes keep rendering.
        #expect(hidden.metrics.map(\.id).contains("claude-weekly-scoped-design"))
        #expect(hidden.metrics.count == allVisible.metrics.count - 1)
    }

    @Test
    func `hiding a row is scoped to one provider`() {
        let hiddenForClaude = QuotaRowVisibilityState.updating(
            [:],
            provider: .claude,
            id: "claude-weekly-scoped-fable",
            visible: false)

        #expect(hiddenForClaude == [UsageProvider.claude.rawValue: ["claude-weekly-scoped-fable"]])
        #expect(QuotaRowVisibilityState.hiddenIDs(
            in: hiddenForClaude ?? [:],
            provider: .codex).isEmpty)
    }

    @Test
    func `hiding and restoring rows round-trips`() throws {
        var raw: [String: [String]] = [:]
        raw = try #require(QuotaRowVisibilityState.updating(
            raw, provider: .claude, id: "claude-weekly-scoped-fable", visible: false))
        raw = try #require(QuotaRowVisibilityState.updating(
            raw, provider: .claude, id: "claude-weekly-scoped-design", visible: false))
        #expect(QuotaRowVisibilityState.hiddenIDs(in: raw, provider: .claude).count == 2)

        raw = try #require(QuotaRowVisibilityState.updating(
            raw, provider: .claude, id: "claude-weekly-scoped-fable", visible: true))
        #expect(QuotaRowVisibilityState.hiddenIDs(in: raw, provider: .claude) == ["claude-weekly-scoped-design"])

        raw = try #require(QuotaRowVisibilityState.clearing(raw, provider: .claude))
        // The provider entry is removed rather than left as an empty list.
        #expect(raw[UsageProvider.claude.rawValue] == nil)
    }

    @Test
    func `redundant updates report no change`() {
        // Showing an already-visible row, or hiding an already-hidden one, must not rewrite storage.
        #expect(QuotaRowVisibilityState.updating(
            [:], provider: .claude, id: "claude-weekly-scoped-fable", visible: true) == nil)
        #expect(QuotaRowVisibilityState.clearing([:], provider: .claude) == nil)

        let hidden = [UsageProvider.claude.rawValue: ["claude-weekly-scoped-fable"]]
        #expect(QuotaRowVisibilityState.updating(
            hidden, provider: .claude, id: "claude-weekly-scoped-fable", visible: false) == nil)
    }
}
