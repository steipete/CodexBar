import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct UsageStoreSessionQuotaTransitionTests {
    private func makeSettings(suiteName: String) -> SettingsStore {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suiteName),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
    }

    @MainActor
    final class SessionQuotaNotifierSpy: SessionQuotaNotifying {
        private(set) var posts: [(transition: SessionQuotaTransition, provider: UsageProvider)] = []
        private(set) var quotaWarningPosts: [(
            event: QuotaWarningEvent,
            provider: UsageProvider,
            soundEnabled: Bool)] = []

        func post(transition: SessionQuotaTransition, provider: UsageProvider, badge _: NSNumber?) {
            self.posts.append((transition: transition, provider: provider))
        }

        func postQuotaWarning(event: QuotaWarningEvent, provider: UsageProvider, soundEnabled: Bool) {
            self.quotaWarningPosts.append((event: event, provider: provider, soundEnabled: soundEnabled))
        }
    }

    @Test
    func `copilot switch from primary to secondary resets baseline`() {
        let settings = self.makeSettings(suiteName: "UsageStoreSessionQuotaTransitionTests-primary-secondary")
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
        let settings = self.makeSettings(suiteName: "UsageStoreSessionQuotaTransitionTests-secondary-primary")
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

    @Test
    func `claude weekly primary fallback does not emit session quota notifications`() {
        let settings = self.makeSettings(suiteName: "UsageStoreSessionQuotaTransitionTests-claude-weekly")
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.sessionQuotaNotificationsEnabled = true

        let notifier = SessionQuotaNotifierSpy()
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            sessionQuotaNotifier: notifier)

        let baseline = UsageSnapshot(
            primary: RateWindow(usedPercent: 20, windowMinutes: 7 * 24 * 60, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date())
        store.handleSessionQuotaTransition(provider: .claude, snapshot: baseline)

        let depleted = UsageSnapshot(
            primary: RateWindow(usedPercent: 100, windowMinutes: 7 * 24 * 60, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date())
        store.handleSessionQuotaTransition(provider: .claude, snapshot: depleted)

        #expect(notifier.posts.isEmpty)
    }

    @Test
    func `claude five hour primary still emits session quota notifications`() {
        let settings = self.makeSettings(suiteName: "UsageStoreSessionQuotaTransitionTests-claude-session")
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.sessionQuotaNotificationsEnabled = true

        let notifier = SessionQuotaNotifierSpy()
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            sessionQuotaNotifier: notifier)

        let baseline = UsageSnapshot(
            primary: RateWindow(usedPercent: 20, windowMinutes: 5 * 60, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date())
        store.handleSessionQuotaTransition(provider: .claude, snapshot: baseline)

        let depleted = UsageSnapshot(
            primary: RateWindow(usedPercent: 100, windowMinutes: 5 * 60, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date())
        store.handleSessionQuotaTransition(provider: .claude, snapshot: depleted)

        #expect(notifier.posts.map(\.provider) == [.claude])
    }

    @Test
    func `quota warning disabled does not post`() {
        let settings = self.makeSettings(suiteName: "UsageStoreSessionQuotaTransitionTests-warning-disabled")
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.quotaWarningNotificationsEnabled = false

        let notifier = SessionQuotaNotifierSpy()
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            sessionQuotaNotifier: notifier)

        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 90, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date())
        store.handleQuotaWarningTransitions(provider: .codex, snapshot: snapshot)

        #expect(notifier.quotaWarningPosts.isEmpty)
    }

    @Test
    func `quota warning posts once per downward threshold crossing`() {
        let settings = self.makeSettings(suiteName: "UsageStoreSessionQuotaTransitionTests-warning-once")
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.quotaWarningNotificationsEnabled = true
        settings.quotaWarningThresholds = [50, 20]
        settings.setQuotaWarningWindowEnabled(.session, enabled: true)
        settings.setQuotaWarningWindowEnabled(.weekly, enabled: true)

        let notifier = SessionQuotaNotifierSpy()
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            sessionQuotaNotifier: notifier)

        store.handleQuotaWarningTransitions(
            provider: .codex,
            snapshot: UsageSnapshot(
                primary: RateWindow(usedPercent: 40, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: Date()))
        store.handleQuotaWarningTransitions(
            provider: .codex,
            snapshot: UsageSnapshot(
                primary: RateWindow(usedPercent: 55, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: Date()))
        store.handleQuotaWarningTransitions(
            provider: .codex,
            snapshot: UsageSnapshot(
                primary: RateWindow(usedPercent: 60, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: Date()))

        #expect(notifier.quotaWarningPosts.count == 1)
        #expect(notifier.quotaWarningPosts.first?.event.window == .session)
        #expect(notifier.quotaWarningPosts.first?.event.threshold == 50)
    }

    @Test
    func `quota warning crossing multiple thresholds posts most severe only`() {
        let settings = self.makeSettings(suiteName: "UsageStoreSessionQuotaTransitionTests-warning-severe")
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.quotaWarningNotificationsEnabled = true
        settings.quotaWarningThresholds = [50, 20]
        settings.setQuotaWarningWindowEnabled(.session, enabled: true)
        settings.setQuotaWarningWindowEnabled(.weekly, enabled: true)

        let notifier = SessionQuotaNotifierSpy()
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            sessionQuotaNotifier: notifier)

        store.handleQuotaWarningTransitions(
            provider: .codex,
            snapshot: UsageSnapshot(
                primary: RateWindow(usedPercent: 10, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: Date()))
        store.handleQuotaWarningTransitions(
            provider: .codex,
            snapshot: UsageSnapshot(
                primary: RateWindow(usedPercent: 85, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: Date()))

        #expect(notifier.quotaWarningPosts.map(\.event.threshold) == [20])
    }

    @Test
    func `quota warning recovers and can fire again`() {
        let settings = self.makeSettings(suiteName: "UsageStoreSessionQuotaTransitionTests-warning-recover")
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.quotaWarningNotificationsEnabled = true
        settings.quotaWarningThresholds = [50]
        settings.setQuotaWarningWindowEnabled(.session, enabled: true)
        settings.setQuotaWarningWindowEnabled(.weekly, enabled: true)

        let notifier = SessionQuotaNotifierSpy()
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            sessionQuotaNotifier: notifier)

        for used in [40, 55, 10, 55] {
            store.handleQuotaWarningTransitions(
                provider: .codex,
                snapshot: UsageSnapshot(
                    primary: RateWindow(
                        usedPercent: Double(used),
                        windowMinutes: nil,
                        resetsAt: nil,
                        resetDescription: nil),
                    secondary: nil,
                    updatedAt: Date()))
        }

        #expect(notifier.quotaWarningPosts.map(\.event.threshold) == [50, 50])
    }

    @Test
    func `quota warning provider override beats global thresholds`() {
        let settings = self.makeSettings(suiteName: "UsageStoreSessionQuotaTransitionTests-warning-override")
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.quotaWarningNotificationsEnabled = true
        settings.quotaWarningThresholds = [50]
        settings.setQuotaWarningWindowEnabled(.session, enabled: true)
        settings.setQuotaWarningWindowEnabled(.weekly, enabled: true)
        settings.setQuotaWarningThresholds(provider: .codex, window: .session, thresholds: [10])

        let notifier = SessionQuotaNotifierSpy()
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            sessionQuotaNotifier: notifier)

        store.handleQuotaWarningTransitions(
            provider: .codex,
            snapshot: UsageSnapshot(
                primary: RateWindow(usedPercent: 40, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: Date()))
        store.handleQuotaWarningTransitions(
            provider: .codex,
            snapshot: UsageSnapshot(
                primary: RateWindow(usedPercent: 95, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: Date()))

        #expect(notifier.quotaWarningPosts.map(\.event.threshold) == [10])
    }

    @Test
    func `quota warning session only config ignores weekly crossings`() {
        let settings = self.makeSettings(suiteName: "UsageStoreSessionQuotaTransitionTests-warning-session-only")
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.quotaWarningNotificationsEnabled = true
        settings.quotaWarningThresholds = [50]
        settings.setQuotaWarningWindowEnabled(.session, enabled: true)
        settings.setQuotaWarningWindowEnabled(.weekly, enabled: false)

        let notifier = SessionQuotaNotifierSpy()
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            sessionQuotaNotifier: notifier)

        store.handleQuotaWarningTransitions(
            provider: .codex,
            snapshot: UsageSnapshot(
                primary: RateWindow(usedPercent: 40, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                secondary: RateWindow(usedPercent: 40, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                updatedAt: Date()))
        store.handleQuotaWarningTransitions(
            provider: .codex,
            snapshot: UsageSnapshot(
                primary: RateWindow(usedPercent: 60, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                secondary: RateWindow(usedPercent: 60, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                updatedAt: Date()))

        #expect(notifier.quotaWarningPosts.map(\.event.window) == [.session])
    }

    @Test
    func `quota warning weekly only config ignores session crossings`() {
        let settings = self.makeSettings(suiteName: "UsageStoreSessionQuotaTransitionTests-warning-weekly-only")
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.quotaWarningNotificationsEnabled = true
        settings.quotaWarningThresholds = [50]
        settings.setQuotaWarningWindowEnabled(.session, enabled: false)
        settings.setQuotaWarningWindowEnabled(.weekly, enabled: true)

        let notifier = SessionQuotaNotifierSpy()
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            sessionQuotaNotifier: notifier)

        store.handleQuotaWarningTransitions(
            provider: .codex,
            snapshot: UsageSnapshot(
                primary: RateWindow(usedPercent: 40, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                secondary: RateWindow(usedPercent: 40, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                updatedAt: Date()))
        store.handleQuotaWarningTransitions(
            provider: .codex,
            snapshot: UsageSnapshot(
                primary: RateWindow(usedPercent: 60, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                secondary: RateWindow(usedPercent: 60, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                updatedAt: Date()))

        #expect(notifier.quotaWarningPosts.map(\.event.window) == [.weekly])
    }

    @Test
    func `disabling quota warning window clears fired state`() {
        let settings = self
            .makeSettings(suiteName: "UsageStoreSessionQuotaTransitionTests-warning-disabled-clears-state")
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.quotaWarningNotificationsEnabled = true
        settings.quotaWarningThresholds = [50]

        let notifier = SessionQuotaNotifierSpy()
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            sessionQuotaNotifier: notifier)

        store.handleQuotaWarningTransitions(
            provider: .codex,
            snapshot: UsageSnapshot(
                primary: RateWindow(usedPercent: 40, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: Date()))
        store.handleQuotaWarningTransitions(
            provider: .codex,
            snapshot: UsageSnapshot(
                primary: RateWindow(usedPercent: 60, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: Date()))

        settings.setQuotaWarningWindowEnabled(.session, enabled: false)
        store.handleQuotaWarningTransitions(
            provider: .codex,
            snapshot: UsageSnapshot(
                primary: RateWindow(usedPercent: 60, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: Date()))

        #expect(notifier.quotaWarningPosts.count == 1)
        #expect(store.quotaWarningState[UsageStore.QuotaWarningStateKey(provider: .codex, window: .session)] == nil)
    }
}
