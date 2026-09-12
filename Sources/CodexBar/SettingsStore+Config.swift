import CodexBarCore
import Foundation
import SwiftUI

enum ProviderConfigStringField: Sendable, Equatable {
    case apiKey
    case secretKey
    case region
    case endpoint
    case workspace
    case secretWorkspace(logField: String)
    case cookieHeader

    fileprivate func read(from config: ProviderConfig?) -> String {
        switch self {
        case .apiKey: config?.sanitizedAPIKey ?? ""
        case .secretKey: config?.sanitizedSecretKey ?? ""
        case .region: config?.sanitizedRegion ?? ""
        case .endpoint: config?.sanitizedEnterpriseHost ?? ""
        case .workspace, .secretWorkspace: config?.sanitizedWorkspaceID ?? ""
        case .cookieHeader: config?.sanitizedCookieHeader ?? ""
        }
    }

    fileprivate func write(_ value: String?, to config: inout ProviderConfig) {
        switch self {
        case .apiKey: config.apiKey = value
        case .secretKey: config.secretKey = value
        case .region: config.region = value
        case .endpoint: config.enterpriseHost = value
        case .workspace, .secretWorkspace: config.workspaceID = value
        case .cookieHeader: config.cookieHeader = value
        }
    }

    fileprivate var secretLogField: String? {
        switch self {
        case .apiKey: "apiKey"
        case .secretKey: "secretKey"
        case .cookieHeader: "cookieHeader"
        case let .secretWorkspace(logField): logField
        case .region, .endpoint, .workspace: nil
        }
    }
}

extension SettingsStore {
    subscript(providerConfig provider: UsageProvider, field field: ProviderConfigStringField) -> String {
        get {
            field.read(from: self.configSnapshot.providerConfig(for: provider.instanceID))
        }
        set {
            self.updateProviderConfig(provider: provider) { entry in
                field.write(self.normalizedConfigValue(newValue), to: &entry)
            }
            if let logField = field.secretLogField {
                self.logSecretUpdate(provider: provider, field: logField, value: newValue)
            }
        }
    }

    func providerConfigBinding(provider: UsageProvider, field: ProviderConfigStringField) -> Binding<String> {
        Binding(
            get: { self[providerConfig: provider, field: field] },
            set: { self[providerConfig: provider, field: field] = $0 })
    }

    func providerConfigSecretBinding(
        provider: UsageProvider,
        key: String,
        logField: String) -> Binding<String>
    {
        Binding(
            get: {
                self.configSnapshot.providerConfig(for: provider.instanceID)?.pluginSecrets?[key] ?? ""
            },
            set: { value in
                self.updateProviderConfig(provider: provider) { entry in
                    var secrets = entry.pluginSecrets ?? [:]
                    secrets[key] = self.normalizedConfigValue(value)
                    entry.pluginSecrets = secrets.isEmpty ? nil : secrets
                }
                self.logSecretUpdate(provider: provider, field: logField, value: value)
            })
    }

    func providerCookieSourceBinding(
        provider: UsageProvider,
        fallback: ProviderCookieSource) -> Binding<ProviderCookieSource>
    {
        Binding(
            get: { self.resolvedCookieSource(provider: provider, fallback: fallback) },
            set: { newValue in
                self.updateProviderConfig(provider: provider) { $0.cookieSource = newValue }
                self.logProviderModeChange(provider: provider, field: "cookieSource", value: newValue.rawValue)
            })
    }

    func providerConfig(for provider: UsageProvider) -> ProviderConfig? {
        self.configSnapshot.providerConfig(for: provider.instanceID)
    }

    func quotaWarningConfig(for provider: UsageProvider) -> QuotaWarningConfig {
        self.configSnapshot.providerConfig(for: provider.instanceID)?.quotaWarnings ?? QuotaWarningConfig()
    }

    /// The user accent override for a provider, or nil when the provider keeps its shipped color.
    func accentColorOverride(for provider: UsageProvider) -> ProviderColor? {
        guard let raw = self.configSnapshot.providerConfig(for: provider.instanceID)?.accentColor else { return nil }
        return ProviderColor(hexString: raw)
    }

    /// The color a provider paints with: the user override when one exists, otherwise the shipped brand color.
    func accentColor(for provider: UsageProvider) -> ProviderColor {
        self.accentColorOverride(for: provider)
            ?? ProviderDescriptorRegistry.descriptor(for: provider).branding.color
    }

    /// Stores an accent override, or clears it when `color` is nil. Clearing restores the shipped color,
    /// which descriptors hold as a compile-time constant and this never writes over.
    func setAccentColorOverride(_ color: ProviderColor?, for provider: UsageProvider) {
        guard self.accentColorOverride(for: provider) != color else { return }
        self.updateProviderConfig(provider: provider, affectsBackgroundWork: false) { entry in
            entry.accentColor = color?.hexString
        }
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
                guard let provider = entry.id.firstPartyProvider,
                      let accounts = entry.tokenAccounts
                else { return nil }
                return (provider, accounts)
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
        let source = self.configSnapshot.providerConfig(for: provider.instanceID)?.cookieSource ?? fallback
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
