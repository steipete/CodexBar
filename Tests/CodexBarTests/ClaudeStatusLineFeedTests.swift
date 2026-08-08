import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

/// The opt-in statusLine feed must compose with the polled sources and never replace them (owner ruling, #2733).
struct ClaudeStatusLineFeedTests {
    private func plan(
        feedEnabled: Bool,
        hasObservation: Bool,
        selected: ClaudeUsageDataSource = .auto,
        hasCLI: Bool = true,
        hasWebSession: Bool = true) -> ClaudeFetchPlan
    {
        ClaudeSourcePlanner.resolve(input: ClaudeSourcePlanningInput(
            runtime: .app,
            selectedDataSource: selected,
            webExtrasEnabled: false,
            hasWebSession: hasWebSession,
            hasCLI: hasCLI,
            hasOAuthCredentials: true,
            statusLineFeedEnabled: feedEnabled,
            hasStatusLineObservation: hasObservation))
    }

    private func limits(
        configDir: String?,
        capturedAt: Date,
        fiveHour: Double? = 40,
        sevenDay: Double? = 60) -> ClaudeStatusLineRateLimits
    {
        ClaudeStatusLineRateLimits(
            configDir: configDir,
            capturedAt: capturedAt,
            fiveHour: fiveHour.map { ClaudeStatusLineWindow(usedPercent: $0, resetsAt: nil) },
            sevenDay: sevenDay.map { ClaudeStatusLineWindow(usedPercent: $0, resetsAt: nil) })
    }

    // MARK: - Opt-in

    @Test
    func `the feed is absent from the auto order until it is switched on`() {
        let plan = self.plan(feedEnabled: false, hasObservation: true)
        #expect(!plan.availableSteps.contains { $0.dataSource == .statusline })
        // Off by default, so the ordinary chain is untouched.
        #expect(plan.availableSteps.first?.dataSource == .oauth)
    }

    @Test
    func `enabling the feed without an observation still leaves the chain untouched`() {
        let plan = self.plan(feedEnabled: true, hasObservation: false)
        #expect(!plan.availableSteps.contains { $0.dataSource == .statusline })
    }

    @Test
    func `the feed is never offered as a user selectable source`() {
        #expect(!ClaudeUsageDataSource.statusline.isUserSelectable)
        #expect(!ClaudeUsageDataSource.userSelectableCases.contains(.statusline))
        // Every other source stays selectable.
        #expect(ClaudeUsageDataSource.userSelectableCases.count == ClaudeUsageDataSource.allCases.count - 1)
    }

    // MARK: - Composition

    @Test
    func `the feed sits behind OAuth and ahead of the CLI probe`() throws {
        let order = self.plan(feedEnabled: true, hasObservation: true)
            .availableSteps.map(\.dataSource)
        let oauth = try #require(order.firstIndex(of: .oauth))
        let statusline = try #require(order.firstIndex(of: .statusline))
        let cli = try #require(order.firstIndex(of: .cli))
        // Composes rather than replaces: a working OAuth read still wins.
        #expect(oauth < statusline)
        #expect(statusline < cli)
    }

    @Test
    func `an explicit source selection is not joined by the feed`() {
        for selected in [ClaudeUsageDataSource.oauth, .web, .cli] {
            let plan = self.plan(feedEnabled: true, hasObservation: true, selected: selected)
            #expect(
                !plan.executionSteps.contains { $0.dataSource == .statusline },
                "explicit \(selected.rawValue) must not gain a statusline step")
        }
    }

    // MARK: - Attribution and freshness

    @Test
    func `an observation from another profile is never adopted`() {
        let foreign = self.limits(configDir: "/Users/x/.claude-work", capturedAt: Date())
        #expect(ClaudeStatusLineDropStore.select(
            candidates: [foreign],
            expectedConfigDir: "/Users/x/.claude") == nil)
        // The ambient profile matches only observations that also reported no config dir.
        #expect(ClaudeStatusLineDropStore.select(
            candidates: [foreign],
            expectedConfigDir: nil) == nil)
    }

    @Test
    func `a stale observation loses to no observation at all`() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let stale = self.limits(
            configDir: nil,
            capturedAt: now.addingTimeInterval(-ClaudeStatusLineDropStore.freshnessWindow - 1))
        #expect(ClaudeStatusLineDropStore.select(
            candidates: [stale],
            expectedConfigDir: nil,
            now: now) == nil)
    }

    @Test
    func `the newest matching observation wins`() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let older = self.limits(configDir: nil, capturedAt: now.addingTimeInterval(-600), fiveHour: 10)
        let newer = self.limits(configDir: nil, capturedAt: now.addingTimeInterval(-60), fiveHour: 80)
        let picked = try #require(ClaudeStatusLineDropStore.select(
            candidates: [older, newer],
            expectedConfigDir: nil,
            now: now))
        #expect(picked.fiveHour?.usedPercent == 80)
    }

    @Test
    func `modest clock skew does not blank a live feed`() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let skewed = self.limits(configDir: nil, capturedAt: now.addingTimeInterval(120))
        #expect(ClaudeStatusLineDropStore.select(
            candidates: [skewed],
            expectedConfigDir: nil,
            now: now) != nil)
    }

    @Test
    func `an implausibly future observation is rejected rather than trusted forever`() {
        // Unbounded future timestamps would stay fresh indefinitely — the same defect as an absent one.
        let now = Date(timeIntervalSince1970: 1_000_000)
        let farFuture = self.limits(
            configDir: nil,
            capturedAt: now.addingTimeInterval(ClaudeStatusLineDropStore.maximumClockSkew + 60))
        #expect(ClaudeStatusLineDropStore.select(
            candidates: [farFuture],
            expectedConfigDir: nil,
            now: now) == nil)
    }

    // MARK: - Snapshot mapping

    @Test
    func `a weekly only observation is promoted to the primary window`() throws {
        let weeklyOnly = self.limits(configDir: nil, capturedAt: Date(), fiveHour: nil, sevenDay: 55)
        let snapshot = try #require(ClaudeStatusLineDropStore.makeSnapshot(from: weeklyOnly))
        #expect(snapshot.primary.usedPercent == 55)
        #expect(snapshot.primary.windowMinutes == 10080)
        #expect(snapshot.secondary == nil)
    }

    @Test
    func `the snapshot carries no identity for the card to mislabel`() throws {
        let snapshot = try #require(
            ClaudeStatusLineDropStore.makeSnapshot(from: self.limits(configDir: nil, capturedAt: Date())))
        // Provider siloing: this feed knows nothing about the account, so it must not assert identity.
        #expect(snapshot.accountEmail == nil)
        #expect(snapshot.accountOrganization == nil)
        #expect(snapshot.primary.windowMinutes == 300)
        #expect(snapshot.secondary?.windowMinutes == 10080)
    }
}

/// Guards the gap the planner tests above cannot see: they build `ClaudeSourcePlanningInput` directly, so they
/// pass even when nothing carries the user's toggle into it. The first version of this feature was unreachable
/// for exactly that reason.
@MainActor
struct ClaudeStatusLineSettingsReachabilityTests {
    @Test
    func `the feed toggle reaches the provider settings snapshot`() {
        let settings = testSettingsStore(suiteName: "ClaudeStatusLineFeed-reachability")

        // Off by default (owner ruling, #2733).
        #expect(!settings.claudeStatusLineFeedEnabled)
        #expect(settings.claudeSettingsSnapshot(tokenOverride: nil).statusLineFeedEnabled == false)

        settings.claudeStatusLineFeedEnabled = true
        // The planner reads this snapshot field; without it the step can never become available.
        #expect(settings.claudeSettingsSnapshot(tokenOverride: nil).statusLineFeedEnabled == true)
    }
}
