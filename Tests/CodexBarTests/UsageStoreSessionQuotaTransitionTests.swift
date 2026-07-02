import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

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
            soundEnabled: Bool,
            onScreenAlertEnabled: Bool)] = []

        func post(transition: SessionQuotaTransition, provider: UsageProvider, badge _: NSNumber?) {
            self.posts.append((transition: transition, provider: provider))
        }

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
    func `claude spend limit fallback does not emit session or quota warning notifications`() throws {
        let settings = self.makeSettings(suiteName: "UsageStoreSessionQuotaTransitionTests-claude-spend-limit")
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.sessionQuotaNotificationsEnabled = true
        settings.quotaWarningNotificationsEnabled = true
        settings.quotaWarningThresholds = [50, 20]

        let notifier = SessionQuotaNotifierSpy()
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            sessionQuotaNotifier: notifier)
        let json = """
        {
          "extra_usage": {
            "is_enabled": true,
            "monthly_limit": 600,
            "used_credits": 434.43,
            "utilization": 72,
            "currency": "USD"
          }
        }
        """
        let claude = try ClaudeUsageFetcher._mapOAuthUsageForTesting(
            Data(json.utf8),
            subscriptionType: "enterprise")
        let snapshot = ClaudeOAuthFetchStrategy._snapshotForTesting(from: claude)

        store.handleSessionQuotaTransition(provider: .claude, snapshot: snapshot)
        store.handleQuotaWarningTransitions(provider: .claude, snapshot: snapshot)

        #expect(snapshot.primary == nil)
        #expect(snapshot.providerCost?.period == "Spend limit")
        #expect(notifier.posts.isEmpty)
        #expect(notifier.quotaWarningPosts.isEmpty)
    }

    @Test
    func `mimo balance and monthly credits do not emit quota notifications`() {
        let settings = self.makeSettings(suiteName: "UsageStoreSessionQuotaTransitionTests-mimo-balance")
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.sessionQuotaNotificationsEnabled = true
        settings.quotaWarningNotificationsEnabled = true
        settings.quotaWarningThresholds = [50, 20]

        let notifier = SessionQuotaNotifierSpy()
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            sessionQuotaNotifier: notifier)
        let balanceSnapshot = MiMoUsageSnapshot(
            balance: 0,
            currency: "USD",
            updatedAt: Date())
            .toUsageSnapshot()
        let tokenPlanSnapshot = MiMoUsageSnapshot(
            balance: 25.51,
            currency: "USD",
            planCode: "standard",
            tokenUsed: 100,
            tokenLimit: 100,
            tokenPercent: 1,
            updatedAt: Date())
            .toUsageSnapshot()

        for snapshot in [balanceSnapshot, tokenPlanSnapshot] {
            store.handleSessionQuotaTransition(provider: .mimo, snapshot: snapshot)
            store.handleQuotaWarningTransitions(provider: .mimo, snapshot: snapshot)
        }

        #expect(notifier.posts.isEmpty)
        #expect(notifier.quotaWarningPosts.isEmpty)
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
    func `antigravity session notification uses quota summary duration instead of family representative`() {
        let settings = self.makeSettings(suiteName: "UsageStoreSessionQuotaTransitionTests-antigravity-session")
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.sessionQuotaNotificationsEnabled = true

        let notifier = SessionQuotaNotifierSpy()
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            sessionQuotaNotifier: notifier)

        store.handleSessionQuotaTransition(
            provider: .antigravity,
            snapshot: self.antigravityQuotaSummarySnapshot(sessionUsed: 20, weeklyUsed: 100))
        store.handleSessionQuotaTransition(
            provider: .antigravity,
            snapshot: self.antigravityQuotaSummarySnapshot(sessionUsed: 100, weeklyUsed: 100))

        #expect(notifier.posts.map(\.provider) == [.antigravity])
        #expect(notifier.posts.map(\.transition) == [.depleted])
    }

    @Test
    func `antigravity preserves session notifications for durationless legacy family lanes`() {
        let settings = self.makeSettings(suiteName: "UsageStoreSessionQuotaTransitionTests-antigravity-legacy-session")
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.sessionQuotaNotificationsEnabled = true

        let notifier = SessionQuotaNotifierSpy()
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            sessionQuotaNotifier: notifier)

        store.handleSessionQuotaTransition(
            provider: .antigravity,
            snapshot: self.antigravityLegacySnapshot(geminiUsed: 20, claudeUsed: 20))
        store.handleSessionQuotaTransition(
            provider: .antigravity,
            snapshot: self.antigravityLegacySnapshot(geminiUsed: 20, claudeUsed: 100))

        #expect(notifier.posts.map(\.provider) == [.antigravity])
        #expect(notifier.posts.map(\.transition) == [.depleted])
    }

    @Test
    func `antigravity snapshot mode change resets session notification baseline`() {
        let settings = self.makeSettings(suiteName: "UsageStoreSessionQuotaTransitionTests-antigravity-mode-change")
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.sessionQuotaNotificationsEnabled = true

        let notifier = SessionQuotaNotifierSpy()
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            sessionQuotaNotifier: notifier)

        store.handleSessionQuotaTransition(
            provider: .antigravity,
            snapshot: self.antigravityQuotaSummarySnapshot(sessionUsed: 20, weeklyUsed: 20))
        store.handleSessionQuotaTransition(
            provider: .antigravity,
            snapshot: self.antigravityLegacySnapshot(geminiUsed: 100, claudeUsed: 100))

        #expect(notifier.posts.isEmpty)
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
        settings.quotaWarningOnScreenAlertEnabled = true
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
                updatedAt: Date(),
                identity: ProviderIdentitySnapshot(
                    providerID: .codex,
                    accountEmail: "person@example.com",
                    accountOrganization: nil,
                    loginMethod: nil)))
        store.handleQuotaWarningTransitions(
            provider: .codex,
            snapshot: UsageSnapshot(
                primary: RateWindow(usedPercent: 55, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: Date(),
                identity: ProviderIdentitySnapshot(
                    providerID: .codex,
                    accountEmail: "person@example.com",
                    accountOrganization: nil,
                    loginMethod: nil)))
        store.handleQuotaWarningTransitions(
            provider: .codex,
            snapshot: UsageSnapshot(
                primary: RateWindow(usedPercent: 60, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: Date(),
                identity: ProviderIdentitySnapshot(
                    providerID: .codex,
                    accountEmail: "person@example.com",
                    accountOrganization: nil,
                    loginMethod: nil)))

        #expect(notifier.quotaWarningPosts.count == 1)
        #expect(notifier.quotaWarningPosts.first?.event.window == .session)
        #expect(notifier.quotaWarningPosts.first?.event.threshold == 50)
        #expect(notifier.quotaWarningPosts.first?.event.accountDisplayName == "person@example.com")
        #expect(notifier.quotaWarningPosts.first?.onScreenAlertEnabled == true)
    }

    @Test
    func `quota warning omits account when personal info is hidden`() {
        let settings = self.makeSettings(suiteName: "UsageStoreSessionQuotaTransitionTests-warning-account-hidden")
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.hidePersonalInfo = true
        settings.quotaWarningNotificationsEnabled = true
        settings.quotaWarningThresholds = [50]
        settings.setQuotaWarningWindowEnabled(.session, enabled: true)

        let notifier = SessionQuotaNotifierSpy()
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            sessionQuotaNotifier: notifier)
        let identity = ProviderIdentitySnapshot(
            providerID: .codex,
            accountEmail: "person@example.com",
            accountOrganization: nil,
            loginMethod: nil)

        store.handleQuotaWarningTransitions(
            provider: .codex,
            snapshot: UsageSnapshot(
                primary: RateWindow(usedPercent: 40, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: Date(),
                identity: identity))
        store.handleQuotaWarningTransitions(
            provider: .codex,
            snapshot: UsageSnapshot(
                primary: RateWindow(usedPercent: 55, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: Date(),
                identity: identity))

        #expect(notifier.quotaWarningPosts.count == 1)
        #expect(notifier.quotaWarningPosts.first?.event.accountDisplayName == nil)
    }

    @Test
    func `hidden quota warning markers do not disable warning notifications`() {
        let settings = self.makeSettings(suiteName: "UsageStoreSessionQuotaTransitionTests-warning-markers-hidden")
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.quotaWarningNotificationsEnabled = true
        settings.quotaWarningMarkersVisible = false
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

        #expect(notifier.quotaWarningPosts.count == 1)
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
    func `minimax quota warning posts for session and weekly windows`() {
        let settings = self.makeSettings(suiteName: "UsageStoreSessionQuotaTransitionTests-warning-minimax")
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
            provider: .minimax,
            snapshot: self.minimaxSnapshot(sessionUsed: 40, weeklyUsed: 40))
        store.handleQuotaWarningTransitions(
            provider: .minimax,
            snapshot: self.minimaxSnapshot(sessionUsed: 55, weeklyUsed: 55))

        #expect(notifier.quotaWarningPosts.map(\.provider) == [.minimax, .minimax])
        #expect(notifier.quotaWarningPosts.map(\.event.window) == [.session, .weekly])
        #expect(notifier.quotaWarningPosts.map(\.event.threshold) == [50, 50])
    }

    @Test
    func `antigravity quota warnings use named session and weekly durations`() {
        let settings = self.makeSettings(suiteName: "UsageStoreSessionQuotaTransitionTests-warning-antigravity")
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

        store.handleQuotaWarningTransitions(
            provider: .antigravity,
            snapshot: self.antigravityQuotaSummarySnapshot(sessionUsed: 40, weeklyUsed: 40))
        store.handleQuotaWarningTransitions(
            provider: .antigravity,
            snapshot: self.antigravityQuotaSummarySnapshot(sessionUsed: 60, weeklyUsed: 60))

        #expect(notifier.quotaWarningPosts.map(\.provider) == [.antigravity, .antigravity])
        #expect(notifier.quotaWarningPosts.map(\.event.window) == [.session, .weekly])
        #expect(notifier.quotaWarningPosts.map(\.event.threshold) == [50, 50])
    }

    @Test
    func `antigravity legacy quota warnings do not infer weekly from family slots`() {
        let settings = self.makeSettings(suiteName: "UsageStoreSessionQuotaTransitionTests-warning-antigravity-legacy")
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

        store.handleQuotaWarningTransitions(
            provider: .antigravity,
            snapshot: self.antigravityLegacySnapshot(geminiUsed: 40, claudeUsed: 40))
        store.handleQuotaWarningTransitions(
            provider: .antigravity,
            snapshot: self.antigravityLegacySnapshot(geminiUsed: 60, claudeUsed: 60))

        #expect(notifier.quotaWarningPosts.map(\.event.window) == [.session])
    }

    @Test
    func `antigravity quota warning mode change resets warning baseline`() {
        let settings = self.makeSettings(suiteName: "UsageStoreSessionQuotaTransitionTests-warning-antigravity-mode")
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

        store.handleQuotaWarningTransitions(
            provider: .antigravity,
            snapshot: self.antigravityQuotaSummarySnapshot(sessionUsed: 20, weeklyUsed: 20))
        store.handleQuotaWarningTransitions(
            provider: .antigravity,
            snapshot: self.antigravityLegacySnapshot(geminiUsed: 80, claudeUsed: 40))

        #expect(notifier.quotaWarningPosts.isEmpty)
        let key = UsageStore.QuotaWarningStateKey(provider: .antigravity, window: .session)
        #expect(store.quotaWarningState[key]?.lastRemaining == 20)
        #expect(store.quotaWarningState[key]?.source == .antigravityLegacy)
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

    private func minimaxSnapshot(sessionUsed: Double, weeklyUsed: Double) -> UsageSnapshot {
        let now = Date()
        return MiniMaxUsageSnapshot(
            planName: "Plus",
            availablePrompts: nil,
            currentPrompts: nil,
            remainingPrompts: nil,
            windowMinutes: nil,
            usedPercent: nil,
            resetsAt: nil,
            updatedAt: now,
            services: [
                MiniMaxServiceUsage(
                    serviceType: "text-generation",
                    windowType: "5 hours",
                    timeRange: "15:00-20:00(UTC+8)",
                    usage: Int(sessionUsed),
                    limit: 100,
                    percent: sessionUsed,
                    resetsAt: now.addingTimeInterval(3600),
                    resetDescription: "Resets in 1 hour"),
                MiniMaxServiceUsage(
                    serviceType: "text-generation",
                    windowType: "Weekly",
                    timeRange: "06/01 00:00 - 06/08 00:00(UTC+8)",
                    usage: Int(weeklyUsed),
                    limit: 100,
                    percent: weeklyUsed,
                    resetsAt: now.addingTimeInterval(6 * 24 * 3600),
                    resetDescription: "Resets in 6 days"),
            ]).toUsageSnapshot()
    }

    private func antigravityQuotaSummarySnapshot(sessionUsed: Double, weeklyUsed: Double) -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(
                usedPercent: weeklyUsed,
                windowMinutes: 7 * 24 * 60,
                resetsAt: nil,
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: sessionUsed,
                windowMinutes: 5 * 60,
                resetsAt: nil,
                resetDescription: nil),
            tertiary: nil,
            extraRateWindows: [
                NamedRateWindow(
                    id: "antigravity-quota-summary-gemini-5h",
                    title: "Gemini Models Five Hour Limit",
                    window: RateWindow(
                        usedPercent: sessionUsed,
                        windowMinutes: 5 * 60,
                        resetsAt: nil,
                        resetDescription: nil)),
                NamedRateWindow(
                    id: "antigravity-quota-summary-gemini-weekly",
                    title: "Gemini Models Weekly Limit",
                    window: RateWindow(
                        usedPercent: weeklyUsed,
                        windowMinutes: 7 * 24 * 60,
                        resetsAt: nil,
                        resetDescription: nil)),
            ],
            updatedAt: Date())
    }

    private func antigravityLegacySnapshot(geminiUsed: Double, claudeUsed: Double) -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(
                usedPercent: geminiUsed,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: claudeUsed,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: nil),
            updatedAt: Date())
    }
}
