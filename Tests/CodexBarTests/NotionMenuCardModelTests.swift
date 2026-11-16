import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

/// The card is where the calendar-cycle resolution has to land. `ProviderPaceCapability` exposing the
/// right duration is not enough on its own: the card is also handed a precomputed `weeklyPace`, and
/// preferring it would score the billing period as a flat 30 days while the CLI scored the real month.
struct NotionMenuCardModelTests {
    /// 2026-02-08T00:00:00Z — 21 days before the cycle ends, 7 days into a 28-day February.
    private static let now = Date(timeIntervalSince1970: 1_770_508_800)
    /// 2026-03-01T00:00:00Z.
    private static let periodEnd = Date(timeIntervalSince1970: 1_772_323_200)

    private static func snapshot() -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(
                usedPercent: 50,
                windowMinutes: 360,
                resetsAt: self.now.addingTimeInterval(3600),
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 40,
                windowMinutes: 43200,
                resetsAt: self.periodEnd,
                resetDescription: nil),
            updatedAt: self.now)
    }

    private static func model(
        weeklyPace: UsagePace?,
        snapshot: UsageSnapshot = Self.snapshot(),
        showOptional: Bool = true) throws -> UsageMenuCardView.Model
    {
        let metadata = try #require(ProviderDefaults.metadata[.notion])
        return UsageMenuCardView.Model.make(.init(
            provider: .notion,
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
            showOptionalCreditsAndExtraUsage: showOptional,
            hidePersonalInfo: false,
            weeklyPace: weeklyPace,
            now: Self.now))
    }

    @Test
    func `monthly bar paces against February, not a flat thirty days`() throws {
        let monthly = try #require(Self.snapshot().secondary)
        // What the store hands the card: a pace measured against the raw 30-day sentinel. Reusing it
        // would report 30% expected (9 of 30 days) instead of 25% (7 of February's 28).
        let sentinelPace = try #require(UsagePace.weekly(
            window: monthly,
            now: Self.now,
            defaultWindowMinutes: 10080))
        #expect((sentinelPace.expectedUsedPercent * 10).rounded() / 10 == 30)

        let metric = try #require(try Self.model(weeklyPace: sentinelPace).metrics.first { $0.id == "secondary" })

        #expect(metric.pacePercent == 25)
        #expect(metric.detailLeftText == "15% in deficit")
    }

    @Test
    func `monthly pace is identical whether or not a precomputed pace is supplied`() throws {
        let monthly = try #require(Self.snapshot().secondary)
        let sentinelPace = UsagePace.weekly(window: monthly, now: Self.now, defaultWindowMinutes: 10080)

        let withPace = try #require(try Self.model(weeklyPace: sentinelPace).metrics.first { $0.id == "secondary" })
        let withoutPace = try #require(try Self.model(weeklyPace: nil).metrics.first { $0.id == "secondary" })

        #expect(withPace.pacePercent == withoutPace.pacePercent)
        #expect(withPace.detailLeftText == withoutPace.detailLeftText)
    }

    @Test
    func `rolling bar carries a session pace`() throws {
        let metric = try #require(try Self.model(weeklyPace: nil).metrics.first { $0.id == "primary" })

        // Five of the six rolling hours elapsed against 50% used.
        #expect(metric.detailLeftText == "33% in reserve")
    }

    @Test(arguments: ["7,850.5", "0", nil] as [String?])
    func `premium balance renders as a separate text section without a fabricated gauge`(balance: String?) throws {
        let base = Self.snapshot()
        let sections = try balance.map { value in
            try [ProviderDetailSection(title: "Notion Credits", rows: [
                .init(label: "Remaining credits", value: value),
            ])]
        } ?? []
        let snapshot = UsageSnapshot(
            primary: base.primary,
            secondary: base.secondary,
            details: sections,
            updatedAt: Self.now)
        let model = try Self.model(weeklyPace: nil, snapshot: snapshot)
        #expect(model.metrics.map(\.id) == ["primary", "secondary"])
        #expect(model.providerDetails.first?.title == (balance == nil ? nil : "Notion Credits"))
        #expect(model.providerDetails.first?.rows.first?.value == balance)
        #expect(model.providerDetails.first?.rows.first?.progress == nil)
        #expect(model.creditsText == nil)
        #expect(model.cloudCredits == nil)
        let hidden = try Self.model(weeklyPace: nil, snapshot: snapshot, showOptional: false)
        #expect(hidden.providerDetails.isEmpty)
        #expect(hidden.metrics.map(\.id) == model.metrics.map(\.id))
        let restored = try Self.model(weeklyPace: nil, snapshot: snapshot, showOptional: true)
        #expect(restored.providerDetails.first?.rows.first?.value == balance)
        let refreshedWithoutCredits = try Self.model(weeklyPace: nil, snapshot: base, showOptional: true)
        #expect(refreshedWithoutCredits.providerDetails.isEmpty)
    }

    @Test
    func `personal monthly labels and pace use the exact server duration even at the legacy sentinel`() throws {
        let standard = RateWindow(
            usedPercent: 20,
            windowMinutes: 43200,
            resetsAt: Self.periodEnd,
            resetDescription: nil,
            quotaLimit: 1500,
            quotaUnit: "credits",
            title: "Standard")
        let select = RateWindow(
            usedPercent: 0,
            windowMinutes: 43200,
            resetsAt: Self.periodEnd,
            resetDescription: nil,
            quotaLimit: 500,
            quotaUnit: "credits",
            title: "Select")
        let snapshot = try UsageSnapshot(
            primary: standard,
            secondary: select,
            details: [
                ProviderDetailSection(title: "Personal credits", rows: [
                    .init(label: "Standard remaining", value: "1,200 credits"),
                    .init(label: "Select remaining", value: "500 credits"),
                ]),
                ProviderDetailSection(title: "Notion Credits", rows: [
                    .init(label: "Remaining credits", value: "300"),
                ]),
            ], updatedAt: Self.now)
        let model = try Self.model(weeklyPace: nil, snapshot: snapshot)
        #expect(model.metrics.map(\.title) == ["Standard", "Select"])
        // This server interval starts January 30. Inferring February would incorrectly yield 25%.
        #expect(model.metrics.map(\.pacePercent) == [30, 30])
        let labels = MenuBarLayoutLaneLabels(provider: .notion, snapshot: snapshot)
        #expect(labels.primary == "Standard")
        #expect(labels.secondary == "Select")
        #expect(MenuBarPercentWindowPreference.session.label(for: .notion, snapshot: snapshot) == "Rolling")
        #expect(MenuBarLayoutSemanticWindowResolver.windows(provider: .notion, snapshot: snapshot).session == nil)
        #expect(MenuBarLayoutBalanceResolver.balance(provider: .notion, snapshot: snapshot) == "300")
        #expect(MenuBarLayoutBalanceResolver.legacyBalance(provider: .notion, snapshot: snapshot) == nil)
        let hidden = try Self.model(weeklyPace: nil, snapshot: snapshot, showOptional: false)
        #expect(hidden.metrics.map(\.title) == model.metrics.map(\.title))
        #expect(hidden.providerDetails.map(\.title) == ["Personal credits"])
        #expect(MenuBarLayoutBalanceResolver.balance(
            provider: .notion, snapshot: snapshot, showsOptionalCredits: false) == nil)
    }
}
