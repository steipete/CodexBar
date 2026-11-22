import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct FamilyQuotaWarningPersistenceTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private final class Notifier: SessionQuotaNotifying {
        var warnings: [QuotaWarningEvent] = []

        func post(transition _: SessionQuotaTransition, provider _: UsageProvider, badge _: NSNumber?) {}

        func postQuotaWarning(
            event: QuotaWarningEvent,
            provider _: UsageProvider,
            soundEnabled _: Bool,
            onScreenAlertEnabled _: Bool)
        {
            self.warnings.append(event)
        }
    }

    private func makeStore(defaults: UserDefaults, notifier: Notifier) -> UsageStore {
        let settings = testSettingsStore(suiteName: "family-warning", userDefaults: defaults)
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.quotaWarningNotificationsEnabled = true
        settings.quotaWarningThresholds = [50, 20, 10]
        settings.setQuotaWarningWindowEnabled(.weekly, enabled: true)
        settings.setQuotaWarningWindowEnabled(.session, enabled: true)
        return UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            sessionQuotaNotifier: notifier,
            startupBehavior: .testing)
    }

    private func snapshot(
        gemini: Double = 94,
        claude: Double = 16,
        fable: Double = 88,
        now: Date = Self.now,
        reset: Date = Self.now.addingTimeInterval(1000)) -> UsageSnapshot
    {
        let rows = [
            ("gemini", "Gemini weekly", gemini),
            ("3p", "Claude/GPT weekly", claude),
            ("fable", "Fictional Fable weekly", fable),
        ].map { id, title, remaining in
            NamedRateWindow(
                id: "antigravity-quota-summary-\(id)-weekly",
                title: title,
                window: RateWindow(
                    usedPercent: 100 - remaining,
                    windowMinutes: 10080,
                    resetsAt: reset,
                    resetDescription: nil))
        }
        return UsageSnapshot(
            primary: nil,
            secondary: rows[1].window,
            extraRateWindows: rows,
            updatedAt: now,
            identity: ProviderIdentitySnapshot(
                providerID: .antigravity,
                accountEmail: "quota-fixture@example.com",
                accountOrganization: nil,
                loginMethod: nil))
    }

    @Test
    func `each family warns independently and names its allowance`() throws {
        let notifier = Notifier()
        let store = self.makeStore(defaults: InMemoryUserDefaults(), notifier: notifier)
        store.handleQuotaWarningTransitions(provider: .antigravity, snapshot: self.snapshot(gemini: 19, fable: 9))
        #expect(notifier.warnings.count == 3)
        #expect(Set(notifier.warnings.compactMap(\.windowDisplayLabel)) == [
            "Gemini weekly", "Claude/GPT weekly", "Fictional Fable weekly",
        ])
        #expect(Set(notifier.warnings.compactMap(\.windowID)).count == 3)
        let warning = try #require(notifier.warnings.first { $0.currentRemaining == 16 })
        let copy = QuotaWarningNotificationLogic.notificationCopy(
            providerName: "Antigravity",
            window: warning.window,
            threshold: warning.threshold,
            currentRemaining: warning.currentRemaining,
            windowDisplayLabel: warning.windowDisplayLabel)
        #expect(copy.title.contains("Claude/GPT"))
        #expect(copy.body.contains("16%"))
    }

    @Test
    func `five hour families are separate and unknown usage is never a low quota`() {
        let notifier = Notifier()
        let store = self.makeStore(defaults: InMemoryUserDefaults(), notifier: notifier)
        let low = RateWindow(usedPercent: 85, windowMinutes: 300, resetsAt: nil, resetDescription: nil)
        let rows = [
            NamedRateWindow(id: "antigravity-quota-summary-gemini-5h", title: "Gemini 5-hour", window: low),
            NamedRateWindow(
                id: "antigravity-quota-summary-3p-5h", title: "Claude/GPT 5-hour", window: low, usageKnown: false),
        ]
        store.handleQuotaWarningTransitions(
            provider: .antigravity,
            snapshot: UsageSnapshot(primary: low, secondary: nil, extraRateWindows: rows, updatedAt: Self.now))
        #expect(notifier.warnings.map(\.window) == [.session])
        #expect(notifier.warnings.first?.windowDisplayLabel == "Gemini 5-hour")
    }

    @Test
    func `persisted warning survives a new store but a lower threshold still warns`() throws {
        let defaults = InMemoryUserDefaults()
        let first = Notifier()
        self.makeStore(defaults: defaults, notifier: first)
            .handleQuotaWarningTransitions(provider: .antigravity, snapshot: self.snapshot())
        #expect(first.warnings.count == 1)
        let data = try #require(defaults.data(forKey: UsageStore.quotaWarningStateDefaultsKey))
        let reloadedDefaults = InMemoryUserDefaults(values: [UsageStore.quotaWarningStateDefaultsKey: data])
        let second = Notifier()
        let restarted = self.makeStore(defaults: reloadedDefaults, notifier: second)
        restarted.handleQuotaWarningTransitions(provider: .antigravity, snapshot: self.snapshot())
        #expect(second.warnings.isEmpty)
        restarted.handleQuotaWarningTransitions(provider: .antigravity, snapshot: self.snapshot(claude: 9))
        #expect(second.warnings.map(\.threshold) == [10])
    }

    @Test
    func `missing family data and reset timestamp jitter do not repeat a warning`() {
        let notifier = Notifier()
        let store = self.makeStore(defaults: InMemoryUserDefaults(), notifier: notifier)
        store.handleQuotaWarningTransitions(provider: .antigravity, snapshot: self.snapshot())
        store.handleQuotaWarningTransitions(
            provider: .antigravity,
            snapshot: UsageSnapshot(
                primary: nil,
                secondary: self.snapshot().secondary,
                updatedAt: Self.now,
                identity: self.snapshot().identity))
        store.handleQuotaWarningTransitions(
            provider: .antigravity, snapshot: self.snapshot(reset: Self.now.addingTimeInterval(1100)))
        #expect(notifier.warnings.count == 1)
    }

    @Test
    func `new quota period or actual recovery permits a new warning`() {
        let notifier = Notifier()
        let store = self.makeStore(defaults: InMemoryUserDefaults(), notifier: notifier)
        store.handleQuotaWarningTransitions(provider: .antigravity, snapshot: self.snapshot())
        store.handleQuotaWarningTransitions(
            provider: .antigravity,
            snapshot: self.snapshot(now: Self.now.addingTimeInterval(1100), reset: Self.now.addingTimeInterval(2000)))
        #expect(notifier.warnings.count == 2)
        store.handleQuotaWarningTransitions(
            provider: .antigravity,
            snapshot: self.snapshot(claude: 30, now: Self.now.addingTimeInterval(1200)))
        store.handleQuotaWarningTransitions(
            provider: .antigravity,
            snapshot: self.snapshot(now: Self.now.addingTimeInterval(1300)))
        #expect(notifier.warnings.count == 3)
    }

    @Test
    func `account scopes and stale observations cannot interfere with warning history`() {
        let notifier = Notifier()
        let store = self.makeStore(defaults: InMemoryUserDefaults(), notifier: notifier)
        for account in ["account-a", "account-b", "account-a"] {
            store.handleQuotaWarningTransitions(
                provider: .antigravity, snapshot: self.snapshot(), accountDiscriminator: account)
        }
        #expect(notifier.warnings.count == 2)
        store.handleQuotaWarningTransitions(
            provider: .antigravity,
            snapshot: self.snapshot(claude: 100, now: Self.now.addingTimeInterval(-10)),
            accountDiscriminator: "account-a")
        store.handleQuotaWarningTransitions(
            provider: .antigravity, snapshot: self.snapshot(), accountDiscriminator: "account-a")
        #expect(notifier.warnings.count == 2)
    }

    @Test
    func `unidentified account warnings are not reused across launches`() {
        let defaults = InMemoryUserDefaults()
        let first = Notifier()
        self.makeStore(defaults: defaults, notifier: first)
            .handleQuotaWarningTransitions(provider: .gemini, snapshot: self.snapshot())
        #expect(first.warnings.count == 1)
        let second = Notifier()
        self.makeStore(defaults: defaults, notifier: second)
            .handleQuotaWarningTransitions(provider: .gemini, snapshot: self.snapshot(claude: 17))
        #expect(second.warnings.count == 1)
    }

    @Test
    func `regressed or absent reset metadata cannot rearm an existing warning`() {
        let notifier = Notifier()
        let store = self.makeStore(defaults: InMemoryUserDefaults(), notifier: notifier)
        store.handleQuotaWarningTransitions(provider: .antigravity, snapshot: self.snapshot())
        store.handleQuotaWarningTransitions(
            provider: .antigravity,
            snapshot: self.snapshot(now: Self.now.addingTimeInterval(700), reset: Self.now.addingTimeInterval(500)))
        store.handleQuotaWarningTransitions(
            provider: .antigravity,
            snapshot: self.snapshot(now: Self.now.addingTimeInterval(800)))
        for offset in [3000.0, 3100.0] {
            store.handleQuotaWarningTransitions(
                provider: .antigravity,
                snapshot: self.snapshot(
                    now: Self.now.addingTimeInterval(offset),
                    reset: Self.now.addingTimeInterval(2000)))
        }
        #expect(notifier.warnings.count == 1)
    }

    @Test
    func `switching to legacy quotas does not permanently silence future warnings`() {
        let notifier = Notifier()
        let store = self.makeStore(defaults: InMemoryUserDefaults(), notifier: notifier)
        store.handleQuotaWarningTransitions(provider: .antigravity, snapshot: self.snapshot())
        for (index, remaining) in [16.0, 100.0, 16.0].enumerated() {
            let original = self.snapshot(claude: remaining)
            let legacy = UsageSnapshot(
                primary: nil,
                secondary: original.secondary,
                updatedAt: Self.now.addingTimeInterval(Double(index + 1)),
                identity: original.identity)
            store.handleQuotaWarningTransitions(provider: .antigravity, snapshot: legacy)
        }
        #expect(notifier.warnings.count == 2)
    }

    @Test
    func `old legacy history cannot suppress a newly reported low family`() {
        let notifier = Notifier()
        let store = self.makeStore(defaults: InMemoryUserDefaults(), notifier: notifier)
        let initial = self.snapshot()
        store.handleQuotaWarningTransitions(
            provider: .antigravity,
            snapshot: UsageSnapshot(
                primary: nil, secondary: initial.secondary, updatedAt: Self.now, identity: initial.identity))
        for offset in [1.0, 2.0] {
            let summary = UsageSnapshot(
                primary: nil,
                secondary: initial.secondary,
                extraRateWindows: initial.extraRateWindows?.filter { !$0.id.contains("fable") },
                updatedAt: Self.now.addingTimeInterval(offset),
                identity: initial.identity)
            store.handleQuotaWarningTransitions(provider: .antigravity, snapshot: summary)
        }
        let before = notifier.warnings.count
        store.handleQuotaWarningTransitions(
            provider: .antigravity, snapshot: self.snapshot(fable: 19, now: Self.now.addingTimeInterval(3)))
        #expect(notifier.warnings.count == before + 1)
        #expect(notifier.warnings.last?.windowDisplayLabel == "Fictional Fable weekly")
    }

    @Test
    func `hook only refresh preserves family baselines between samples`() {
        let notifier = Notifier()
        let store = self.makeStore(defaults: InMemoryUserDefaults(), notifier: notifier)
        store.settings.quotaWarningNotificationsEnabled = false
        store.settings.setHooksEnabled(true)
        store.settings.addHookRule(HookRule(
            event: .quotaLow, provider: "antigravity", threshold: 0.99, executable: "/usr/bin/true"))
        let key = UsageStore.QuotaWarningStateKey(
            provider: .antigravity,
            window: .weekly,
            accountDiscriminator: "account-a",
            windowID: "antigravity-quota-summary-3p-weekly")
        store.handleQuotaWarningTransitions(
            provider: .antigravity, snapshot: self.snapshot(), accountDiscriminator: "account-a")
        #expect(store.quotaLowHookUsage[key] == 0.84)
        store.handleQuotaWarningTransitions(
            provider: .antigravity, snapshot: self.snapshot(claude: 15), accountDiscriminator: "account-a")
        #expect(store.quotaLowHookUsage[key] == 0.85)
        #expect(notifier.warnings.isEmpty)
    }

    @Test
    func `ordinary provider weekly warning also survives restart`() {
        let defaults = InMemoryUserDefaults()
        let first = Notifier()
        self.makeStore(defaults: defaults, notifier: first)
            .handleQuotaWarningTransitions(
                provider: .codex, snapshot: self.snapshot(), accountDiscriminator: "codex-owner-a")
        #expect(first.warnings.count == 1)
        let second = Notifier()
        self.makeStore(defaults: defaults, notifier: second)
            .handleQuotaWarningTransitions(
                provider: .codex, snapshot: self.snapshot(), accountDiscriminator: "codex-owner-a")
        #expect(second.warnings.isEmpty)
    }
}
