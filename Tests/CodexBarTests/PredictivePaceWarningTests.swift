import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct PredictivePaceWarningTests {
    @MainActor
    final class NotifierSpy: SessionQuotaNotifying {
        struct PredictivePost {
            let event: PredictivePaceWarningEvent
            let provider: UsageProvider
            let soundEnabled: Bool
            let onScreenAlertEnabled: Bool
            let now: Date
        }

        private(set) var quotaWarningPosts: [(
            event: QuotaWarningEvent,
            provider: UsageProvider,
            soundEnabled: Bool,
            onScreenAlertEnabled: Bool)] = []
        private(set) var predictivePosts: [PredictivePost] = []

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

        func postPredictivePaceWarning(
            event: PredictivePaceWarningEvent,
            provider: UsageProvider,
            soundEnabled: Bool,
            onScreenAlertEnabled: Bool,
            now: Date)
        {
            self.predictivePosts.append(PredictivePost(
                event: event,
                provider: provider,
                soundEnabled: soundEnabled,
                onScreenAlertEnabled: onScreenAlertEnabled,
                now: now))
        }
    }

    @Test
    func `predictive pace warnings default off and persist when enabled`() throws {
        let suite = "PredictivePaceWarningTests-default-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = self.makeSettings(suiteName: suite, clear: false)

        #expect(settings.predictivePaceWarningNotificationsEnabled == false)
        #expect(defaults.object(forKey: "predictivePaceWarningNotificationsEnabled") == nil)

        settings.predictivePaceWarningNotificationsEnabled = true

        #expect(defaults.bool(forKey: "predictivePaceWarningNotificationsEnabled") == true)
        #expect(self.makeSettings(suiteName: suite, clear: false).predictivePaceWarningNotificationsEnabled == true)
    }

    @Test
    func `predictive pace preference refreshes background work only when it changes`() {
        let settings = self.makeSettings(suiteName: "PredictivePaceWarningTests-settings-revision")
        let initialRevision = settings.backgroundWorkSettingsRevision

        settings.predictivePaceWarningNotificationsEnabled = true
        #expect(settings.backgroundWorkSettingsRevision == initialRevision + 1)

        settings.predictivePaceWarningNotificationsEnabled = true
        #expect(settings.backgroundWorkSettingsRevision == initialRevision + 1)

        settings.predictivePaceWarningNotificationsEnabled = false
        #expect(settings.backgroundWorkSettingsRevision == initialRevision + 2)
    }

    @Test
    func `predictive only settings expose delivery controls without threshold editors`() {
        let disabled = QuotaWarningSettingsVisibility(
            thresholdWarningsEnabled: false,
            predictiveWarningsEnabled: false)
        #expect(!disabled.showsThresholdControls)
        #expect(!disabled.showsDeliveryControls)

        let predictiveOnly = QuotaWarningSettingsVisibility(
            thresholdWarningsEnabled: false,
            predictiveWarningsEnabled: true)
        #expect(!predictiveOnly.showsThresholdControls)
        #expect(predictiveOnly.showsDeliveryControls)

        let thresholdWarnings = QuotaWarningSettingsVisibility(
            thresholdWarningsEnabled: true,
            predictiveWarningsEnabled: false)
        #expect(thresholdWarnings.showsThresholdControls)
        #expect(thresholdWarnings.showsDeliveryControls)
    }

    @Test
    func `trigger only accepts at risk pace with positive eta and confident probability`() {
        #expect(PredictivePaceWarningNotificationLogic.shouldNotify(pace: self.pace(
            willLastToReset: false,
            etaSeconds: 60,
            runOutProbability: nil)))
        #expect(PredictivePaceWarningNotificationLogic.shouldNotify(pace: self.pace(
            willLastToReset: false,
            etaSeconds: 60,
            runOutProbability: 0.5)))
        #expect(!PredictivePaceWarningNotificationLogic.shouldNotify(pace: self.pace(
            willLastToReset: true,
            etaSeconds: 60,
            runOutProbability: nil)))
        #expect(!PredictivePaceWarningNotificationLogic.shouldNotify(pace: self.pace(
            willLastToReset: false,
            etaSeconds: nil,
            runOutProbability: nil)))
        #expect(!PredictivePaceWarningNotificationLogic.shouldNotify(pace: self.pace(
            willLastToReset: false,
            etaSeconds: 0,
            runOutProbability: nil)))
        #expect(!PredictivePaceWarningNotificationLogic.shouldNotify(pace: self.pace(
            willLastToReset: false,
            etaSeconds: 60,
            runOutProbability: 0.49)))
    }

    @Test
    func `state machine suppresses repeats until authoritative recovery`() {
        let key = PredictivePaceWarningStateKey(
            provider: .claude,
            accountDiscriminator: "email:person@example.com",
            window: .session,
            resetWindow: self.resetWindow(minutes: 300, resetsAt: 1_780_000_000))
        var notifiedKeys: Set<PredictivePaceWarningStateKey> = []

        #expect(PredictivePaceWarningNotificationLogic.recordObservation(
            key: key,
            pace: self.pace(willLastToReset: false, etaSeconds: 60),
            notifiedKeys: &notifiedKeys))
        #expect(!PredictivePaceWarningNotificationLogic.recordObservation(
            key: key,
            pace: self.pace(willLastToReset: false, etaSeconds: 60),
            notifiedKeys: &notifiedKeys))
        #expect(!PredictivePaceWarningNotificationLogic.recordObservation(
            key: key,
            pace: self.pace(willLastToReset: false, etaSeconds: 60, runOutProbability: 0.2),
            notifiedKeys: &notifiedKeys))
        #expect(notifiedKeys.contains(key))

        #expect(!PredictivePaceWarningNotificationLogic.recordObservation(
            key: key,
            pace: self.pace(willLastToReset: true, etaSeconds: nil),
            notifiedKeys: &notifiedKeys))
        #expect(!notifiedKeys.contains(key))
        #expect(PredictivePaceWarningNotificationLogic.recordObservation(
            key: key,
            pace: self.pace(willLastToReset: false, etaSeconds: 60),
            notifiedKeys: &notifiedKeys))
    }

    @Test
    func `new reset window identity is independent and prunes expired sibling key`() {
        var notifiedKeys: Set<PredictivePaceWarningStateKey> = []
        let oldKey = PredictivePaceWarningStateKey(
            provider: .claude,
            accountDiscriminator: "email:person@example.com",
            window: .weekly,
            resetWindow: self.resetWindow(minutes: 10080, resetsAt: 1_780_000_000))
        let newKey = PredictivePaceWarningStateKey(
            provider: .claude,
            accountDiscriminator: "email:person@example.com",
            window: .weekly,
            resetWindow: self.resetWindow(minutes: 10080, resetsAt: 1_780_604_800))

        #expect(PredictivePaceWarningNotificationLogic.recordObservation(
            key: oldKey,
            pace: self.pace(willLastToReset: false, etaSeconds: 60),
            notifiedKeys: &notifiedKeys))
        PredictivePaceWarningNotificationLogic.reconcileSiblingWindowKeys(
            activeKey: newKey,
            notifiedKeys: &notifiedKeys)
        #expect(!notifiedKeys.contains(oldKey))
        #expect(PredictivePaceWarningNotificationLogic.recordObservation(
            key: newKey,
            pace: self.pace(willLastToReset: false, etaSeconds: 60),
            notifiedKeys: &notifiedKeys))
    }

    @Test
    func `provider account and window risk episodes are isolated`() {
        let keys = [
            PredictivePaceWarningStateKey(
                provider: .claude,
                accountDiscriminator: "account-a",
                window: .session,
                resetWindow: self.resetWindow(minutes: 300, resetsAt: 1_780_000_000)),
            PredictivePaceWarningStateKey(
                provider: .claude,
                accountDiscriminator: "account-a",
                window: .weekly,
                resetWindow: self.resetWindow(minutes: 10080, resetsAt: 1_780_000_000)),
            PredictivePaceWarningStateKey(
                provider: .claude,
                accountDiscriminator: "account-b",
                window: .session,
                resetWindow: self.resetWindow(minutes: 300, resetsAt: 1_780_000_000)),
            PredictivePaceWarningStateKey(
                provider: .codex,
                accountDiscriminator: "account-a",
                window: .session,
                resetWindow: self.resetWindow(minutes: 300, resetsAt: 1_780_000_000)),
        ]
        var notifiedKeys: Set<PredictivePaceWarningStateKey> = []

        for key in keys {
            #expect(PredictivePaceWarningNotificationLogic.recordObservation(
                key: key,
                pace: self.pace(willLastToReset: false, etaSeconds: 60),
                notifiedKeys: &notifiedKeys))
        }
        for key in keys {
            #expect(!PredictivePaceWarningNotificationLogic.recordObservation(
                key: key,
                pace: self.pace(willLastToReset: false, etaSeconds: 60),
                notifiedKeys: &notifiedKeys))
        }
        #expect(notifiedKeys == Set(keys))
    }

    @Test
    func `reset time jitter follows the same risk episode without repeating`() {
        let firstKey = PredictivePaceWarningStateKey(
            provider: .codex,
            accountDiscriminator: "account-a",
            window: .session,
            resetWindow: self.resetWindow(minutes: 300, resetsAt: 1_780_000_000))
        let correctedKey = PredictivePaceWarningStateKey(
            provider: .codex,
            accountDiscriminator: "account-a",
            window: .session,
            resetWindow: self.resetWindow(minutes: 300, resetsAt: 1_780_000_120))
        var notifiedKeys: Set<PredictivePaceWarningStateKey> = []

        #expect(PredictivePaceWarningNotificationLogic.recordObservation(
            key: firstKey,
            pace: self.pace(willLastToReset: false, etaSeconds: 60),
            notifiedKeys: &notifiedKeys))
        PredictivePaceWarningNotificationLogic.reconcileSiblingWindowKeys(
            activeKey: correctedKey,
            notifiedKeys: &notifiedKeys)
        #expect(!PredictivePaceWarningNotificationLogic.recordObservation(
            key: correctedKey,
            pace: self.pace(willLastToReset: false, etaSeconds: 60),
            notifiedKeys: &notifiedKeys))
        #expect(notifiedKeys == Set([correctedKey]))

        PredictivePaceWarningNotificationLogic.reconcileSiblingWindowKeys(
            activeKey: correctedKey,
            notifiedKeys: &notifiedKeys)
        #expect(!PredictivePaceWarningNotificationLogic.recordObservation(
            key: correctedKey,
            pace: self.pace(willLastToReset: true, etaSeconds: nil),
            notifiedKeys: &notifiedKeys))
        #expect(notifiedKeys.isEmpty)
    }

    @Test
    func `store posts once for Claude session and weekly risk then re-arms after recovery`() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let settings = self.makeSettings(suiteName: "PredictivePaceWarningTests-claude-store")
        settings.predictivePaceWarningNotificationsEnabled = true
        settings.quotaWarningSoundEnabled = false
        settings.quotaWarningOnScreenAlertEnabled = true
        let notifier = NotifierSpy()
        let store = self.makeStore(settings: settings, notifier: notifier)

        let atRisk = self.snapshot(
            now: now,
            sessionUsed: 80,
            weeklyUsed: 90,
            accountEmail: "person@example.com")
        store.handlePredictivePaceWarningTransitions(provider: .claude, snapshot: atRisk)
        store.handlePredictivePaceWarningTransitions(provider: .claude, snapshot: atRisk)

        #expect(notifier.predictivePosts.map(\.event.window) == [.session, .weekly])
        #expect(notifier.predictivePosts.allSatisfy { $0.provider == .claude })
        #expect(notifier.predictivePosts.allSatisfy { $0.soundEnabled == false })
        #expect(notifier.predictivePosts.allSatisfy { $0.onScreenAlertEnabled == true })
        #expect(notifier.predictivePosts.allSatisfy { $0.event.accountDisplayName == "person@example.com" })

        let jitteredAtRisk = self.snapshot(
            now: now.addingTimeInterval(120),
            sessionUsed: 80,
            weeklyUsed: 90,
            accountEmail: "person@example.com")
        store.handlePredictivePaceWarningTransitions(provider: .claude, snapshot: jitteredAtRisk)
        #expect(notifier.predictivePosts.map(\.event.window) == [.session, .weekly])

        let recovered = self.snapshot(
            now: now,
            sessionUsed: 20,
            weeklyUsed: 20,
            accountEmail: "person@example.com")
        store.handlePredictivePaceWarningTransitions(provider: .claude, snapshot: recovered)
        store.handlePredictivePaceWarningTransitions(provider: .claude, snapshot: atRisk)

        #expect(notifier.predictivePosts.map(\.event.window) == [.session, .weekly, .session, .weekly])
    }

    @Test
    func `missing incomplete and failed observations preserve warned state`() async {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let settings = self.makeSettings(suiteName: "PredictivePaceWarningTests-preserve-state")
        settings.predictivePaceWarningNotificationsEnabled = true
        let notifier = NotifierSpy()
        let store = self.makeStore(settings: settings, notifier: notifier)
        let atRisk = self.snapshot(
            now: now,
            sessionUsed: 80,
            weeklyUsed: 90,
            accountEmail: "person@example.com")

        store.handlePredictivePaceWarningTransitions(provider: .claude, snapshot: atRisk)
        #expect(notifier.predictivePosts.map(\.event.window) == [.session, .weekly])

        let incomplete = UsageSnapshot(
            primary: nil,
            secondary: nil,
            updatedAt: now,
            identity: ProviderIdentitySnapshot(
                providerID: .claude,
                accountEmail: "person@example.com",
                accountOrganization: nil,
                loginMethod: nil))
        store.handlePredictivePaceWarningTransitions(provider: .claude, snapshot: incomplete)

        let missingIdentity = self.snapshot(
            now: now,
            sessionUsed: 80,
            weeklyUsed: 90,
            accountEmail: nil)
        store.handlePredictivePaceWarningTransitions(provider: .claude, snapshot: missingIdentity)

        await store.applySelectedOutcome(
            ProviderFetchOutcome(
                result: .failure(ProviderFetchError.noAvailableStrategy(.claude)),
                attempts: []),
            provider: .claude,
            account: nil,
            fallbackSnapshot: atRisk)

        store.handlePredictivePaceWarningTransitions(provider: .claude, snapshot: atRisk)
        #expect(notifier.predictivePosts.map(\.event.window) == [.session, .weekly])
    }

    @Test
    func `new store starts with memory only warning state`() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let settings = self.makeSettings(suiteName: "PredictivePaceWarningTests-memory-only")
        settings.predictivePaceWarningNotificationsEnabled = true
        let snapshot = self.snapshot(
            now: now,
            sessionUsed: 80,
            weeklyUsed: 20,
            accountEmail: "person@example.com")
        let firstNotifier = NotifierSpy()
        let firstStore = self.makeStore(settings: settings, notifier: firstNotifier)
        firstStore.handlePredictivePaceWarningTransitions(provider: .claude, snapshot: snapshot)
        firstStore.handlePredictivePaceWarningTransitions(provider: .claude, snapshot: snapshot)
        #expect(firstNotifier.predictivePosts.count == 1)

        let secondNotifier = NotifierSpy()
        let secondStore = self.makeStore(settings: settings, notifier: secondNotifier)
        secondStore.handlePredictivePaceWarningTransitions(provider: .claude, snapshot: snapshot)
        #expect(secondNotifier.predictivePosts.count == 1)
    }

    @Test
    func `store posts for Codex session and weekly risk`() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let settings = self.makeSettings(suiteName: "PredictivePaceWarningTests-codex-store")
        settings.predictivePaceWarningNotificationsEnabled = true
        let notifier = NotifierSpy()
        let store = self.makeStore(settings: settings, notifier: notifier)

        let atRisk = self.snapshot(
            now: now,
            sessionUsed: 80,
            weeklyUsed: 90,
            accountEmail: "codex@example.com",
            provider: .codex)
        store.handlePredictivePaceWarningTransitions(provider: .codex, snapshot: atRisk)
        store.handlePredictivePaceWarningTransitions(provider: .codex, snapshot: atRisk)

        #expect(notifier.predictivePosts.map(\.event.window) == [.session, .weekly])
        #expect(notifier.predictivePosts.allSatisfy { $0.provider == .codex })
        #expect(notifier.predictivePosts.allSatisfy { $0.event.accountDisplayName == "codex@example.com" })
    }

    @Test
    func `store isolates risk episodes by account`() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let settings = self.makeSettings(suiteName: "PredictivePaceWarningTests-account-isolation")
        settings.predictivePaceWarningNotificationsEnabled = true
        let notifier = NotifierSpy()
        let store = self.makeStore(settings: settings, notifier: notifier)

        let firstAccount = self.snapshot(
            now: now,
            sessionUsed: 80,
            weeklyUsed: 20,
            accountEmail: "first@example.com")
        let secondAccount = self.snapshot(
            now: now,
            sessionUsed: 80,
            weeklyUsed: 20,
            accountEmail: "second@example.com")

        store.handlePredictivePaceWarningTransitions(provider: .claude, snapshot: firstAccount)
        store.handlePredictivePaceWarningTransitions(provider: .claude, snapshot: firstAccount)
        store.handlePredictivePaceWarningTransitions(provider: .claude, snapshot: secondAccount)
        store.handlePredictivePaceWarningTransitions(provider: .claude, snapshot: firstAccount)

        #expect(notifier.predictivePosts.map(\.event.window) == [.session, .session])
        #expect(notifier.predictivePosts.map(\.event.accountDisplayName) == [
            "first@example.com",
            "second@example.com",
        ])
    }

    @Test
    func `stable Claude account identity spans OAuth and CLI observations`() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let settings = self.makeSettings(suiteName: "PredictivePaceWarningTests-claude-active-account")
        settings.predictivePaceWarningNotificationsEnabled = true
        let notifier = NotifierSpy()
        let store = self.makeStore(settings: settings, notifier: notifier)
        let firstAccount = UsageStore.warningClaudeAccountDiscriminator(
            strategyKind: .oauth,
            observation: .stable(identity: "account-a"))
        let secondAccount = UsageStore.warningClaudeAccountDiscriminator(
            strategyKind: .cli,
            observation: .stable(identity: "account-b"))
        #expect(UsageStore.warningClaudeAccountDiscriminator(
            strategyKind: .oauth,
            observation: .stable(identity: nil)) == nil)
        #expect(UsageStore.warningClaudeAccountDiscriminator(
            strategyKind: .cli,
            observation: .changed) == nil)
        #expect(UsageStore.warningClaudeAccountDiscriminator(
            strategyKind: .web,
            observation: .stable(identity: "account-a")) == nil)
        #expect(UsageStore.warningClaudeAccountDiscriminator(
            strategyKind: .apiToken,
            observation: .stable(identity: "account-a")) == nil)
        let noEmailRisk = self.snapshot(
            now: now,
            sessionUsed: 80,
            weeklyUsed: 20,
            accountEmail: nil)
        let emailRisk = self.snapshot(
            now: now,
            sessionUsed: 80,
            weeklyUsed: 20,
            accountEmail: "person@example.com")
        let emailRecovery = self.snapshot(
            now: now,
            sessionUsed: 20,
            weeklyUsed: 20,
            accountEmail: "person@example.com")

        store.handlePredictivePaceWarningTransitions(
            provider: .claude,
            snapshot: noEmailRisk,
            accountDiscriminatorOverride: firstAccount)
        store.handlePredictivePaceWarningTransitions(
            provider: .claude,
            snapshot: emailRisk,
            accountDiscriminatorOverride: firstAccount)
        store.handlePredictivePaceWarningTransitions(
            provider: .claude,
            snapshot: emailRecovery,
            accountDiscriminatorOverride: firstAccount)
        store.handlePredictivePaceWarningTransitions(
            provider: .claude,
            snapshot: noEmailRisk,
            accountDiscriminatorOverride: firstAccount)
        store.handlePredictivePaceWarningTransitions(
            provider: .claude,
            snapshot: noEmailRisk,
            accountDiscriminatorOverride: secondAccount)

        #expect(notifier.predictivePosts.map(\.event.window) == [.session, .session, .session])
        #expect(notifier.predictivePosts.allSatisfy { $0.provider == .claude })
    }

    @Test
    func `Claude OAuth owner keeps no email warnings account scoped when active metadata is missing`() {
        let owner = String(repeating: "a", count: 64)

        #expect(UsageStore.warningClaudeAccountDiscriminator(
            strategyKind: .oauth,
            observation: .stable(identity: nil),
            oauthHistoryOwnerIdentifier: owner) == "claude-oauth-owner:\(owner)")
        #expect(UsageStore.warningClaudeAccountDiscriminator(
            strategyKind: .oauth,
            observation: .changed,
            oauthHistoryOwnerIdentifier: "  \(owner.uppercased())  ") == "claude-oauth-owner:\(owner)")
        #expect(UsageStore.warningClaudeAccountDiscriminator(
            strategyKind: .cli,
            observation: .stable(identity: nil),
            oauthHistoryOwnerIdentifier: owner) == nil)
        #expect(UsageStore.warningClaudeAccountDiscriminator(
            strategyKind: .web,
            observation: .stable(identity: nil),
            oauthHistoryOwnerIdentifier: owner) == nil)
    }

    @Test
    func `selected Claude account identity is stable across OAuth owner changes`() async throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let settings = self.makeSettings(suiteName: "PredictivePaceWarningTests-selected-claude-account")
        settings.predictivePaceWarningNotificationsEnabled = true
        let firstAccount = try ProviderTokenAccount(
            id: #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001")),
            label: "First",
            token: "token",
            addedAt: 0,
            lastUsed: nil)
        let secondAccount = try ProviderTokenAccount(
            id: #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002")),
            label: "Second",
            token: "token",
            addedAt: 0,
            lastUsed: nil)
        let notifier = NotifierSpy()
        let store = self.makeStore(settings: settings, notifier: notifier)
        let snapshot = self.snapshot(
            now: now,
            sessionUsed: 80,
            weeklyUsed: 20,
            accountEmail: nil)

        await store.applySelectedOutcome(
            self.claudeOAuthOutcome(snapshot: snapshot, ownerIdentifier: "owner-a"),
            provider: .claude,
            account: firstAccount,
            fallbackSnapshot: nil)
        await store.applySelectedOutcome(
            self.claudeOAuthOutcome(snapshot: snapshot, ownerIdentifier: "owner-b"),
            provider: .claude,
            account: firstAccount,
            fallbackSnapshot: nil)
        await store.applySelectedOutcome(
            self.claudeOAuthOutcome(snapshot: snapshot, ownerIdentifier: "owner-b"),
            provider: .claude,
            account: secondAccount,
            fallbackSnapshot: nil)

        #expect(notifier.predictivePosts.map(\.event.window) == [.session, .session])
        #expect(notifier.predictivePosts.allSatisfy { $0.provider == .claude })
        #expect(notifier.predictivePosts.map(\.event.accountDisplayName) == ["First", "Second"])
    }

    @Test
    func `store keeps identity out of copy when personal info is hidden`() throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let settings = self.makeSettings(suiteName: "PredictivePaceWarningTests-hidden-info")
        settings.predictivePaceWarningNotificationsEnabled = true
        settings.hidePersonalInfo = true
        let notifier = NotifierSpy()
        let store = self.makeStore(settings: settings, notifier: notifier)

        store.handlePredictivePaceWarningTransitions(
            provider: .claude,
            snapshot: self.snapshot(
                now: now,
                sessionUsed: 80,
                weeklyUsed: 20,
                accountEmail: "person@example.com"))

        #expect(notifier.predictivePosts.first?.event.accountDisplayName == nil)
        let copy = try PredictivePaceWarningNotificationLogic.notificationCopy(
            providerName: "Claude",
            event: #require(notifier.predictivePosts.first?.event),
            now: now)
        #expect(!copy.body.contains("person@example.com"))
    }

    @Test
    func `store ignores providers outside accepted scope`() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let settings = self.makeSettings(suiteName: "PredictivePaceWarningTests-scope")
        settings.predictivePaceWarningNotificationsEnabled = true
        let notifier = NotifierSpy()
        let store = self.makeStore(settings: settings, notifier: notifier)

        store.handlePredictivePaceWarningTransitions(
            provider: .zai,
            snapshot: self.snapshot(now: now, sessionUsed: 80, weeklyUsed: 90, accountEmail: "person@example.com"))

        #expect(notifier.predictivePosts.isEmpty)
    }

    @Test
    func `store ignores unsupported tertiary windows`() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let settings = self.makeSettings(suiteName: "PredictivePaceWarningTests-window-scope")
        settings.predictivePaceWarningNotificationsEnabled = true
        let notifier = NotifierSpy()
        let store = self.makeStore(settings: settings, notifier: notifier)
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            tertiary: RateWindow(
                usedPercent: 90,
                windowMinutes: 30 * 24 * 60,
                resetsAt: now.addingTimeInterval(2 * 24 * 3600),
                resetDescription: nil),
            updatedAt: now,
            identity: ProviderIdentitySnapshot(
                providerID: .claude,
                accountEmail: "person@example.com",
                accountOrganization: nil,
                loginMethod: nil))

        store.handlePredictivePaceWarningTransitions(provider: .claude, snapshot: snapshot)

        #expect(notifier.predictivePosts.isEmpty)
    }

    private func makeSettings(suiteName: String, clear: Bool = true) -> SettingsStore {
        let defaults = UserDefaults(suiteName: suiteName)!
        if clear {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suiteName),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore(),
            tokenAccountStore: InMemoryTokenAccountStore())
    }

    private func makeStore(settings: SettingsStore, notifier: NotifierSpy) -> UsageStore {
        UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            sessionQuotaNotifier: notifier)
    }

    private func claudeOAuthOutcome(snapshot: UsageSnapshot, ownerIdentifier: String) -> ProviderFetchOutcome {
        ProviderFetchOutcome(
            result: .success(ProviderFetchResult(
                usage: snapshot,
                credits: nil,
                dashboard: nil,
                sourceLabel: "oauth",
                strategyID: "claude-oauth",
                strategyKind: .oauth,
                claudeOAuthHistoryOwnerIdentifier: ownerIdentifier)),
            attempts: [])
    }

    private func snapshot(
        now: Date,
        sessionUsed: Double,
        weeklyUsed: Double,
        accountEmail: String?,
        provider: UsageProvider = .claude) -> UsageSnapshot
    {
        UsageSnapshot(
            primary: RateWindow(
                usedPercent: sessionUsed,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(2 * 3600),
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: weeklyUsed,
                windowMinutes: 7 * 24 * 60,
                resetsAt: now.addingTimeInterval(2 * 24 * 3600),
                resetDescription: nil),
            updatedAt: now,
            identity: ProviderIdentitySnapshot(
                providerID: provider,
                accountEmail: accountEmail,
                accountOrganization: nil,
                loginMethod: nil))
    }

    private func pace(
        willLastToReset: Bool,
        etaSeconds: TimeInterval?,
        runOutProbability: Double? = nil) -> UsagePace
    {
        UsagePace(
            stage: willLastToReset ? .onTrack : .ahead,
            deltaPercent: willLastToReset ? 0 : 20,
            expectedUsedPercent: 50,
            actualUsedPercent: willLastToReset ? 40 : 70,
            etaSeconds: etaSeconds,
            willLastToReset: willLastToReset,
            runOutProbability: runOutProbability)
    }

    private func resetWindow(minutes: Int?, resetsAt: TimeInterval) -> PredictivePaceWarningResetWindow {
        PredictivePaceWarningResetWindow(
            windowMinutes: minutes,
            resetsAt: Date(timeIntervalSince1970: resetsAt))
    }
}
