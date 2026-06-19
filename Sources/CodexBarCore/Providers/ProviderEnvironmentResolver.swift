import Foundation

public enum ProviderEnvironmentResolver {
    public static func resolve(
        base: [String: String],
        provider: UsageProvider,
        config: ProviderConfig?,
        selectedAccount: ProviderTokenAccount?) -> [String: String]
    {
        var environment = ProviderConfigEnvironment.applyProviderConfigOverrides(
            base: base,
            provider: provider,
            config: config)
        guard let selectedAccount else { return environment }

        TokenAccountSupportCatalog.scrubEnvironmentForSelectedAccount(
            &environment,
            provider: provider,
            token: selectedAccount.token)
        if let override = TokenAccountSupportCatalog.envOverride(
            for: provider,
            token: selectedAccount.token)
        {
            environment.merge(override) { _, selectedAccountValue in selectedAccountValue }
        }
        return environment
    }
}
