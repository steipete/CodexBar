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
    func recoverLegacyCredentials(for provider: UsageProvider?, allowDisabled: Bool = false) {
        guard !Task.isCancelled, ProviderInteractionContext.current == .userInitiated,
              !KeychainAccessGate.isDisabled, !self.configNeedsReload,
              !self.userDefaults.bool(forKey: CodexBarConfigMigrator.legacyMigrationCompletedKey)
        else { return }
        for source in CodexBarConfigMigrator.legacySecretSources(stores: self.legacyCredentialStores) {
            guard !Task.isCancelled else { return }
            guard provider == nil || provider == source.provider,
                  self.legacyCredentialRecoverySources.contains(source.store),
                  self.legacyCredentialSourceIsActive(provider: source.provider, field: source.field),
                  self.effectiveSelectedTokenAccount(for: source.provider) == nil,
                  (allowDisabled && provider == source.provider) || self.isProviderEnabled(
                      provider: source.provider,
                      metadata: ProviderDescriptorRegistry.descriptor(for: source.provider).metadata)
            else { continue }
            guard Self.normalizedConfigField(self.providerConfig(for: source.provider)?[keyPath: source.field]) == nil
            else {
                self.legacyCredentialRecoverySources.remove(source.store)
                continue
            }
            let revision = self.providerConfigRevision(for: source.provider)
            do {
                guard let value = try Self.normalizedConfigField(source.load()),
                      // The explanation alert can allow another settings edit before the read returns.
                      !Task.isCancelled, !self.configNeedsReload,
                      revision == self.providerConfigRevision(for: source.provider),
                      self.legacyCredentialSourceIsActive(provider: source.provider, field: source.field),
                      Self
                          .normalizedConfigField(self.providerConfig(for: source.provider)?[keyPath: source.field]) ==
                          nil
                else { continue }
                self.updateProviderConfig(provider: source.provider) { $0[keyPath: source.field] = value }
                self.legacyCredentialRecoverySources.remove(source.store)
            } catch {
                CodexBarLog.logger(LogCategories.configMigration).info(
                    "Legacy credential recovery deferred",
                    metadata: ["store": source.store])
            }
        }
    }

    private func legacyCredentialSourceIsActive(
        provider: UsageProvider,
        field: WritableKeyPath<ProviderConfig, String?>) -> Bool
    {
        let source = self.providerConfig(for: provider)?.source ?? .auto
        if field == \.apiKey { return source == .auto || source == .api }
        guard self.resolvedCookieSource(provider: provider, fallback: .auto) == .manual else { return false }
        // Provider-specific by design: recover only credentials used by each legacy source or its optional web details.
        switch provider {
        case .codex:
            return self.codexCookieSource == .manual
        case .claude:
            let settings = self.claudeSettingsSnapshot(tokenOverride: nil)
            guard settings.cookieSource == .manual else { return false }
            switch settings.usageDataSource {
            case .auto, .web: return true
            case .cli, .oauth: return settings.webExtrasEnabled || self.showOptionalCreditsAndExtraUsage
            case .api: return false
            }
        case .cursor, .augment:
            return ProviderDescriptorRegistry.descriptor(for: provider).fetchPlan.sourceModes.contains(source)
        case .factory:
            return self.factoryUsageDataSource != .api
        case .kimi:
            return source == .auto || source == .web || source == .api
        default:
            return source.usesWeb
        }
    }

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
            set: { self.setCookieSource($0, provider: provider) })
    }

    func setCookieSource(_ source: ProviderCookieSource, provider: UsageProvider) {
        self.updateProviderConfig(provider: provider) { $0.cookieSource = source }
        self.logProviderModeChange(provider: provider, field: "cookieSource", value: source.rawValue)
    }

    func providerConfig(for provider: UsageProvider) -> ProviderConfig? {
        self.configSnapshot.providerConfig(for: provider.instanceID)
    }

    func quotaWarningConfig(for provider: ProviderInstanceID) -> QuotaWarningConfig {
        self.configSnapshot.providerConfig(for: provider)?.quotaWarnings ?? QuotaWarningConfig()
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

    func resolvedQuotaWarningThresholds(provider: ProviderInstanceID, window: QuotaWarningWindow) -> [Int] {
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
        self.quotaWarningConfig(for: provider.instanceID).isEnabled(
            for: window,
            global: self.quotaWarningWindowEnabled(window))
    }

    func hasQuotaWarningOverride(provider: UsageProvider, window: QuotaWarningWindow) -> Bool {
        self.quotaWarningConfig(for: provider.instanceID).hasOverride(for: window)
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
        let config = self.quotaWarningConfig(for: provider.instanceID)
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
