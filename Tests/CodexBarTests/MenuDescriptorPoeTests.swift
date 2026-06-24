import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct MenuDescriptorPoeTests {
    @Test
    func `poe balance renders as balance text not plan label`() throws {
        let suite = "MenuDescriptorPoeTests-balance"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            tertiary: nil,
            providerCost: nil,
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: .poe,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: "Balance: 1,500 points"))
        store._setSnapshotForTesting(snapshot, provider: .poe)

        let descriptor = MenuDescriptor.build(
            provider: .poe,
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updateReady: false,
            includeContextualActions: false)

        let textLines = descriptor.sections
            .flatMap(\.entries)
            .compactMap { entry -> String? in
                guard case let .text(text, _) = entry else { return nil }
                return text
            }

        #expect(textLines.contains(where: { $0.contains("Balance: 1,500 points") }))
        #expect(!textLines.contains(where: { $0.contains("Plan: Balance:") }))
    }

    @Test
    func `poe usage history renders today week month and top breakdown`() throws {
        let suite = "MenuDescriptorPoeTests-history"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)

        let now = Date()
        let history = PoeUsageHistorySnapshot(
            entries: [
                .init(
                    id: "a",
                    createdAt: now.addingTimeInterval(-1000),
                    model: "GPT-4o",
                    usageType: "chat",
                    points: 100,
                    costUSD: nil),
                .init(
                    id: "b",
                    createdAt: now.addingTimeInterval(-86000),
                    model: "Claude-3.7-Sonnet",
                    usageType: "chat",
                    points: 200,
                    costUSD: nil),
            ],
            daily: [
                .init(day: "2026-05-30", points: 200, requests: 1, costUSD: nil),
                .init(day: "2026-05-31", points: 100, requests: 1, costUSD: nil),
            ],
            updatedAt: now)

        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            tertiary: nil,
            providerCost: nil,
            poeUsage: history,
            updatedAt: now,
            identity: ProviderIdentitySnapshot(
                providerID: .poe,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: "Balance: 300 points"))
        store._setSnapshotForTesting(snapshot, provider: .poe)

        let descriptor = MenuDescriptor.build(
            provider: .poe,
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updateReady: false,
            includeContextualActions: false)

        let textLines = descriptor.sections
            .flatMap(\.entries)
            .compactMap { entry -> String? in
                guard case let .text(text, _) = entry else { return nil }
                return text
            }

        #expect(textLines.contains(where: { $0.contains("Today: 100 points") }))
        #expect(textLines.contains(where: { $0.contains("7d: 300 points") }))
        #expect(textLines.contains(where: { $0.contains("30d: 300 points") }))
        #expect(textLines.contains(where: { $0.contains("Top model: Claude-3.7-Sonnet") }))
        #expect(textLines.contains(where: { $0.contains("Usage mix: chat: 300 points") }))
        #expect(textLines.contains(where: { $0.contains("Recent activity:") }))
    }
}
