import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct ProviderSelectionFixtureTests {
    @Test(arguments: [nil, .codex, .claude, .gemini] as [ProviderInstanceID?])
    func `fixture selection preserves setter results and persisted fields`(_ selection: ProviderInstanceID?) throws {
        var config = testConfigWithAllProvidersDisabled()
        for index in config.providers.indices {
            switch config.providers[index].id {
            case .codex:
                config.providers[index].enabled = nil
                config.providers[index].apiKey = "fixture-key"
            case .claude:
                config.providers[index].enabled = nil
                config.providers[index].extrasEnabled = true
            default: break
            }
        }
        let original = testSettingsStore(
            suiteName: "provider-fixture-original", userDefaults: InMemoryUserDefaults(), config: config)
        let arranged = testSettingsStore(
            suiteName: "provider-fixture-arranged", userDefaults: InMemoryUserDefaults(), config: config)
        original.selectedMenuProvider = selection
        arranged.selectedMenuProvider = selection
        let metadata = ProviderRegistry.shared.metadata
        // Other entries already have explicit false values; cover each distinct transition without repeated disk
        // writes.
        for provider in [UsageProvider.codex, .claude, .zai, .gemini] {
            let value = try #require(metadata[provider])
            original.setProviderEnabled(
                provider: provider, metadata: value, enabled: provider == .codex || provider == .zai)
        }

        enableTestProviders([.codex, .zai], settings: arranged)

        #expect(arranged.selectedMenuProvider == original.selectedMenuProvider)
        #expect(arranged.providerEnablement == original.providerEnablement)
        let originalConfig = try #require(try original.configStore.load())
        let arrangedConfig = try #require(try arranged.configStore.load())
        #expect(arrangedConfig.providerConfig(for: .codex)?.apiKey == "fixture-key")
        #expect(arrangedConfig.providerConfig(for: .claude)?.extrasEnabled == true)
        let originalData = try original.configStore.encodedData(for: originalConfig)
        let arrangedData = try arranged.configStore.encodedData(for: arrangedConfig)
        #expect(arrangedData == originalData)
    }

    @Test
    func `arranging unchanged unselected providers does not repeat config work`() {
        let settings = testSettingsStore(suiteName: "provider-fixture-work", userDefaults: InMemoryUserDefaults())
        settings.selectedMenuProvider = nil
        enableTestProviders([.codex], settings: settings)
        let revision = settings.configRevision

        enableTestProviders([.codex], settings: settings)

        #expect(settings.configRevision == revision)
    }
}
