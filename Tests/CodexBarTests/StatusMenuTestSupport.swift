import CodexBarCore
@testable import CodexBar

extension StatusMenuTests {
    func enableProvidersForInstantOpenTesting(
        _ enabledProviders: Set<UsageProvider>,
        settings: SettingsStore)
    {
        let registry = ProviderRegistry.shared
        for provider in UsageProvider.allCases {
            guard let metadata = registry.metadata[provider] else { continue }
            settings.setProviderEnabled(
                provider: provider,
                metadata: metadata,
                enabled: enabledProviders.contains(provider))
        }
    }
}
