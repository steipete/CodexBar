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
        self.quotaWarningConfig(for: provider).thresholds(
            for: window,
            global: self.quotaWarningThresholds(window))
    }

    func quotaWarningEnabled(provider: UsageProvider, window: QuotaWarningWindow) -> Bool {
        self.quotaWarningConfig(for: provider).isEnabled(
            for: window,
            global: self.quotaWarningWindowEnabled(window))
    }

    func hasQuotaWarningOverride(provider: UsageProvider, window: QuotaWarningWindow) -> Bool {
        self.quotaWarningConfig(for: provider).hasOverride(for: window)
    }

    func setQuotaWarningThresholds(provider: UsageProvider, window: QuotaWarningWindow, thresholds: [Int]?) {
        self.updateProviderConfig(provider: provider) { entry in
            var config = entry.quotaWarnings ?? QuotaWarningConfig()
            switch window {
            case .session:
                var windowConfig = config.session ?? QuotaWarningWindowConfig()
                windowConfig.thresholds = thresholds.map(QuotaWarningThresholds.sanitized)
                config.session = windowConfig.hasOverride ? windowConfig : nil
            case .weekly:
                var windowConfig = config.weekly ?? QuotaWarningWindowConfig()
                windowConfig.thresholds = thresholds.map(QuotaWarningThresholds.sanitized)
                config.weekly = windowConfig.hasOverride ? windowConfig : nil
            }
            entry.quotaWarnings = config.isEmpty ? nil : config
        }
    }

    func setQuotaWarningOverride(
        provider: UsageProvider,
        window: QuotaWarningWindow,
        thresholds: [Int]?,
        enabled: Bool?)
    {
        self.updateProviderConfig(provider: provider) { entry in
            var config = entry.quotaWarnings ?? QuotaWarningConfig()
            switch window {
            case .session:
                var windowConfig = config.session ?? QuotaWarningWindowConfig()
                windowConfig.thresholds = thresholds.map(QuotaWarningThresholds.sanitized)
                windowConfig.enabled = enabled
                config.session = windowConfig.hasOverride ? windowConfig : nil
            case .weekly:
                var windowConfig = config.weekly ?? QuotaWarningWindowConfig()
                windowConfig.thresholds = thresholds.map(QuotaWarningThresholds.sanitized)
                windowConfig.enabled = enabled
                config.weekly = windowConfig.hasOverride ? windowConfig : nil
            }
            entry.quotaWarnings = config.isEmpty ? nil : config
        }
    }

    func setQuotaWarningWindowEnabled(provider: UsageProvider, window: QuotaWarningWindow, enabled: Bool?) {
        self.updateProviderConfig(provider: provider) { entry in
            var config = entry.quotaWarnings ?? QuotaWarningConfig()
            switch window {
            case .session:
                var windowConfig = config.session ?? QuotaWarningWindowConfig()
                windowConfig.enabled = enabled
                config.session = windowConfig.hasOverride ? windowConfig : nil
            case .weekly:
                var windowConfig = config.weekly ?? QuotaWarningWindowConfig()
                windowConfig.enabled = enabled
                config.weekly = windowConfig.hasOverride ? windowConfig : nil
            }
            entry.quotaWarnings = config.isEmpty ? nil : config
        }
    }

    func providerSubscriptionSnapshot(for provider: UsageProvider) -> ProviderSubscriptionSnapshot? {
        guard let snapshot = self.configSnapshot.providerConfig(for: provider)?.subscriptionSnapshot else {
            return nil
        }
        return snapshot.withProvider(provider)
    }

    func setProviderSubscriptionSnapshot(
        provider: UsageProvider,
        snapshot: ProviderSubscriptionSnapshot?)
    {
        self.updateProviderConfig(provider: provider) { entry in
            entry.subscriptionSnapshot = snapshot?.withProvider(provider)
        }
    }

    func providerSubscriptionReminderState(for provider: UsageProvider) -> ProviderSubscriptionReminderState? {
        self.configSnapshot.providerConfig(for: provider)?.subscriptionReminderState?[provider.rawValue]
    }

    func setProviderSubscriptionReminderState(
        for provider: UsageProvider,
        state: ProviderSubscriptionReminderState?)
    {
        self.updateConfig(reason: "subscription-reminder-state-\(provider.rawValue)") { config in
            guard let index = config.providers.firstIndex(where: { $0.id == provider }) else { return }
            var states = config.providers[index].subscriptionReminderState ?? [:]
            if let state {
                states[provider.rawValue] = state
            } else {
                states.removeValue(forKey: provider.rawValue)
            }
            config.providers[index].subscriptionReminderState = states.isEmpty ? nil : states
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
