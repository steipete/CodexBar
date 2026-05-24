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
