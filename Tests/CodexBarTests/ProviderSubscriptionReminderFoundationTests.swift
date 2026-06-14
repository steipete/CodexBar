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
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let renewsAt = try #require(calendar.date(from: DateComponents(year: 2024, month: 7, day: 10, hour: 2)))
        let snapshot = ProviderSubscriptionSnapshot(
            provider: .codex,
            planName: "Codex Plus",
            status: .active,
            subscriptionRenewsAt: renewsAt,
            subscriptionExpiresAt: nil,
            source: .manual,
            confidence: .manual,
            updatedAt: now)
        let config = CodexBarConfig(providers: [
            ProviderConfig(id: .codex, subscriptionSnapshot: snapshot),
        ])

        let encoded = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(CodexBarConfig.self, from: encoded)
        let restored = try #require(decoded.providerConfig(for: .codex)?.subscriptionSnapshot)

        #expect(restored.provider == .codex)
        #expect(restored.planName == "Codex Plus")
        #expect(restored.status == .active)
        let restoredLine = ProviderSubscriptionFormatter.menuLine(
            from: restored,
            now: now,
            calendar: calendar,
            locale: Locale(identifier: "en_US"))
        #expect(restoredLine == "Renews Jul 10, 2024")
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
              "id": "codex",
              "subscriptionSnapshot": {
                "provider": "codex",
                "planName": "Codex Plus",
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
        let snapshot = try #require(decoded.providerConfig(for: .codex)?.subscriptionSnapshot)

        #expect(snapshot.subscriptionRenewsAt != nil)
        #expect(snapshot.updatedAt != Date(timeIntervalSince1970: 0))
    }

    @Test
    func `manual subscription dates preserve calendar day across negative UTC offsets`() throws {
        let json = """
        {
          "version": 1,
          "providers": [
            {
              "id": "codex",
              "subscriptionSnapshot": {
                "provider": "codex",
                "planName": "Codex Plus",
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
        let snapshot = try #require(decoded.providerConfig(for: .codex)?.subscriptionSnapshot)
        let locale = Locale(identifier: "en_US")
        var losAngelesCalendar = Calendar(identifier: .gregorian)
        losAngelesCalendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let now = Date(timeIntervalSince1970: 1_718_928_000) // 2024-06-22T12:00:00Z

        let line = ProviderSubscriptionFormatter.menuLine(
            from: snapshot,
            now: now,
            calendar: losAngelesCalendar,
            locale: locale)

        #expect(line == "Renews Jun 24, 2026")
    }

    @Test
    func `manual subscription dates preserve calendar day across positive UTC offsets`() throws {
        let json = """
        {
          "version": 1,
          "providers": [
            {
              "id": "codex",
              "subscriptionSnapshot": {
                "provider": "codex",
                "planName": "Codex Plus",
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
        let snapshot = try #require(decoded.providerConfig(for: .codex)?.subscriptionSnapshot)
        let locale = Locale(identifier: "en_US")
        var kiritimatiCalendar = Calendar(identifier: .gregorian)
        kiritimatiCalendar.timeZone = try #require(TimeZone(identifier: "Pacific/Kiritimati"))
        let now = Date(timeIntervalSince1970: 1_718_928_000) // 2024-06-22T12:00:00Z

        let line = ProviderSubscriptionFormatter.menuLine(
            from: snapshot,
            now: now,
            calendar: kiritimatiCalendar,
            locale: locale)

        #expect(line == "Renews Jun 24, 2026")
    }

    @Test
    func `manual subscription dates encode as calendar day strings`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 6, day: 24, hour: 0)))
        let snapshot = ProviderSubscriptionSnapshot(
            provider: .codex,
            planName: "Codex Plus",
            status: .active,
            subscriptionRenewsAt: date,
            subscriptionExpiresAt: nil,
            updatedAt: Date(timeIntervalSince1970: 1_720_000_000))
        let config = CodexBarConfig(providers: [
            ProviderConfig(id: .codex, subscriptionSnapshot: snapshot),
        ])

        let encoded = try JSONEncoder().encode(config)
        let json = try #require(String(data: encoded, encoding: .utf8))

        #expect(json.contains("\"subscriptionRenewsAt\":\"2026-06-24\""))
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
            provider: .codex,
            snapshot: ProviderSubscriptionSnapshot(
                provider: .codex,
                planName: "Codex Plus",
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
            result: .failure(ProviderFetchError.noAvailableStrategy(.codex)),
            attempts: [])
        await store.applySelectedOutcome(
            outcome,
            provider: .codex,
            account: nil,
            fallbackSnapshot: nil)

        #expect(notifier.reminders.contains(where: { $0.provider == .codex && $0.event.type == .expiresToday }))
    }

    @Test
    func `subscription formatter handles renews expires and expired states`() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_720_000_000)
        let sixDays = try #require(calendar.date(byAdding: .day, value: 6, to: now))
        let today = now
        let past = try #require(calendar.date(byAdding: .day, value: -2, to: now))

        let renews = ProviderSubscriptionSnapshot(
            provider: .codex,
            planName: "Codex Plus",
            status: .active,
            subscriptionRenewsAt: today,
            subscriptionExpiresAt: nil,
            updatedAt: now)
        #expect(ProviderSubscriptionFormatter.menuLine(from: renews, now: now, calendar: calendar) == "Renews today")

        let expiresSoon = ProviderSubscriptionSnapshot(
            provider: .codex,
            planName: "Codex Plus",
            status: .canceled,
            subscriptionRenewsAt: nil,
            subscriptionExpiresAt: sixDays,
            updatedAt: now)
        #expect(
            ProviderSubscriptionFormatter.menuLine(from: expiresSoon, now: now, calendar: calendar) ==
                "Expires in 6 days")

        let expired = ProviderSubscriptionSnapshot(
            provider: .codex,
            planName: "Codex Plus",
            status: .canceled,
            subscriptionRenewsAt: nil,
            subscriptionExpiresAt: past,
            updatedAt: now)
        #expect(
            ProviderSubscriptionFormatter.menuLine(from: expired, now: now, calendar: calendar)?
                .hasPrefix("Expired ") == true)
    }

    @Test
    func `expiry takes precedence when both manual reminder dates are present`() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_720_000_000)
        let renewsSoon = try #require(calendar.date(byAdding: .day, value: 7, to: now))
        let expiresSoon = try #require(calendar.date(byAdding: .day, value: 3, to: now))
        let snapshot = ProviderSubscriptionSnapshot(
            provider: .codex,
            planName: "Codex Plus",
            status: .active,
            subscriptionRenewsAt: renewsSoon,
            subscriptionExpiresAt: expiresSoon,
            updatedAt: now)

        let menuLine = ProviderSubscriptionFormatter.menuLine(from: snapshot, now: now, calendar: calendar)
        #expect(menuLine == "Expires in 3 days")

        let result = ProviderSubscriptionReminderLogic.evaluate(
            providerName: "Codex",
            snapshot: snapshot,
            previous: nil,
            now: now,
            calendar: calendar)

        #expect(result.events.count == 1)
        #expect(result.events.first?.type == .expiresIn3Days)
    }

    @Test
    func `manual reminder save semantics collapse to active or canceled`() {
        #expect(
            CodexManualSubscriptionSectionView.effectiveStatusForSave(hasExpiresAt: false) == .active)
        #expect(
            CodexManualSubscriptionSectionView.effectiveStatusForSave(hasExpiresAt: true) == .canceled)
    }

    @Test
    func `manual expiry today remains stable across positive UTC offsets`() throws {
        let json = """
        {
          "version": 1,
          "providers": [
            {
              "id": "codex",
              "subscriptionSnapshot": {
                "provider": "codex",
                "planName": "Codex Plus",
                "status": "canceled",
                "subscriptionRenewsAt": null,
                "subscriptionExpiresAt": "2026-06-24T00:00:00Z",
                "source": "manual",
                "confidence": "manual",
                "updatedAt": "2026-05-24T00:00:00Z"
              }
            }
          ]
        }
        """
        let decoded = try JSONDecoder().decode(CodexBarConfig.self, from: Data(json.utf8))
        let snapshot = try #require(decoded.providerConfig(for: .codex)?.subscriptionSnapshot)
        let now = Date(timeIntervalSince1970: 1_782_267_600) // 2026-06-24T01:00:00Z
        var kiritimatiCalendar = Calendar(identifier: .gregorian)
        kiritimatiCalendar.timeZone = try #require(TimeZone(identifier: "Pacific/Kiritimati"))

        let line = ProviderSubscriptionFormatter.menuLine(
            from: snapshot,
            now: now,
            calendar: kiritimatiCalendar)
        let result = ProviderSubscriptionReminderLogic.evaluate(
            providerName: "Codex",
            snapshot: snapshot,
            previous: nil,
            now: now,
            calendar: kiritimatiCalendar)

        #expect(line == "Expires today")
        #expect(result.events.count == 1)
        #expect(result.events.first?.type == .expiresToday)
    }

    @Test
    func `reminder logic emits threshold events once and dedupes`() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_720_000_000)
        let inSevenDays = try #require(calendar.date(byAdding: .day, value: 7, to: now))
        let snapshot = ProviderSubscriptionSnapshot(
            provider: .codex,
            planName: "Codex Plus",
            status: .canceled,
            subscriptionRenewsAt: nil,
            subscriptionExpiresAt: inSevenDays,
            updatedAt: now)

        let first = ProviderSubscriptionReminderLogic.evaluate(
            providerName: "Codex",
            snapshot: snapshot,
            previous: nil,
            now: now,
            calendar: calendar)
        #expect(first.events.count == 1)
        #expect(first.events.first?.type == .expiresIn7Days)

        let second = ProviderSubscriptionReminderLogic.evaluate(
            providerName: "Codex",
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
            provider: .codex,
            snapshot: ProviderSubscriptionSnapshot(
                provider: .codex,
                planName: "Codex Plus",
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

        originalStore.handleProviderSubscriptionReminders(provider: .codex)
        #expect(originalNotifier.reminders.count == 1)
        #expect(originalNotifier.reminders.first?.event.type == .expiresIn7Days)

        let configBeforeSave = originalSettings.configSnapshot
        try configStore.save(configBeforeSave)

        let reloadedConfig = try configStore.load()
        #expect(reloadedConfig != nil)
        let stateInReloaded = reloadedConfig?.providerConfig(for: .codex)?.subscriptionReminderState?["codex"]
        #expect(stateInReloaded?.fired.contains(.expiresIn7Days) == true)

        let relaunchedSettings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite, reset: false),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        relaunchedSettings.statusChecksEnabled = false

        let stateFromRelaunched = relaunchedSettings.providerSubscriptionReminderState(for: .codex)
        #expect(stateFromRelaunched?.fired.contains(.expiresIn7Days) == true)

        let snapshotFromRelaunched = relaunchedSettings.providerSubscriptionSnapshot(for: .codex)
        #expect(snapshotFromRelaunched != nil)

        let relaunchedNotifier = SubscriptionReminderNotifierSpy()
        let relaunchedStore = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: relaunchedSettings,
            sessionQuotaNotifier: relaunchedNotifier,
            startupBehavior: .testing)

        relaunchedStore.handleProviderSubscriptionReminders(provider: .codex)

        let dedupeWorks = relaunchedNotifier.reminders.isEmpty
        #expect(dedupeWorks == true)
    }

    @Test
    func `unchanged subscription reminder state does not rewrite config`() throws {
        let suite = "ProviderSubscriptionReminderFoundationTests-no-rewrite-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        let inSevenDays = Date().addingTimeInterval(7 * 24 * 60 * 60)
        settings.setProviderSubscriptionSnapshot(
            provider: .codex,
            snapshot: ProviderSubscriptionSnapshot(
                provider: .codex,
                planName: "Codex Plus (manual)",
                status: .active,
                subscriptionRenewsAt: inSevenDays,
                subscriptionExpiresAt: nil,
                updatedAt: Date()))

        let notifier = SubscriptionReminderNotifierSpy()
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            sessionQuotaNotifier: notifier,
            startupBehavior: .testing)

        let revisionBefore = settings.configRevision
        store.handleProviderSubscriptionReminders(provider: .codex)
        let revisionAfterFirst = settings.configRevision
        #expect(revisionAfterFirst > revisionBefore)

        store.handleProviderSubscriptionReminders(provider: .codex)
        let revisionAfterSecond = settings.configRevision
        #expect(revisionAfterSecond == revisionAfterFirst)
    }

    @Test
    func `manual subscription metadata is ignored for non-Codex providers`() throws {
        let suite = "ProviderSubscriptionReminderFoundationTests-menu-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        let expiresAt = Date().addingTimeInterval(7 * 24 * 60 * 60)
        try configStore.save(CodexBarConfig(providers: [
            ProviderConfig(
                id: .minimax,
                subscriptionSnapshot: ProviderSubscriptionSnapshot(
                    provider: .minimax,
                    planName: "Monthly",
                    status: .canceled,
                    subscriptionRenewsAt: nil,
                    subscriptionExpiresAt: expiresAt,
                    updatedAt: Date(timeIntervalSince1970: 1_720_000_000))),
        ]))
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite, reset: false),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        #expect(settings.providerSubscriptionSnapshot(for: .minimax) == nil)

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
        #expect(lines.allSatisfy { !$0.hasPrefix("Subscription:") })
    }

    @Test
    func `menu descriptor shows manual codex renewal line`() throws {
        let suite = "ProviderSubscriptionReminderFoundationTests-codex-line-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        let renewsAt = Date().addingTimeInterval(8 * 24 * 60 * 60)
        settings.setProviderSubscriptionSnapshot(
            provider: .codex,
            snapshot: ProviderSubscriptionSnapshot(
                provider: .codex,
                planName: "Codex Plus (manual)",
                status: .active,
                subscriptionRenewsAt: renewsAt,
                subscriptionExpiresAt: nil,
                updatedAt: Date()))

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
            provider: .codex)

        let descriptor = MenuDescriptor.build(
            provider: .codex,
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updateReady: false,
            includeContextualActions: false)

        let lines = Self.textLines(from: descriptor)
        let subscriptionLines = lines.filter { $0.hasPrefix("Subscription: Renews ") }
        #expect(subscriptionLines.count == 1)
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
