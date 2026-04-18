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
}
