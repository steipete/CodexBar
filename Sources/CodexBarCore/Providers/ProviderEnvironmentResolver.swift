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
        Self.applyProviderSpecificAccountOverrides(
            &environment,
            provider: provider,
            account: selectedAccount)
        return environment
    }

    private static func applyProviderSpecificAccountOverrides(
        _ environment: inout [String: String],
        provider: UsageProvider,
        account: ProviderTokenAccount)
    {
        guard provider == .zai else {
            return
        }

        // Team usage scope is account-level only. Accounts without an explicit
        // `.team` scope are treated as personal and must not inherit stray team
        // context from the base environment or provider config.
        let scope: ZaiUsageScope = if let raw = account.sanitizedUsageScope?.lowercased(),
                                      let resolved = ZaiUsageScope(rawValue: raw)
        {
            resolved
        } else {
            .personal
        }

        environment.removeValue(forKey: ZaiSettingsReader.bigModelOrganizationKey)
        environment.removeValue(forKey: ZaiSettingsReader.bigModelProjectKey)

        guard scope == .team else { return }
        if let organizationID = account.sanitizedOrganizationID {
            environment[ZaiSettingsReader.bigModelOrganizationKey] = organizationID
        }
        if let projectID = account.sanitizedWorkspaceID {
            environment[ZaiSettingsReader.bigModelProjectKey] = projectID
        }
    }
}
