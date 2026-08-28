import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
@Suite("Claude synthetic session placeholder notifications")
struct ClaudeSyntheticPlaceholderNotificationTests {
    private let start = Date(timeIntervalSince1970: 1_780_000_000)

    @Test
    func `placeholder preserves depleted state without a reset boundary`() {
        let notifier = NotifierSpy()
        let store = self.makeStore(
            suiteName: "ClaudeSyntheticPlaceholderNotificationTests-depleted-no-boundary",
            notifier: notifier)

        store.handleSessionQuotaTransition(provider: .claude, snapshot: self.snapshot(sessionUsed: 20))
        store.handleSessionQuotaTransition(provider: .claude, snapshot: self.snapshot(sessionUsed: 100))
        store.handleSessionQuotaTransition(
            provider: .claude,
            snapshot: self.snapshot(sessionUsed: 0, sessionIsSyntheticPlaceholder: true))
        store.handleSessionQuotaTransition(provider: .claude, snapshot: self.snapshot(sessionUsed: 100))

        #expect(notifier.transitions == [.depleted])
        #expect(store.sessionQuotaTransitionStates[.claude]?.remaining == 0)
    }

    @Test
    func `placeholder stays non authoritative after the prior boundary elapses`() {
        let notifier = NotifierSpy()
        let store = self.makeStore(
            suiteName: "ClaudeSyntheticPlaceholderNotificationTests-depleted-elapsed-boundary",
            notifier: notifier)
        let boundary = self.start.addingTimeInterval(5 * 60)

        store.handleSessionQuotaTransition(
            provider: .claude,
            snapshot: self.snapshot(sessionUsed: 20, sessionReset: boundary))
        store.handleSessionQuotaTransition(
            provider: .claude,
            snapshot: self.snapshot(sessionUsed: 100, sessionReset: boundary, secondsAfterStart: 60))
        store.handleSessionQuotaTransition(
            provider: .claude,
            snapshot: self.snapshot(
                sessionUsed: 0,
                sessionReset: boundary,
                sessionIsSyntheticPlaceholder: true,
                secondsAfterStart: 6 * 60))
        store.handleSessionQuotaTransition(
            provider: .claude,
            snapshot: self.snapshot(sessionUsed: 100, sessionReset: boundary, secondsAfterStart: 7 * 60))

        #expect(notifier.transitions == [.depleted])
        #expect(store.sessionQuotaTransitionStates[.claude]?.remaining == 0)
    }

    @Test
    func `placeholder cannot rearm depletion while notifications are disabled`() {
        let notifier = NotifierSpy()
        let store = self.makeStore(
            suiteName: "ClaudeSyntheticPlaceholderNotificationTests-disabled",
            notifier: notifier)

        store.handleSessionQuotaTransition(provider: .claude, snapshot: self.snapshot(sessionUsed: 20))
        store.handleSessionQuotaTransition(provider: .claude, snapshot: self.snapshot(sessionUsed: 100))

        store.settings.sessionQuotaNotificationsEnabled = false
        store.handleSessionQuotaTransition(
            provider: .claude,
            snapshot: self.snapshot(sessionUsed: 0, sessionIsSyntheticPlaceholder: true))
        store.settings.sessionQuotaNotificationsEnabled = true
        store.handleSessionQuotaTransition(provider: .claude, snapshot: self.snapshot(sessionUsed: 100))

        #expect(notifier.transitions == [.depleted])
        #expect(store.sessionQuotaTransitionStates[.claude]?.remaining == 0)
    }

    @Test
    func `real zero usage remains an authoritative restore`() {
        let notifier = NotifierSpy()
        let store = self.makeStore(
            suiteName: "ClaudeSyntheticPlaceholderNotificationTests-real-zero",
            notifier: notifier)

        store.handleSessionQuotaTransition(provider: .claude, snapshot: self.snapshot(sessionUsed: 20))
        store.handleSessionQuotaTransition(provider: .claude, snapshot: self.snapshot(sessionUsed: 100))
        store.handleSessionQuotaTransition(provider: .claude, snapshot: self.snapshot(sessionUsed: 0))

        #expect(notifier.transitions == [.depleted, .restored])
        #expect(store.sessionQuotaTransitionStates[.claude]?.remaining == 100)
    }

    @Test
    func `placeholder preserves threshold state while weekly warnings continue`() {
        let notifier = NotifierSpy()
        let store = self.makeStore(
            suiteName: "ClaudeSyntheticPlaceholderNotificationTests-threshold",
            notifier: notifier)
        store.settings.quotaWarningNotificationsEnabled = true
        store.settings.quotaWarningThresholds = [50]
        store.settings.setQuotaWarningWindowEnabled(.session, enabled: true)
        store.settings.setQuotaWarningWindowEnabled(.weekly, enabled: true)
        let sessionReset = self.start.addingTimeInterval(2 * 60 * 60)
        let weeklyReset = self.start.addingTimeInterval(2 * 24 * 60 * 60)

        store.handleQuotaWarningTransitions(
            provider: .claude,
            snapshot: self.snapshot(
                sessionUsed: 40,
                weeklyUsed: 40,
                sessionReset: sessionReset,
                weeklyReset: weeklyReset))
        store.handleQuotaWarningTransitions(
            provider: .claude,
            snapshot: self.snapshot(
                sessionUsed: 60,
                weeklyUsed: 40,
                sessionReset: sessionReset,
                weeklyReset: weeklyReset,
                secondsAfterStart: 60))
        store.handleQuotaWarningTransitions(
            provider: .claude,
            snapshot: self.snapshot(
                sessionUsed: 0,
                weeklyUsed: 60,
                sessionReset: sessionReset,
                weeklyReset: weeklyReset,
                sessionIsSyntheticPlaceholder: true,
                secondsAfterStart: 120))
        store.handleQuotaWarningTransitions(
            provider: .claude,
            snapshot: self.snapshot(
                sessionUsed: 60,
                weeklyUsed: 60,
                sessionReset: sessionReset,
                weeklyReset: weeklyReset,
                secondsAfterStart: 180))

        #expect(notifier.quotaWarnings.map(\.window) == [.session, .weekly])
        #expect(notifier.quotaWarnings.map(\.threshold) == [50, 50])
    }

    @Test
    func `placeholder preserves predictive episode while weekly risk continues`() {
        let notifier = NotifierSpy()
        let store = self.makeStore(
            suiteName: "ClaudeSyntheticPlaceholderNotificationTests-predictive",
            notifier: notifier)
        store.settings.predictivePaceWarningNotificationsEnabled = true
        let sessionReset = self.start.addingTimeInterval(2 * 60 * 60)
        let weeklyReset = self.start.addingTimeInterval(2 * 24 * 60 * 60)

        store.handlePredictivePaceWarningTransitions(
            provider: .claude,
            snapshot: self.snapshot(
                sessionUsed: 80,
                weeklyUsed: 20,
                sessionReset: sessionReset,
                weeklyReset: weeklyReset))
        store.handlePredictivePaceWarningTransitions(
            provider: .claude,
            snapshot: self.snapshot(
                sessionUsed: 0,
                weeklyUsed: 90,
                sessionReset: sessionReset,
                weeklyReset: weeklyReset,
                sessionIsSyntheticPlaceholder: true,
                secondsAfterStart: 60))
        store.handlePredictivePaceWarningTransitions(
            provider: .claude,
            snapshot: self.snapshot(
                sessionUsed: 80,
                weeklyUsed: 90,
                sessionReset: sessionReset,
                weeklyReset: weeklyReset,
                secondsAfterStart: 120))

        #expect(notifier.predictiveWarnings == [.session, .weekly])
    }

    private func makeStore(suiteName: String, notifier: NotifierSpy) -> UsageStore {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suiteName),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.sessionQuotaNotificationsEnabled = true
        return UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            sessionQuotaNotifier: notifier)
    }

    private func snapshot(
        sessionUsed: Double,
        weeklyUsed: Double = 20,
        sessionReset: Date? = nil,
        weeklyReset: Date? = nil,
        sessionIsSyntheticPlaceholder: Bool = false,
        secondsAfterStart: TimeInterval = 0) -> UsageSnapshot
    {
        UsageSnapshot(
            primary: RateWindow(
                usedPercent: sessionUsed,
                windowMinutes: 5 * 60,
                resetsAt: sessionReset,
                resetDescription: nil,
                isSyntheticPlaceholder: sessionIsSyntheticPlaceholder),
            secondary: RateWindow(
                usedPercent: weeklyUsed,
                windowMinutes: 7 * 24 * 60,
                resetsAt: weeklyReset,
                resetDescription: nil),
            updatedAt: self.start.addingTimeInterval(secondsAfterStart),
            identity: ProviderIdentitySnapshot(
                providerID: .claude,
                accountEmail: "placeholder@example.com",
                accountOrganization: nil,
                loginMethod: "web"))
    }
}

@MainActor
private final class NotifierSpy: SessionQuotaNotifying {
    private(set) var transitions: [SessionQuotaTransition] = []
    private(set) var quotaWarnings: [QuotaWarningEvent] = []
    private(set) var predictiveWarnings: [QuotaWarningWindow] = []

    func post(transition: SessionQuotaTransition, provider _: UsageProvider, badge _: NSNumber?) {
        self.transitions.append(transition)
    }

    func postQuotaWarning(
        event: QuotaWarningEvent,
        provider _: UsageProvider,
        soundEnabled _: Bool,
        onScreenAlertEnabled _: Bool)
    {
        self.quotaWarnings.append(event)
    }

    func postPredictivePaceWarning(
        event: PredictivePaceWarningEvent,
        provider _: UsageProvider,
        soundEnabled _: Bool,
        onScreenAlertEnabled _: Bool,
        now _: Date)
    {
        self.predictiveWarnings.append(event.window)
    }
}
