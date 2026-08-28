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

        let rows = try [
            ProviderDetailSection.Row(label: "Today", value: "100 points", secondaryValue: "1 requests"),
            ProviderDetailSection.Row(label: "Last 7 days", value: "300 points", secondaryValue: "2 requests"),
            ProviderDetailSection.Row(label: "Last 30 days", value: "300 points", secondaryValue: "2 requests"),
            ProviderDetailSection.Row(
                label: "Top model",
                value: "Claude-3.7-Sonnet",
                secondaryValue: "200 points"),
            ProviderDetailSection.Row(label: "Usage mix", value: "chat: 300 points"),
            ProviderDetailSection.Row(
                label: "Recent activity",
                value: "05-31 12:00 · GPT-4o",
                secondaryValue: "100 points"),
        ]
        let details = try [ProviderDetailSection(title: "Points", rows: rows)]
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            tertiary: nil,
            providerCost: nil,
            details: details,
            updatedAt: Date(),
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

        #expect(textLines.contains(where: { $0.contains("Today: 100 points · 1 requests") }))
        #expect(textLines.contains(where: { $0.contains("Last 7 days: 300 points · 2 requests") }))
        #expect(textLines.contains(where: { $0.contains("Last 30 days: 300 points · 2 requests") }))
        #expect(textLines.contains(where: { $0.contains("Top model: Claude-3.7-Sonnet · 200 points") }))
        #expect(textLines.contains(where: { $0.contains("Usage mix: chat: 300 points") }))
        #expect(textLines.contains(where: { $0.contains("Recent activity:") }))
    }
}
