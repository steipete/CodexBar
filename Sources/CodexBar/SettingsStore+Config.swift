import CodexBarCore
import Foundation

extension SettingsStore {
    func providerConfig(for provider: UsageProvider) -> ProviderConfig? {
        self.configSnapshot.providerConfig(for: provider)
    }

    func quotaWarningConfig(for provider: UsageProvider) -> QuotaWarningConfig {
        self.configSnapshot.providerConfig(for: provider)?.quotaWarnings ?? QuotaWarningConfig()
    }

    func resolvedQuotaWarningThresholds(provider: UsageProvider, window: QuotaWarningWindow) -> [Int] {
        self.quotaWarningConfig(for: provider).thresholds(for: window, global: self.quotaWarningThresholds)
    }

    func hasQuotaWarningOverride(provider: UsageProvider, window: QuotaWarningWindow) -> Bool {
        self.quotaWarningConfig(for: provider).hasOverride(for: window)
    }

    func setQuotaWarningThresholds(provider: UsageProvider, window: QuotaWarningWindow, thresholds: [Int]?) {
        self.updateProviderConfig(provider: provider) { entry in
            var config = entry.quotaWarnings ?? QuotaWarningConfig()
            switch window {
            case .session:
                config.session = thresholds.map { QuotaWarningWindowConfig(thresholds: $0) }
            case .weekly:
                config.weekly = thresholds.map { QuotaWarningWindowConfig(thresholds: $0) }
            }
            entry.quotaWarnings = config.isEmpty ? nil : config
        }
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
