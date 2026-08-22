import CodexBarCore
import Foundation
import Testing
@testable import CodexBarWidget

@Suite("Widget tile layout")
struct WidgetTileLayoutTests {
    // MARK: - Headline selection

    private func lane(_ id: String, _ title: String, _ remaining: Double?) -> WidgetTileLane {
        WidgetTileLane(id: id, title: title, remainingPercent: remaining)
    }

    @Test
    func `headline is the lane with the least left`() {
        let plan = WidgetTilePlan.make(
            lanes: [self.lane("a", "Session", 100), self.lane("b", "Weekly", 41), self.lane("c", "Opus", 77)],
            maxSecondaryLanes: 5)

        #expect(plan.hero?.id == "b")
        #expect(plan.lanes.map(\.id) == ["a", "c"])
        #expect(plan.overflowCount == 0)
    }

    @Test
    func `headline ties keep the provider ordering`() {
        let plan = WidgetTilePlan.make(
            lanes: [self.lane("a", "Session", 50), self.lane("b", "Weekly", 50)],
            maxSecondaryLanes: 5)

        #expect(plan.hero?.id == "a")
    }

    @Test
    func `lanes without a percentage never displace a measured headline`() {
        let plan = WidgetTilePlan.make(
            lanes: [self.lane("a", "Unknown", nil), self.lane("b", "Weekly", 88)],
            maxSecondaryLanes: 5)

        #expect(plan.hero?.id == "b")
        #expect(plan.lanes.map(\.id) == ["a"])
    }

    @Test
    func `an unmeasured lane still becomes the headline when nothing else can`() {
        let plan = WidgetTilePlan.make(lanes: [self.lane("a", "Unknown", nil)], maxSecondaryLanes: 5)

        #expect(plan.hero?.id == "a")
    }

    @Test
    func `no lanes yields an empty plan`() {
        #expect(WidgetTilePlan.make(lanes: [], maxSecondaryLanes: 5) == .empty)
    }

    @Test
    func `lanes beyond the cap are counted rather than dropped silently`() {
        let lanes = (0..<8).map { self.lane("lane-\($0)", "Lane \($0)", Double(50 + $0)) }

        let plan = WidgetTilePlan.make(lanes: lanes, maxSecondaryLanes: 3)

        #expect(plan.hero?.id == "lane-0")
        #expect(plan.lanes.count == 3)
        #expect(plan.overflowCount == 4)
    }

    @Test
    func `reserving a slot for the overflow row keeps compact tiles inside their budget`() {
        let lanes = (0..<6).map { self.lane("lane-\($0)", "Lane \($0)", Double(50 + $0)) }

        let reserved = WidgetTilePlan.make(lanes: lanes, maxSecondaryLanes: 2, reservesOverflowRow: true)
        let unreserved = WidgetTilePlan.make(lanes: lanes, maxSecondaryLanes: 2)

        #expect(reserved.lanes.count == 1)
        #expect(reserved.overflowCount == 4)
        #expect(unreserved.lanes.count == 2)
        #expect(unreserved.overflowCount == 3)
    }

    @Test
    func `reserving a slot does nothing when every lane already fits`() {
        let lanes = (0..<3).map { self.lane("lane-\($0)", "Lane \($0)", Double(50 + $0)) }

        let plan = WidgetTilePlan.make(lanes: lanes, maxSecondaryLanes: 2, reservesOverflowRow: true)

        #expect(plan.lanes.count == 2)
        #expect(plan.overflowCount == 0)
    }

    @Test
    func `a provider row cap never hides the binding lane`() {
        // Kimi writes primary/secondary plus kimi-monthly and kimi-code-7d, but caps compact tiles
        // at three rows. Truncating before the headline was chosen dropped a 1%-left lane and left
        // overflowCount at zero, so the tile gave no sign the binding quota was missing.
        let all = [
            self.lane("primary", "Session", 88),
            self.lane("secondary", "Weekly", 74),
            self.lane("kimi-monthly", "Monthly", 60),
            self.lane("kimi-code-7d", "Code 7d", 1),
        ]
        let curated = Array(all.prefix(3))

        let plan = WidgetTilePlan.make(lanes: all, displayCandidates: curated, maxSecondaryLanes: 2)

        #expect(plan.hero?.id == "kimi-code-7d")
        #expect(plan.overflowCount == all.count - 1 - plan.lanes.count)
        #expect(plan.overflowCount > 0)
    }

    @Test
    func `the curated row count is honoured once the headline takes a row`() {
        let all = (0..<6).map { self.lane("lane-\($0)", "Lane \($0)", Double(50 + $0)) }
        let curated = Array(all.prefix(3))

        let plan = WidgetTilePlan.make(lanes: all, displayCandidates: curated, maxSecondaryLanes: 5)

        // Headline plus listed lanes must not exceed what the provider curated.
        #expect(1 + plan.lanes.count <= curated.count)
        #expect(plan.overflowCount == all.count - 1 - plan.lanes.count)
    }

    @Test
    func `without a provider cap every lane is still accounted for`() {
        let all = (0..<4).map { self.lane("lane-\($0)", "Lane \($0)", Double(50 + $0)) }

        let plan = WidgetTilePlan.make(lanes: all, maxSecondaryLanes: 5)

        #expect(plan.hero?.id == "lane-0")
        #expect(plan.lanes.count == 3)
        #expect(plan.overflowCount == 0)
    }

    // MARK: - Lane capacity

    @Test
    func `large tiles trade lane slots for the cost block and the chart`() {
        #expect(WidgetTileSize.large.secondaryLaneCapacity(hasMetrics: false, hasChart: false) == 6)
        #expect(WidgetTileSize.large.secondaryLaneCapacity(hasMetrics: true, hasChart: false) == 4)
        #expect(WidgetTileSize.large.secondaryLaneCapacity(hasMetrics: true, hasChart: true) == 2)
        #expect(WidgetTileSize.medium.secondaryLaneCapacity(hasMetrics: true, hasChart: false) == 2)
        #expect(WidgetTileSize.medium.secondaryLaneCapacity(hasMetrics: false, hasChart: false) == 3)
    }

    @Test
    func `the chart yields to the lanes once a provider reports more than three`() {
        #expect(WidgetTileSize.large.showsChart(laneCount: 3, hasHistory: true))
        #expect(!WidgetTileSize.large.showsChart(laneCount: 4, hasHistory: true))
        #expect(!WidgetTileSize.large.showsChart(laneCount: 2, hasHistory: false))
        #expect(!WidgetTileSize.medium.showsChart(laneCount: 1, hasHistory: true))
    }

    // MARK: - Lane copy

    @Test
    func `lane captions state whether the figure is remaining or used`() {
        #expect(WidgetLaneCopy.caption(title: "Weekly", showUsed: false) == "Weekly left")
        #expect(WidgetLaneCopy.caption(title: "Weekly", showUsed: true) == "Weekly used")
    }

    @Test
    func `reset text rounds to the nearest whole unit`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func text(_ seconds: TimeInterval) -> String? {
            WidgetLaneCopy.resetText(resetsAt: now.addingTimeInterval(seconds), resetDescription: nil, now: now)
        }

        #expect(text(45 * 60) == "Resets in 45m")
        #expect(text(3 * 3600) == "Resets in 3h")
        // 47h59m is two days to a reader; flooring used to render it as "1d".
        #expect(text(48 * 3600 - 60) == "Resets in 2d")
        #expect(text(9 * 86400) == "Resets in 9d")
    }

    @Test
    func `a known reset date wins over provider wording`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        // The compact countdown is predictable in width; provider wording is not.
        #expect(WidgetLaneCopy.resetText(
            resetsAt: now.addingTimeInterval(3600),
            resetDescription: "Resets Monday",
            now: now) == "Resets in 1h")
    }

    @Test
    func `bare provider timestamps get labelled so they are not mistaken for data`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        // Codex emits "tomorrow, 12:28 PM", which says nothing on its own.
        #expect(WidgetLaneCopy.resetText(
            resetsAt: nil,
            resetDescription: "tomorrow, 12:28 PM",
            now: now) == "Resets tomorrow, 12:28 PM")
        // Wording that already says "Resets" is passed through untouched.
        #expect(WidgetLaneCopy.resetText(
            resetsAt: nil,
            resetDescription: "Resets Monday",
            now: now) == "Resets Monday")
    }

    @Test
    func `a known reset that already passed renders nothing, even with cached wording`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        // A stale snapshot would otherwise keep showing "Resets in 4h" after the reset happened.
        #expect(WidgetLaneCopy.resetText(
            resetsAt: now.addingTimeInterval(-60),
            resetDescription: "Resets in 4h",
            now: now) == nil)
    }

    @Test
    func `expired and unknown resets render nothing`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        #expect(WidgetLaneCopy.resetText(
            resetsAt: now.addingTimeInterval(-60),
            resetDescription: nil,
            now: now) == nil)
        #expect(WidgetLaneCopy.resetText(resetsAt: nil, resetDescription: "   ", now: now) == nil)
    }

    // MARK: - Freshness

    @Test
    func `a snapshot from moments ago reads as Now, never as a future time`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        // Gallery placeholders stamp updatedAt with the render time; the formatter turns that
        // instant into "in 0s".
        #expect(WidgetFormat.shortRelativeDate(now, relativeTo: now) == "Now")
        #expect(WidgetFormat.shortRelativeDate(now.addingTimeInterval(30), relativeTo: now) == "Now")
        #expect(WidgetFormat.shortRelativeDate(now.addingTimeInterval(-30), relativeTo: now) == "Now")
        #expect(WidgetFormat.shortRelativeDate(now.addingTimeInterval(-3600), relativeTo: now) != "Now")
    }

    @Test
    func `staleness only trips past a day`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        #expect(!WidgetFreshness.isStale(now.addingTimeInterval(-3600), now: now))
        #expect(WidgetFreshness.isStale(now.addingTimeInterval(-5 * 86400), now: now))
    }

    // MARK: - Reset metadata recovery

    @Test
    func `generic provider rows recover their reset from the entry windows`() {
        // The generic snapshot writer stores only percentLeft for primary/secondary/tertiary and
        // leaves the reset on the entry's own windows, so the caption used to appear for Codex and
        // silently vanish for Claude, Gemini and Alibaba.
        let reset = Date(timeIntervalSince1970: 1_800_003_600)
        let entry = WidgetSnapshot.ProviderEntry(
            provider: .claude,
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            primary: RateWindow(usedPercent: 10, windowMinutes: 300, resetsAt: reset, resetDescription: nil),
            secondary: RateWindow(usedPercent: 40, windowMinutes: 10080, resetsAt: reset, resetDescription: nil),
            tertiary: nil,
            usageRows: [
                .init(id: "primary", title: "Session", percentLeft: 90),
                .init(id: "secondary", title: "Weekly", percentLeft: 60),
            ],
            creditsRemaining: nil,
            codeReviewRemainingPercent: nil,
            tokenUsage: nil,
            dailyUsage: [])

        let rows = WidgetUsageRow.rows(for: entry)

        #expect(rows.map(\.resetsAt) == [reset, reset])
        // The row's own percentage stays authoritative.
        #expect(rows.map(\.percentLeft) == [90, 60])
    }

    @Test
    func `slot recovery does not invent resets for provider specific rows`() {
        let entry = WidgetSnapshot.ProviderEntry(
            provider: .kimi,
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            primary: RateWindow(
                usedPercent: 10,
                windowMinutes: 300,
                resetsAt: Date(timeIntervalSince1970: 1_800_003_600),
                resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            usageRows: nil,
            creditsRemaining: nil,
            codeReviewRemainingPercent: nil,
            tokenUsage: nil,
            dailyUsage: [])

        #expect(WidgetUsageRow.slotWindow(for: "kimi-code-7d", entry: entry) == nil)
        #expect(WidgetUsageRow.slotWindow(for: "primary", entry: entry) != nil)
    }

    // MARK: - Severity

    @Test
    func `severity tracks what is left, not what is displayed`() {
        #expect(QuotaSeverity.isLow(remaining: 10))
        #expect(QuotaSeverity.isLow(remaining: 0))
        #expect(!QuotaSeverity.isLow(remaining: 10.1))
        #expect(!QuotaSeverity.isLow(remaining: nil))
    }

    @Test
    func `a nearly exhausted bar keeps a visible fill`() {
        #expect(QuotaBar.fillFraction(0) == 0)
        #expect(QuotaBar.fillFraction(nil) == 0)
        #expect(QuotaBar.fillFraction(50) == 0.5)
        #expect(QuotaBar.fillFraction(140) == 1)
        #expect(QuotaBar.fillFraction(-5) == 0)
    }
}
