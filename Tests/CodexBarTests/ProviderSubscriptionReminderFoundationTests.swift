import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite(.serialized)
@MainActor
struct ProviderSubscriptionReminderFoundationTests {
    @Test
    func `provider config round-trips manual subscription snapshot`() throws {
        let now = Date(timeIntervalSince1970: 1_720_000_000)
        let renewsAt = now.addingTimeInterval(7 * 24 * 60 * 60)
        let snapshot = ProviderSubscriptionSnapshot(
            provider: .minimax,
            planName: "Max Monthly",
            status: .active,
            subscriptionRenewsAt: renewsAt,
            subscriptionExpiresAt: nil,
            source: .manual,
            confidence: .manual,
            updatedAt: now)
        let config = CodexBarConfig(providers: [
            ProviderConfig(id: .minimax, subscriptionSnapshot: snapshot),
        ])

        let encoded = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(CodexBarConfig.self, from: encoded)
        let restored = try #require(decoded.providerConfig(for: .minimax)?.subscriptionSnapshot)

        #expect(restored.provider == .minimax)
        #expect(restored.planName == "Max Monthly")
        #expect(restored.status == .active)
        #expect(restored.subscriptionRenewsAt == renewsAt)
        #expect(restored.subscriptionExpiresAt == nil)
        #expect(restored.source == .manual)
        #expect(restored.confidence == .manual)
    }

    @Test
    func `documented ISO-8601 subscription dates decode from config JSON`() throws {
        let json = """
        {
          "version": 1,
          "providers": [
            {
              "id": "minimax",
              "subscriptionSnapshot": {
                "provider": "minimax",
                "planName": "Monthly",
                "status": "active",
                "subscriptionRenewsAt": "2026-06-24T00:00:00Z",
                "subscriptionExpiresAt": null,
                "source": "manual",
                "confidence": "manual",
                "updatedAt": "2026-05-24T00:00:00Z"
              }
            }
          ]
        }
        """
        let decoded = try JSONDecoder().decode(CodexBarConfig.self, from: Data(json.utf8))
        let snapshot = try #require(decoded.providerConfig(for: .minimax)?.subscriptionSnapshot)

        #expect(snapshot.subscriptionRenewsAt != nil)
        #expect(snapshot.updatedAt != Date(timeIntervalSince1970: 0))
    }

    @Test
    func `manual subscription reminders still evaluate on token account failure`() async throws {
        let suite = "ProviderSubscriptionReminderFoundationTests-failure-reminder-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false

        let expiresToday = Date()
        settings.setProviderSubscriptionSnapshot(
            provider: .minimax,
            snapshot: ProviderSubscriptionSnapshot(
                provider: .minimax,
                planName: "Monthly",
                status: .canceled,
                subscriptionRenewsAt: nil,
                subscriptionExpiresAt: expiresToday,
                updatedAt: Date()))

        let notifier = SubscriptionReminderNotifierSpy()
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            sessionQuotaNotifier: notifier,
            startupBehavior: .testing)

        let outcome = ProviderFetchOutcome(
            result: .failure(ProviderFetchError.noAvailableStrategy(.minimax)),
            attempts: [])
        await store.applySelectedOutcome(
            outcome,
            provider: .minimax,
            account: nil,
            fallbackSnapshot: nil)

        #expect(notifier.reminders.contains(where: { $0.provider == .minimax && $0.event.type == .expiresToday }))
    }

    @Test
    func `subscription formatter handles renews expires and expired states`() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_720_000_000)
        let sixDays = try #require(calendar.date(byAdding: .day, value: 6, to: now))
        let today = now
        let past = try #require(calendar.date(byAdding: .day, value: -2, to: now))

        let renews = ProviderSubscriptionSnapshot(
            provider: .minimax,
            planName: "Monthly",
            status: .active,
            subscriptionRenewsAt: today,
            subscriptionExpiresAt: nil,
            updatedAt: now)
        #expect(ProviderSubscriptionFormatter.menuLine(from: renews, now: now, calendar: calendar) == "Renews today")

        let expiresSoon = ProviderSubscriptionSnapshot(
            provider: .minimax,
            planName: "Monthly",
            status: .canceled,
            subscriptionRenewsAt: nil,
            subscriptionExpiresAt: sixDays,
            updatedAt: now)
        #expect(
            ProviderSubscriptionFormatter.menuLine(from: expiresSoon, now: now, calendar: calendar) ==
                "Expires in 6 days")

        let expired = ProviderSubscriptionSnapshot(
            provider: .minimax,
            planName: "Monthly",
            status: .canceled,
            subscriptionRenewsAt: nil,
            subscriptionExpiresAt: past,
            updatedAt: now)
        #expect(
            ProviderSubscriptionFormatter.menuLine(from: expired, now: now, calendar: calendar)?
                .hasPrefix("Expired ") == true)
    }

    @Test
    func `reminder logic emits threshold events once and dedupes`() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_720_000_000)
        let inSevenDays = try #require(calendar.date(byAdding: .day, value: 7, to: now))
        let snapshot = ProviderSubscriptionSnapshot(
            provider: .minimax,
            planName: "Monthly",
            status: .canceled,
            subscriptionRenewsAt: nil,
            subscriptionExpiresAt: inSevenDays,
            updatedAt: now)

        let first = ProviderSubscriptionReminderLogic.evaluate(
            providerName: "MiniMax",
            snapshot: snapshot,
            previous: nil,
            now: now,
            calendar: calendar)
        #expect(first.events.count == 1)
        #expect(first.events.first?.type == .expiresIn7Days)

        let second = ProviderSubscriptionReminderLogic.evaluate(
            providerName: "MiniMax",
            snapshot: snapshot,
            previous: first.state,
            now: now,
            calendar: calendar)
        #expect(second.events.isEmpty)
    }

    @Test
    func `fired reminder state persists across app relaunch and dedupes correctly`() throws {
        let suite = "ProviderSubscriptionReminderFoundationTests-relaunch-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        let calendar = Calendar(identifier: .gregorian)
        let now = Date()
        let inSevenDays = try #require(calendar.date(byAdding: .day, value: 7, to: now))

        let originalSettings = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        originalSettings.statusChecksEnabled = false
        originalSettings.setProviderSubscriptionSnapshot(
            provider: .minimax,
            snapshot: ProviderSubscriptionSnapshot(
                provider: .minimax,
                planName: "Monthly",
                status: .canceled,
                subscriptionRenewsAt: nil,
                subscriptionExpiresAt: inSevenDays,
                updatedAt: now))

        let originalNotifier = SubscriptionReminderNotifierSpy()
        let originalStore = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: originalSettings,
            sessionQuotaNotifier: originalNotifier,
            startupBehavior: .testing)

        originalStore.handleProviderSubscriptionReminders(provider: .minimax)
        #expect(originalNotifier.reminders.count == 1)
        #expect(originalNotifier.reminders.first?.event.type == .expiresIn7Days)

        let configBeforeSave = originalSettings.configSnapshot
        try configStore.save(configBeforeSave)

        let reloadedConfig = try configStore.load()
        #expect(reloadedConfig != nil)
        let stateInReloaded = reloadedConfig?.providerConfig(for: .minimax)?.subscriptionReminderState?["minimax"]
        #expect(stateInReloaded?.fired.contains(.expiresIn7Days) == true)

        let relaunchedSettings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite, reset: false),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        relaunchedSettings.statusChecksEnabled = false

        let stateFromRelaunched = relaunchedSettings.providerSubscriptionReminderState(for: .minimax)
        #expect(stateFromRelaunched?.fired.contains(.expiresIn7Days) == true)

        let snapshotFromRelaunched = relaunchedSettings.providerSubscriptionSnapshot(for: .minimax)
        #expect(snapshotFromRelaunched != nil)

        let relaunchedNotifier = SubscriptionReminderNotifierSpy()
        let relaunchedStore = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: relaunchedSettings,
            sessionQuotaNotifier: relaunchedNotifier,
            startupBehavior: .testing)

        relaunchedStore.handleProviderSubscriptionReminders(provider: .minimax)

        let dedupeWorks = relaunchedNotifier.reminders.isEmpty
        #expect(dedupeWorks == true)
    }

    @Test
    func `menu descriptor shows subscription line separate from quota rows`() throws {
        let suite = "ProviderSubscriptionReminderFoundationTests-menu-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        let expiresAt = Date().addingTimeInterval(7 * 24 * 60 * 60)
        settings.setProviderSubscriptionSnapshot(
            provider: .minimax,
            snapshot: ProviderSubscriptionSnapshot(
                provider: .minimax,
                planName: "Monthly",
                status: .canceled,
                subscriptionRenewsAt: nil,
                subscriptionExpiresAt: expiresAt,
                updatedAt: Date(timeIntervalSince1970: 1_720_000_000)))

        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(usedPercent: 20, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: RateWindow(usedPercent: 40, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
                updatedAt: Date()),
            provider: .minimax)

        let descriptor = MenuDescriptor.build(
            provider: .minimax,
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updateReady: false,
            includeContextualActions: false)

        let lines = Self.textLines(from: descriptor)
        #expect(lines.contains(where: { $0.hasPrefix("Subscription: Expires in 7 days") }))
        #expect(!lines.contains(where: { $0.hasPrefix("Subscription: Resets ") }))
    }

    @Test
    func `usage reset formatting remains unchanged`() {
        let line = UsageFormatter.resetLine(
            for: RateWindow(
                usedPercent: 10,
                windowMinutes: 300,
                resetsAt: Date(timeIntervalSince1970: 1_720_000_000 + 3600),
                resetDescription: nil),
            style: .countdown,
            now: Date(timeIntervalSince1970: 1_720_000_000))
        #expect(line?.hasPrefix("Resets in 1h") == true)
    }

    private static func textLines(from descriptor: MenuDescriptor) -> [String] {
        descriptor.sections.flatMap { section in
            section.entries.compactMap { entry in
                if case let .text(text, _) = entry { return text }
                return nil
            }
        }
    }
}

@MainActor
private final class SubscriptionReminderNotifierSpy: SessionQuotaNotifying {
    private(set) var transitions: [(transition: SessionQuotaTransition, provider: UsageProvider)] = []
    private(set) var quotaWarnings: [(event: QuotaWarningEvent, provider: UsageProvider, soundEnabled: Bool)] = []
    private(set) var reminders: [(provider: UsageProvider, event: ProviderSubscriptionReminderEvent)] = []

    func post(transition: SessionQuotaTransition, provider: UsageProvider, badge _: NSNumber?) {
        self.transitions.append((transition, provider))
    }

    func postQuotaWarning(event: QuotaWarningEvent, provider: UsageProvider, soundEnabled: Bool) {
        self.quotaWarnings.append((event, provider, soundEnabled))
    }

    func postProviderSubscriptionReminder(
        provider: UsageProvider,
        event: ProviderSubscriptionReminderEvent,
        badge _: NSNumber?)
    {
        self.reminders.append((provider, event))
    }
}
