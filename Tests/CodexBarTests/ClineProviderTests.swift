import Foundation
import SwiftUI
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct ClineProviderTests {
    @Test
    func `provider appears in settings with API key field and cline icon`() throws {
        let suite = "ClineProviderTests-settings"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let implementation = ClineProviderImplementation()
        let context = ProviderSettingsContext(
            provider: .cline,
            settings: settings,
            store: store,
            statusText: { _ in nil },
            setStatusText: { _, _ in },
            lastAppActiveRunAt: { _ in nil },
            setLastAppActiveRunAt: { _, _ in },
            requestConfirmation: { _ in },
            runLoginFlow: {})

        #expect(settings.orderedProviders().contains(.cline))
        #expect(ProviderCatalog.implementation(for: .cline)?.id == .cline)
        #expect(ProviderDescriptorRegistry.descriptor(for: .cline).branding.iconResourceName == "ProviderIcon-cline")

        let field = try #require(implementation.settingsFields(context: context).first)
        #expect(field.id == "cline-api-key")
        #expect(field.kind == .secure)
    }
}
