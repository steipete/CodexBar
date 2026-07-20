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

    func explicitQuotaWarningThresholds(provider: UsageProvider, window: QuotaWarningWindow) -> [Int]? {
        self.quotaWarningWindowConfig(provider: provider, window: window)?
            .thresholds
            .map(QuotaWarningThresholds.sanitized)
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
        let sanitizedThresholds = thresholds.map(QuotaWarningThresholds.sanitized)
        let currentThresholds = self.quotaWarningWindowConfig(provider: provider, window: window)?
            .thresholds
            .map(QuotaWarningThresholds.sanitized)
        guard currentThresholds != sanitizedThresholds else { return }

        self.updateProviderConfig(provider: provider) { entry in
            var config = entry.quotaWarnings ?? QuotaWarningConfig()
            switch window {
            case .session:
                var windowConfig = config.session ?? QuotaWarningWindowConfig()
                windowConfig.thresholds = sanitizedThresholds
                config.session = windowConfig.hasOverride ? windowConfig : nil
            case .weekly:
                var windowConfig = config.weekly ?? QuotaWarningWindowConfig()
                windowConfig.thresholds = sanitizedThresholds
                config.weekly = windowConfig.hasOverride ? windowConfig : nil
            }
            entry.quotaWarnings = config.isEmpty ? nil : config
        }
    }

    func setQuotaWarningThresholdsIfOverridden(
        provider: UsageProvider,
        window: QuotaWarningWindow,
        thresholds: [Int]?)
    {
        guard let windowConfig = self.quotaWarningWindowConfig(provider: provider, window: window),
              windowConfig.hasOverride
        else { return }

        let sanitizedThresholds = thresholds.map(QuotaWarningThresholds.sanitized)
        let currentThresholds = windowConfig.thresholds.map(QuotaWarningThresholds.sanitized)
        let inheritedThresholds = QuotaWarningThresholds.sanitized(self.quotaWarningThresholds(window))
        if currentThresholds == nil, sanitizedThresholds == inheritedThresholds {
            return
        }

        self.setQuotaWarningThresholds(provider: provider, window: window, thresholds: thresholds)
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

    // MARK: - Hooks

    var hooksConfig: HooksConfig {
        self.configSnapshot.hooks ?? HooksConfig()
    }

    var hooksEnabled: Bool {
        self.hooksConfig.enabled
    }

    var hookRules: [HookRule] {
        self.hooksConfig.events
    }

    func setHooksEnabled(_ enabled: Bool) {
        self.updateHooks { $0.enabled = enabled }
    }

    func addHookRule(_ rule: HookRule) {
        self.updateHooks { $0.events.append(rule) }
    }

    func updateHookRule(_ rule: HookRule) {
        self.updateHooks { config in
            if let index = config.events.firstIndex(where: { $0.id == rule.id }) {
                config.events[index] = rule
            }
        }
    }

    func removeHookRule(id: String) {
        self.updateHooks { config in
            config.events.removeAll { $0.id == id }
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
    private func quotaWarningWindowConfig(
        provider: UsageProvider,
        window: QuotaWarningWindow) -> QuotaWarningWindowConfig?
    {
        let config = self.quotaWarningConfig(for: provider)
        switch window {
        case .session:
            return config.session
        case .weekly:
            return config.weekly
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
