import Foundation

public enum ProviderConfigEnvironment {
    public static func applyAPIKeyOverride(
        base: [String: String],
        provider: UsageProvider,
        config: ProviderConfig?) -> [String: String]
    {
        ProviderDescriptorRegistry.descriptor(for: provider).credentials?.applyConfig(base: base, config: config)
            ?? base
    }

    public static func supportsAPIKeyOverride(for provider: UsageProvider) -> Bool {
        ProviderDescriptorRegistry.descriptor(for: provider).credentials?.supportsAPIKeyOverride ?? false
    }

    public static func applyProviderConfigOverrides(
        base: [String: String],
        provider: UsageProvider,
        config: ProviderConfig?) -> [String: String]
    {
        self.applyAPIKeyOverride(base: base, provider: provider, config: config)
    }
}
