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
}
