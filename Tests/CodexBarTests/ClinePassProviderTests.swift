import Foundation
import SwiftUI
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct ClinePassProviderTests {
    @Test
    func `provider appears in settings with API key field and official icon`() throws {
        let suite = "ClinePassProviderTests-settings"
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
        let implementation = ClinePassProviderImplementation()
        let context = ProviderSettingsContext(
            provider: .clinepass,
            settings: settings,
            store: store,
            boolBinding: { keyPath in
                Binding(
                    get: { settings[keyPath: keyPath] },
                    set: { settings[keyPath: keyPath] = $0 })
            },
            stringBinding: { keyPath in
                Binding(
                    get: { settings[keyPath: keyPath] },
                    set: { settings[keyPath: keyPath] = $0 })
            },
            statusText: { _ in nil },
            setStatusText: { _, _ in },
            lastAppActiveRunAt: { _ in nil },
            setLastAppActiveRunAt: { _, _ in },
            requestConfirmation: { _ in },
            runLoginFlow: {})

        #expect(settings.orderedProviders().contains(.clinepass))
        #expect(ProviderCatalog.implementation(for: .clinepass)?.id == .clinepass)
        #expect(ProviderDescriptorRegistry.descriptor(for: .clinepass).branding.iconResourceName ==
            "ProviderIcon-clinepass")
        #expect(!implementation.isAvailable(context: ProviderAvailabilityContext(
            provider: .clinepass,
            settings: settings,
            environment: [:])))

        let field = try #require(implementation.settingsFields(context: context).first)
        #expect(field.id == "clinepass-api-key")
        #expect(field.kind == .secure)

        field.binding.wrappedValue = "clinepass-test-key"

        #expect(settings.clinePassAPIKey == "clinepass-test-key")
        #expect(settings.providerConfig(for: .clinepass)?.sanitizedAPIKey == "clinepass-test-key")
        #expect(implementation.isAvailable(context: ProviderAvailabilityContext(
            provider: .clinepass,
            settings: settings,
            environment: [:])))
    }
}
