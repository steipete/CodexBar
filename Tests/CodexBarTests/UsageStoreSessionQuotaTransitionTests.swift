import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct UsageStoreSessionQuotaTransitionTests {
    @MainActor
    final class SessionQuotaNotifierSpy: SessionQuotaNotifying {
        private(set) var posts: [(transition: SessionQuotaTransition, provider: UsageProvider)] = []

        func post(transition: SessionQuotaTransition, provider: UsageProvider, badge _: NSNumber?) {
            self.posts.append((transition: transition, provider: provider))
        }
    }

    @Test
    func `copilot switch from primary to secondary resets baseline`() {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "UsageStoreSessionQuotaTransitionTests-primary-secondary"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.sessionQuotaNotificationsEnabled = true

        let notifier = SessionQuotaNotifierSpy()
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            sessionQuotaNotifier: notifier)

        let primarySnapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 20, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date())
        store.handleSessionQuotaTransition(provider: .copilot, snapshot: primarySnapshot)

        let secondarySnapshot = UsageSnapshot(
            primary: nil,
            secondary: RateWindow(usedPercent: 100, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            updatedAt: Date())
        store.handleSessionQuotaTransition(provider: .copilot, snapshot: secondarySnapshot)

        #expect(notifier.posts.isEmpty)
    }

    @Test
    func `copilot switch from secondary to primary resets baseline`() {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "UsageStoreSessionQuotaTransitionTests-secondary-primary"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.sessionQuotaNotificationsEnabled = true

        let notifier = SessionQuotaNotifierSpy()
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            sessionQuotaNotifier: notifier)

        let secondarySnapshot = UsageSnapshot(
            primary: nil,
            secondary: RateWindow(usedPercent: 20, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            updatedAt: Date())
        store.handleSessionQuotaTransition(provider: .copilot, snapshot: secondarySnapshot)

        let primarySnapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 100, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date())
        store.handleSessionQuotaTransition(provider: .copilot, snapshot: primarySnapshot)

        #expect(notifier.posts.isEmpty)
    }

    /// Regression for https://github.com/steipete/CodexBar/pull/741: when the
    /// Claude OAuth response is missing the `five_hour` window,
    /// `ClaudeUsageFetcher` promotes a weekly window into `primary` so the menu
    /// bar still renders. That weekly window MUST NOT drive session-quota
    /// depleted/restored notifications, because it does not represent the 5h
    /// session lane.
    @Test
    func `claude weekly primary fallback does not emit session quota notifications`() {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "UsageStoreSessionQuotaTransitionTests-claude-weekly-fallback"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.sessionQuotaNotificationsEnabled = true

        let notifier = SessionQuotaNotifierSpy()
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            sessionQuotaNotifier: notifier)

        let weeklyMinutes = 7 * 24 * 60

        // First snapshot: weekly-as-primary at 20% used — establishes baseline.
        let first = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 20,
                windowMinutes: weeklyMinutes,
                resetsAt: nil,
                resetDescription: nil),
            secondary: nil,
            updatedAt: Date())
        store.handleSessionQuotaTransition(provider: .claude, snapshot: first)

        // Second snapshot: weekly-as-primary crosses into depleted territory.
        // Under the old code this would fire a spurious session-depleted
        // notification; with the session-window guard it must stay silent.
        let second = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 100,
                windowMinutes: weeklyMinutes,
                resetsAt: nil,
                resetDescription: nil),
            secondary: nil,
            updatedAt: Date())
        store.handleSessionQuotaTransition(provider: .claude, snapshot: second)

        #expect(notifier.posts.isEmpty)
    }

    /// Sanity check: a genuine 5h session window still drives notifications so
    /// the guard introduced above is not over-broad.
    @Test
    func `claude five hour primary still emits session quota notifications`() {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "UsageStoreSessionQuotaTransitionTests-claude-five-hour"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.sessionQuotaNotificationsEnabled = true

        let notifier = SessionQuotaNotifierSpy()
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            sessionQuotaNotifier: notifier)

        let sessionMinutes = 5 * 60

        let baseline = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 20,
                windowMinutes: sessionMinutes,
                resetsAt: nil,
                resetDescription: nil),
            secondary: nil,
            updatedAt: Date())
        store.handleSessionQuotaTransition(provider: .claude, snapshot: baseline)

        let depleted = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 100,
                windowMinutes: sessionMinutes,
                resetsAt: nil,
                resetDescription: nil),
            secondary: nil,
            updatedAt: Date())
        store.handleSessionQuotaTransition(provider: .claude, snapshot: depleted)

        #expect(notifier.posts.contains(where: { $0.provider == .claude }))
    }
}
