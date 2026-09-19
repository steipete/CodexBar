import CodexBarCore
import Foundation
import Testing
@testable import CodexBarWidget

@Suite("Widget binding quota")
struct WidgetBindingQuotaTests {
    private typealias Row = WidgetSnapshot.WidgetUsageRowSnapshot

    private func entry(
        _ provider: UsageProvider,
        primary: Double? = nil,
        secondary: Double? = nil,
        tertiary: Double? = nil,
        rows: [Row]? = nil,
        review: Double? = nil,
        credits: Double? = nil,
        tokenUsage: WidgetSnapshot.TokenUsageSummary? = nil) -> WidgetSnapshot.ProviderEntry
    {
        func window(_ remaining: Double?) -> RateWindow? {
            remaining
                .map { RateWindow(usedPercent: 100 - $0, windowMinutes: nil, resetsAt: nil, resetDescription: nil) }
        }
        return WidgetSnapshot.ProviderEntry(
            provider: provider,
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            primary: window(primary),
            secondary: window(secondary),
            tertiary: window(tertiary),
            usageRows: rows,
            creditsRemaining: credits,
            codeReviewRemainingPercent: review,
            tokenUsage: tokenUsage,
            dailyUsage: [])
    }

    @Test
    func `Codex review does not displace its binding coding quota`() {
        let entry = self.entry(
            .codex,
            primary: 70,
            secondary: 40,
            rows: [
                Row(id: "session", title: "Session", percentLeft: 70),
                Row(id: "weekly", title: "Weekly", percentLeft: 40),
            ],
            review: 0)
        let plan = WidgetTilePlan.make(lanes: WidgetTileLane.lanes(for: entry), maxSecondaryLanes: 5)
        #expect(plan.hero?.id == "weekly")
        #expect(plan.lanes.map(\.id) == ["session", "code-review"])
    }

    @Test
    func `Codex ranks raw quota windows before applying the weekly cap`() {
        let entry = self.entry(.codex, primary: 99, secondary: 0, rows: [
            Row(id: "session", title: "Session", percentLeft: 99),
            Row(id: "weekly", title: "Weekly", percentLeft: 0),
        ])
        let plan = WidgetTilePlan.make(lanes: WidgetTileLane.lanes(for: entry), maxSecondaryLanes: 5)
        #expect(plan.hero?.id == "weekly")
        #expect(plan.lanes.first?.remainingPercent == 99)
    }

    @Test
    func `Claude model quotas remain details even when exhausted`() {
        let entry = self.entry(.claude, rows: [
            Row(id: "primary", title: "Session", percentLeft: 70),
            Row(id: "secondary", title: "Weekly", percentLeft: 40),
            Row(id: "tertiary", title: "Fable", percentLeft: 0),
            Row(id: "claude-scoped", title: "Scoped", percentLeft: 0),
        ])
        let plan = WidgetTilePlan.make(lanes: WidgetTileLane.lanes(for: entry), maxSecondaryLanes: 5)
        #expect(plan.hero?.id == "secondary")
        #expect(plan.lanes.map(\.id) == ["primary", "tertiary", "claude-scoped"])
    }

    @Test
    func `all declared binding slots participate in headline selection`() {
        let entry = self.entry(.alibaba, rows: [
            Row(id: "primary", title: "Session", percentLeft: 70),
            Row(id: "secondary", title: "Weekly", percentLeft: 40),
            Row(id: "tertiary", title: "Monthly", percentLeft: 5),
        ])
        let plan = WidgetTilePlan.make(lanes: WidgetTileLane.lanes(for: entry), maxSecondaryLanes: 5)
        #expect(plan.hero?.id == "tertiary")
    }

    @Test
    func `Claude replacement balance remains useful without promoting scoped only rows`() {
        let balance = self.entry(.claude, rows: [Row(id: "extraUsage", title: "Extra usage", percentLeft: 15)])
        let scoped = self.entry(.claude, rows: [Row(id: "tertiary", title: "Fable", percentLeft: 0)])
        let balancePlan = WidgetTilePlan.make(lanes: WidgetTileLane.lanes(for: balance), maxSecondaryLanes: 5)
        let scopedPlan = WidgetTilePlan.make(lanes: WidgetTileLane.lanes(for: scoped), maxSecondaryLanes: 5)
        #expect(balancePlan.hero?.id == "extraUsage")
        #expect(scopedPlan.hero == nil)
        #expect(scopedPlan.lanes.map(\.id) == ["tertiary"])
    }

    @Test
    func `Kimi quota beyond compact curation remains the headline`() {
        let entry = self.entry(.kimi, rows: [
            Row(id: "primary", title: "Session", percentLeft: 70),
            Row(id: "secondary", title: "Weekly", percentLeft: 40),
            Row(id: "kimi-monthly", title: "Monthly", percentLeft: 30),
            Row(id: "kimi-code-7d", title: "Code 7d", percentLeft: 1),
        ])
        let all = WidgetTileLane.lanes(for: entry)
        let curated = WidgetTileLane.lanes(for: entry, limit: WidgetUsageRow.smallWidgetRowLimit(for: entry))
        let plan = WidgetTilePlan.make(
            lanes: all,
            displayCandidates: curated,
            maxSecondaryLanes: 2,
            reservesOverflowRow: true)
        #expect(plan.hero?.id == "kimi-code-7d")
        #expect(plan.overflowCount == all.count - 1 - plan.lanes.count)
    }

    @Test
    func `legacy snapshots use the same binding slot policy`() throws {
        let original = self.entry(.claude, primary: 70, secondary: 40, tertiary: 0)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(WidgetSnapshot.ProviderEntry.self, from: data)
        #expect(decoded.usageRows == nil)
        let plan = WidgetTilePlan.make(lanes: WidgetTileLane.lanes(for: decoded), maxSecondaryLanes: 5)
        #expect(plan.hero?.id == "secondary")
        #expect(plan.lanes.map(\.id) == ["primary", "tertiary"])
    }

    @Test
    func `review only snapshots keep the detail and credit fallback`() {
        let entry = self.entry(.codex, review: 0, credits: 10)
        let plan = WidgetTilePlan.make(lanes: WidgetTileLane.lanes(for: entry), maxSecondaryLanes: 5)
        #expect(plan.hero == nil)
        #expect(plan.lanes.map(\.id) == ["code-review"])
        #expect(plan.overflowCount == 0)
        let fallback = WidgetFallbackHero.make(for: entry)
        #expect(fallback?.consumedMetricID == "credits")
        let metrics = WidgetMetricRows.rows(
            for: entry,
            size: .large,
            secondaryLaneCount: 1,
            excluding: fallback?.consumedMetricID)
        #expect(!metrics.contains { $0.id == "credits" })
    }

    @Test
    func `unpriced local history keeps reported tokens in small widgets`() {
        let summary = WidgetSnapshot.TokenUsageSummary(
            sessionCostUSD: nil,
            sessionTokens: 1200,
            last30DaysCostUSD: nil,
            last30DaysTokens: 1200,
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let entry = self.entry(.claude, tokenUsage: summary)
        let fallback = WidgetFallbackHero.make(for: entry)
        #expect(fallback?.value == UsageFormatter.tokenCountString(1200))
        #expect(fallback?.caption == "Today tokens")
        #expect(WidgetMetricRows.rows(for: entry, size: .small).first?.value == WidgetFormat.tokenCount(1200))
        let remaining = WidgetMetricRows.rows(for: entry, size: .small, excluding: fallback?.consumedMetricID)
        #expect(remaining.isEmpty)
    }

    @Test
    func `live reset presentation omits expired dates and uses provider text only without a date`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let future = now.addingTimeInterval(3600)
        #expect(WidgetLaneCopy.reset(resetsAt: future, resetDescription: "in 4h", now: now) == .date(future))
        #expect(WidgetLaneCopy.reset(resetsAt: now, resetDescription: "in 4h", now: now) == nil)
        #expect(WidgetLaneCopy.reset(
            resetsAt: now.addingTimeInterval(-1), resetDescription: "in 4h", now: now) == nil)
        #expect(WidgetLaneCopy.reset(resetsAt: nil, resetDescription: "in 4h", now: now) == .text("Resets in 4h"))
    }
}
