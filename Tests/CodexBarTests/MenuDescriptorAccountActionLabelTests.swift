import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct MenuDescriptorAccountActionLabelTests {
    @Test
    func `claude shows Switch Account when usage exists without email`() throws {
        let suite = "MenuDescriptorAccountActionLabelTests-claude-usage-no-email"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual

        let registry = ProviderRegistry.shared
        if let claudeMeta = registry.metadata[.claude] {
            settings.setProviderEnabled(provider: .claude, metadata: claudeMeta, enabled: true)
        }

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)

        let identity = ProviderIdentitySnapshot(
            providerID: .claude,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: nil)
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 5, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            updatedAt: Date(),
            identity: identity)
        store._setSnapshotForTesting(snapshot, provider: .claude)

        let descriptor = MenuDescriptor.build(
            provider: .claude,
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updateReady: false,
            includeContextualActions: true)

        let actionTitles = descriptor.sections.flatMap(\.entries).compactMap { entry -> String? in
            if case let .action(title, _) = entry { return title }
            return nil
        }
        #expect(actionTitles.contains("Switch Account..."))
        #expect(!actionTitles.contains("Add Account..."))
    }

    @Test
    func `claude shows Add Account when no usage snapshot`() throws {
        let suite = "MenuDescriptorAccountActionLabelTests-claude-empty"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual

        let registry = ProviderRegistry.shared
        if let claudeMeta = registry.metadata[.claude] {
            settings.setProviderEnabled(provider: .claude, metadata: claudeMeta, enabled: true)
        }

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)

        store._setSnapshotForTesting(nil, provider: .claude)

        let descriptor = MenuDescriptor.build(
            provider: .claude,
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updateReady: false,
            includeContextualActions: true)

        let actionTitles = descriptor.sections.flatMap(\.entries).compactMap { entry -> String? in
            if case let .action(title, _) = entry { return title }
            return nil
        }
        #expect(actionTitles.contains("Add Account..."))
        #expect(!actionTitles.contains("Switch Account..."))
    }
}
