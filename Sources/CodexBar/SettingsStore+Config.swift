import CodexBarCore
import Foundation

extension SettingsStore {
    func providerConfig(for provider: UsageProvider) -> ProviderConfig? {
        self.configSnapshot.providerConfig(for: provider)
    }

    var tokenAccountsByProvider: [UsageProvider: ProviderTokenAccountData] {
        get {
            Dictionary(uniqueKeysWithValues: self.configSnapshot.providers.compactMap { entry in
                guard let accounts = entry.tokenAccounts else { return nil }
                return (entry.id, accounts)
            })
        }
        set {
            self.updateProviderTokenAccounts(newValue)
        }
    }
}

extension SettingsStore {
    func resolvedCookieSource(
        provider: UsageProvider,
        fallback: ProviderCookieSource) -> ProviderCookieSource
    {
        let source = self.configSnapshot.providerConfig(for: provider)?.cookieSource ?? fallback
        guard self.debugDisableKeychainAccess == false else { return source == .off ? .off : .manual }
        return source
    }

    func logProviderModeChange(provider: UsageProvider, field: String, value: String) {
        CodexBarLog.logger(LogCategories.settings).info(
            "Provider mode updated",
            metadata: ["provider": provider.rawValue, "field": field, "value": value])
    }

    func logSecretUpdate(provider: UsageProvider, field: String, value: String) {
        var metadata = LogMetadata.secretSummary(value)
        metadata["provider"] = provider.rawValue
        metadata["field"] = field
        CodexBarLog.logger(LogCategories.settings).info(
            "Provider secret updated",
            metadata: metadata)
    }
}
