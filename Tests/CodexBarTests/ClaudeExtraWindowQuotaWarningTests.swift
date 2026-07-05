import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct ClaudeExtraWindowQuotaWarningTests {
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
        private(set) var quotaWarningPosts: [(
            event: QuotaWarningEvent,
            provider: UsageProvider,
            soundEnabled: Bool,
            onScreenAlertEnabled: Bool)] = []

        func post(transition _: SessionQuotaTransition, provider _: UsageProvider, badge _: NSNumber?) {}

        func postQuotaWarning(
            event: QuotaWarningEvent,
            provider: UsageProvider,
            soundEnabled: Bool,
            onScreenAlertEnabled: Bool)
        {
            self.quotaWarningPosts.append((
                event: event,
                provider: provider,
                soundEnabled: soundEnabled,
                onScreenAlertEnabled: onScreenAlertEnabled))
        }
    }

    @Test
    func `claude scoped weekly and routines extra windows fire independent weekly warnings`() {
        let settings = self.makeSettings(suiteName: "ClaudeExtraWindowQuotaWarningTests-independent")
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
            provider: .claude,
            snapshot: self.claudeExtraWindowSnapshot(fableUsed: 40, routinesUsed: 40))
        store.handleQuotaWarningTransitions(
            provider: .claude,
            snapshot: self.claudeExtraWindowSnapshot(fableUsed: 55, routinesUsed: 55))

        #expect(notifier.quotaWarningPosts.count == 2)
        let fable = notifier.quotaWarningPosts.first { $0.event.windowID == "claude-weekly-scoped-fable" }
        let routines = notifier.quotaWarningPosts.first { $0.event.windowID == "claude-routines" }
        #expect(fable?.event.window == .weekly)
        #expect(fable?.event.threshold == 50)
        #expect(fable?.event.windowDisplayLabel == "Fable only")
        #expect(routines?.event.threshold == 50)
        #expect(routines?.event.windowDisplayLabel == "Daily Routines")

        // Each window keeps independent fired-threshold state instead of clobbering the shared weekly key.
        let fableKey = UsageStore.QuotaWarningStateKey(
            provider: .claude, window: .weekly, windowID: "claude-weekly-scoped-fable")
        let routinesKey = UsageStore.QuotaWarningStateKey(
            provider: .claude, window: .weekly, windowID: "claude-routines")
        #expect(store.quotaWarningState[fableKey]?.firedThresholds.contains(50) == true)
        #expect(store.quotaWarningState[routinesKey]?.firedThresholds.contains(50) == true)
    }

    @Test
    func `antigravity summary extra windows do not trigger the claude extra-window lane`() {
        let settings = self.makeSettings(suiteName: "ClaudeExtraWindowQuotaWarningTests-antigravity-guard")
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.quotaWarningNotificationsEnabled = true
        settings.quotaWarningThresholds = [50, 20]
        settings.setQuotaWarningWindowEnabled(.weekly, enabled: true)

        let notifier = SessionQuotaNotifierSpy()
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            sessionQuotaNotifier: notifier)

        func snapshot(used: Double) -> UsageSnapshot {
            UsageSnapshot(
                primary: nil,
                secondary: nil,
                extraRateWindows: [
                    NamedRateWindow(
                        id: "antigravity-quota-summary-model-weekly",
                        title: "Weekly",
                        window: RateWindow(
                            usedPercent: used,
                            windowMinutes: 7 * 24 * 60,
                            resetsAt: nil,
                            resetDescription: nil)),
                ],
                updatedAt: Date())
        }
        store.handleQuotaWarningTransitions(provider: .claude, snapshot: snapshot(used: 40))
        store.handleQuotaWarningTransitions(provider: .claude, snapshot: snapshot(used: 55))

        #expect(notifier.quotaWarningPosts.isEmpty)
    }

    @Test
    func `claude scoped weekly window refires after recovering above threshold`() {
        let settings = self.makeSettings(suiteName: "ClaudeExtraWindowQuotaWarningTests-refire")
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.quotaWarningNotificationsEnabled = true
        settings.quotaWarningThresholds = [50]
        settings.setQuotaWarningWindowEnabled(.weekly, enabled: true)

        let notifier = SessionQuotaNotifierSpy()
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            sessionQuotaNotifier: notifier)

        // 60% remaining -> 45% (fires 50) -> 60% (clears 50) -> 45% (refires 50).
        store.handleQuotaWarningTransitions(
            provider: .claude, snapshot: self.claudeExtraWindowSnapshot(fableUsed: 40, routinesUsed: nil))
        store.handleQuotaWarningTransitions(
            provider: .claude, snapshot: self.claudeExtraWindowSnapshot(fableUsed: 55, routinesUsed: nil))
        store.handleQuotaWarningTransitions(
            provider: .claude, snapshot: self.claudeExtraWindowSnapshot(fableUsed: 40, routinesUsed: nil))
        store.handleQuotaWarningTransitions(
            provider: .claude, snapshot: self.claudeExtraWindowSnapshot(fableUsed: 55, routinesUsed: nil))

        #expect(notifier.quotaWarningPosts.count == 2)
        #expect(notifier.quotaWarningPosts.allSatisfy { $0.event.windowID == "claude-weekly-scoped-fable" })
    }

    @Test
    func `claude extra-window fired state is pruned when a window disappears but others remain`() {
        let settings = self.makeSettings(suiteName: "ClaudeExtraWindowQuotaWarningTests-prune")
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.quotaWarningNotificationsEnabled = true
        settings.quotaWarningThresholds = [50]
        settings.setQuotaWarningWindowEnabled(.weekly, enabled: true)

        let notifier = SessionQuotaNotifierSpy()
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            sessionQuotaNotifier: notifier)

        store.handleQuotaWarningTransitions(
            provider: .claude, snapshot: self.claudeExtraWindowSnapshot(fableUsed: 40, routinesUsed: 40))
        store.handleQuotaWarningTransitions(
            provider: .claude, snapshot: self.claudeExtraWindowSnapshot(fableUsed: 55, routinesUsed: 55))
        let fableKey = UsageStore.QuotaWarningStateKey(
            provider: .claude, window: .weekly, windowID: "claude-weekly-scoped-fable")
        let routinesKey = UsageStore.QuotaWarningStateKey(
            provider: .claude, window: .weekly, windowID: "claude-routines")
        #expect(store.quotaWarningState[fableKey] != nil)
        #expect(store.quotaWarningState[routinesKey] != nil)

        // Fable ends while Routines is still present: this refresh carries authoritative extras, so
        // Fable's stale state is dropped and Routines is kept.
        store.handleQuotaWarningTransitions(
            provider: .claude, snapshot: self.claudeExtraWindowSnapshot(fableUsed: nil, routinesUsed: 55))
        #expect(store.quotaWarningState[fableKey] == nil)
        #expect(store.quotaWarningState[routinesKey] != nil)
    }

    @Test
    func `disabling weekly warnings clears all claude extra-window state`() {
        let settings = self.makeSettings(suiteName: "ClaudeExtraWindowQuotaWarningTests-disable")
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.quotaWarningNotificationsEnabled = true
        settings.quotaWarningThresholds = [50]
        settings.setQuotaWarningWindowEnabled(.weekly, enabled: true)

        let notifier = SessionQuotaNotifierSpy()
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            sessionQuotaNotifier: notifier)

        store.handleQuotaWarningTransitions(
            provider: .claude, snapshot: self.claudeExtraWindowSnapshot(fableUsed: 40, routinesUsed: 40))
        store.handleQuotaWarningTransitions(
            provider: .claude, snapshot: self.claudeExtraWindowSnapshot(fableUsed: 55, routinesUsed: 55))
        let fableKey = UsageStore.QuotaWarningStateKey(
            provider: .claude, window: .weekly, windowID: "claude-weekly-scoped-fable")
        let routinesKey = UsageStore.QuotaWarningStateKey(
            provider: .claude, window: .weekly, windowID: "claude-routines")
        #expect(store.quotaWarningState[fableKey] != nil)
        #expect(store.quotaWarningState[routinesKey] != nil)

        settings.setQuotaWarningWindowEnabled(.weekly, enabled: false)
        store.handleQuotaWarningTransitions(
            provider: .claude,
            snapshot: UsageSnapshot(primary: nil, secondary: nil, extraRateWindows: nil, updatedAt: Date()))
        #expect(store.quotaWarningState[fableKey] == nil)
        #expect(store.quotaWarningState[routinesKey] == nil)
    }

    @Test
    func `claude extra-window state survives a transient extras miss without re-posting`() {
        let settings = self.makeSettings(suiteName: "ClaudeExtraWindowQuotaWarningTests-transient-miss")
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.quotaWarningNotificationsEnabled = true
        settings.quotaWarningThresholds = [50]
        settings.setQuotaWarningWindowEnabled(.weekly, enabled: true)

        let notifier = SessionQuotaNotifierSpy()
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            sessionQuotaNotifier: notifier)

        // Fable crosses 50% and warns once.
        store.handleQuotaWarningTransitions(
            provider: .claude, snapshot: self.claudeExtraWindowSnapshot(fableUsed: 40, routinesUsed: nil))
        store.handleQuotaWarningTransitions(
            provider: .claude, snapshot: self.claudeExtraWindowSnapshot(fableUsed: 55, routinesUsed: nil))
        #expect(notifier.quotaWarningPosts.count == 1)
        let fableKey = UsageStore.QuotaWarningStateKey(
            provider: .claude, window: .weekly, windowID: "claude-weekly-scoped-fable")

        // A failed web-extras fetch delivers nil extras while the main snapshot is intact. The fired
        // state must persist so the warning is not re-posted when extras recover.
        store.handleQuotaWarningTransitions(
            provider: .claude,
            snapshot: UsageSnapshot(primary: nil, secondary: nil, extraRateWindows: nil, updatedAt: Date()))
        #expect(store.quotaWarningState[fableKey] != nil)

        store.handleQuotaWarningTransitions(
            provider: .claude, snapshot: self.claudeExtraWindowSnapshot(fableUsed: 55, routinesUsed: nil))
        #expect(notifier.quotaWarningPosts.count == 1)
    }

    private func claudeExtraWindowSnapshot(fableUsed: Double?, routinesUsed: Double?) -> UsageSnapshot {
        var windows: [NamedRateWindow] = []
        if let fableUsed {
            windows.append(NamedRateWindow(
                id: "claude-weekly-scoped-fable",
                title: "Fable only",
                window: RateWindow(
                    usedPercent: fableUsed, windowMinutes: 7 * 24 * 60, resetsAt: nil, resetDescription: nil)))
        }
        if let routinesUsed {
            windows.append(NamedRateWindow(
                id: "claude-routines",
                title: "Daily Routines",
                window: RateWindow(
                    usedPercent: routinesUsed, windowMinutes: 7 * 24 * 60, resetsAt: nil, resetDescription: nil)))
        }
        return UsageSnapshot(primary: nil, secondary: nil, extraRateWindows: windows, updatedAt: Date())
    }
}
