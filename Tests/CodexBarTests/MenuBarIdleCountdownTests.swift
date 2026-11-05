import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct MenuBarIdleCountdownTests {
    @Test
    func `hidden reset branches do not schedule countdown work`() {
        let (settings, store, controller) = Self.makeController()
        defer { controller.releaseStatusItemsForTesting() }
        let now = Date()
        let reset = now.addingTimeInterval(3600)
        Self.setSnapshot(store, reset: reset, now: now)

        for token in [MenuBarLayoutToken.resetCountdown, .resetAbsolute] {
            let conditional = Self.conditional(token: token)
            settings.menuBarLayoutConditionals = [conditional]
            settings.menuBarLayout = MenuBarLayout(lines: [[.icon, .conditional(id: conditional.id)]])
            controller.scheduleMenuBarCountdownRefreshIfNeeded(now: now)

            #expect(controller.menuBarLayoutResetDates(for: .claude, now: now).isEmpty)
            #expect(!controller._test_isMenuBarCountdownRefreshScheduled())

            Self.setSnapshot(store, used: 100, reset: reset, now: now)
            controller.scheduleMenuBarCountdownRefreshIfNeeded(now: now)
            #expect(controller.menuBarLayoutResetDates(for: .claude, now: now) == [reset])
            #expect(controller._test_isMenuBarCountdownRefreshScheduled())
            Self.setSnapshot(store, reset: reset, now: now)
        }
    }

    @Test
    func `hidden countdown keeps its predicate boundary wakeup`() {
        let (settings, store, controller) = Self.makeController()
        defer { controller.releaseStatusItemsForTesting() }
        let now = Date()
        Self.setSnapshot(store, reset: now.addingTimeInterval(3600), now: now)
        let conditional = Self.conditional(token: .resetCountdown, metric: .sessionResetsIn, threshold: 0.5)
        settings.menuBarLayoutConditionals = [conditional]
        settings.menuBarLayout = MenuBarLayout(lines: [[.icon, .conditional(id: conditional.id)]])
        controller.scheduleMenuBarCountdownRefreshIfNeeded(now: now)

        #expect(controller.menuBarLayoutResetDates(for: .claude, now: now).isEmpty)
        #expect(controller._test_isMenuBarCountdownRefreshScheduled())
        #expect(controller.menuBarLayoutResetDates(for: .claude, now: now.addingTimeInterval(1801)).count == 1)
    }

    @Test
    func `hidden countdown keeps its predicate expiration wakeup`() {
        let (settings, store, controller) = Self.makeController()
        defer { controller.releaseStatusItemsForTesting() }
        let now = Date()
        let reset = now.addingTimeInterval(900)
        Self.setSnapshot(store, reset: reset, now: now)
        let conditional = MenuBarLayoutConditional(
            clauses: [MenuBarConditionalClause(
                combinator: nil,
                predicate: MenuBarConditionalPredicate(
                    metric: .sessionResetsIn, comparison: .lessThan, threshold: 0.5))],
            thenToken: .percent(window: .session),
            elseToken: .resetCountdown)
        settings.menuBarLayoutConditionals = [conditional]
        settings.menuBarLayout = MenuBarLayout(lines: [[.icon, .conditional(id: conditional.id)]])
        controller.scheduleMenuBarCountdownRefreshIfNeeded(now: now)

        #expect(controller.menuBarLayoutResetDates(for: .claude, now: now).isEmpty)
        #expect(controller._test_isMenuBarCountdownRefreshScheduled())
        #expect(controller.menuBarLayoutResetDates(for: .claude, now: reset.addingTimeInterval(1)) == [reset])
        controller.scheduleMenuBarCountdownRefreshIfNeeded(now: reset.addingTimeInterval(1))
        #expect(!controller._test_isMenuBarCountdownRefreshScheduled())
    }

    static func conditional(
        token: MenuBarLayoutToken,
        metric: MenuBarConditionalMetric = .session,
        threshold: Double = 95) -> MenuBarLayoutConditional
    {
        MenuBarLayoutConditional(
            clauses: [MenuBarConditionalClause(
                combinator: nil,
                predicate: MenuBarConditionalPredicate(
                    metric: metric,
                    comparison: metric == .sessionResetsIn ? .lessThan : .greaterThanOrEqual,
                    threshold: threshold))],
            thenToken: token,
            elseToken: .percent(window: .session))
    }

    static func makeController() -> (SettingsStore, UsageStore, StatusItemController) {
        let settings = testSettingsStore(
            suiteName: "MenuBarIdleCountdownTests",
            userDefaults: InMemoryUserDefaults(),
            config: testConfigWithAllProvidersDisabled())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        settings.randomBlinkEnabled = false
        settings.menuBarShowsBrandIconWithPercent = true
        enableTestProviders([.claude], settings: settings)
        let fetcher = UsageFetcher(environment: [:])
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: testStatusBar())
        return (settings, store, controller)
    }

    static func setSnapshot(_ store: UsageStore, used: Double = 40, reset: Date, now: Date) {
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(usedPercent: used, windowMinutes: 300, resetsAt: reset, resetDescription: nil),
                secondary: nil,
                updatedAt: now),
            provider: .claude)
    }
}
