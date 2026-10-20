import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct MenuBarSpendCountdownRefreshTests {
    /// The spend reset predicate gets the same exact wake-up as the quota windows.
    @Test
    func `predicate-only spend reset countdown conditional schedules its flip instant`() {
        let settings = Self.makeSettings(suite: "MenuBarSpendCountdownRefreshTests-predicate-only")
        let conditional = MenuBarLayoutConditional(
            name: "gate",
            clauses: [MenuBarConditionalClause(
                combinator: nil,
                predicate: MenuBarConditionalPredicate(metric: .spendResetsIn, comparison: .lessThan, threshold: 1))],
            thenToken: .providerName,
            elseToken: .hidden)
        settings.menuBarLayoutConditionals = [conditional]
        settings.menuBarLayout = MenuBarLayout(lines: [[.icon, .conditional(id: conditional.id)]])
        let controller = Self.makeController(settings: settings)
        defer { controller.releaseStatusItemsForTesting() }

        #expect(controller._test_isMenuBarCountdownRefreshScheduled())
    }

    @Test
    func `spend reset tokens contribute their window to the countdown dates`() {
        let settings = Self.makeSettings(suite: "MenuBarSpendCountdownRefreshTests-token-dates")
        settings.menuBarLayout = MenuBarLayout(lines: [[
            .windowResetCountdown(window: .spend), .windowResetAbsolute(window: .spend),
        ]])
        let controller = Self.makeController(settings: settings)
        defer { controller.releaseStatusItemsForTesting() }
        let now = Date()

        let countdown = controller.menuBarLayoutResetDates(for: .claude, now: now, absolute: false)
        let absolute = controller.menuBarLayoutResetDates(for: .claude, now: now, absolute: true)

        #expect(countdown.count == 1)
        #expect(countdown.first.map { abs($0.timeIntervalSince(now.addingTimeInterval(3 * 60 * 60))) < 5 } == true)
        #expect(absolute == countdown)
    }

    @Test
    func `spend pace token schedules its elapsed eligibility refresh`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let month = try #require(calendar.dateInterval(of: .month, for: Date()))
        let settings = Self.makeSettings(suite: "MenuBarSpendCountdownRefreshTests-pace-boundary")
        settings.menuBarLayout = MenuBarLayout(lines: [[.icon, .pace(window: .spend)]])
        let controller = Self.makeController(settings: settings, resetsAt: month.end)
        defer { controller.releaseStatusItemsForTesting() }

        // An hour into the month is short of the 1% floor (about seven hours), so pace waits on that boundary.
        controller.scheduleMenuBarCountdownRefreshIfNeeded(now: month.start.addingTimeInterval(60 * 60))

        #expect(controller._test_isMenuBarCountdownRefreshScheduled())
    }

    private static func makeSettings(suite: String) -> SettingsStore {
        let settings = testSettingsStore(suiteName: suite)
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.menuBarShowsBrandIconWithPercent = true
        return settings
    }

    /// Claude with a monthly spend budget that resets in three hours unless `resetsAt` says otherwise.
    private static func makeController(settings: SettingsStore, resetsAt: Date? = nil) -> StatusItemController {
        if let metadata = ProviderRegistry.shared.metadata[.claude] {
            settings.setProviderEnabled(provider: .claude, metadata: metadata, enabled: true)
        }
        let fetcher = UsageFetcher(environment: [:])
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: testStatusBar())

        let now = Date()
        let budget = ProviderCostSnapshot(
            used: 420,
            limit: 1000,
            currencyCode: "USD",
            period: "Monthly",
            resetsAt: resetsAt ?? now.addingTimeInterval(3 * 60 * 60),
            updatedAt: now)
        store._setSnapshotForTesting(
            UsageSnapshot(primary: nil, secondary: nil, providerCost: budget, updatedAt: now),
            provider: .claude)
        controller.updateIcons()
        return controller
    }
}
