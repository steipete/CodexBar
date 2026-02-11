import AppKit
import CodexBarCore
import Observation
import ServiceManagement

enum RefreshFrequency: String, CaseIterable, Identifiable {
    case manual
    case oneMinute
    case twoMinutes
    case fiveMinutes
    case fifteenMinutes
    case thirtyMinutes

    var id: String {
        self.rawValue
    }

    var seconds: TimeInterval? {
        switch self {
        case .manual: nil
        case .oneMinute: 60
        case .twoMinutes: 120
        case .fiveMinutes: 300
        case .fifteenMinutes: 900
        case .thirtyMinutes: 1800
        }
    }

    var label: String {
        switch self {
        case .manual:
            L10n.tr("settings.general.refresh_frequency.manual", fallback: "Manual")
        case .oneMinute:
            L10n.tr("settings.general.refresh_frequency.one_minute", fallback: "1 min")
        case .twoMinutes:
            L10n.tr("settings.general.refresh_frequency.two_minutes", fallback: "2 min")
        case .fiveMinutes:
            L10n.tr("settings.general.refresh_frequency.five_minutes", fallback: "5 min")
        case .fifteenMinutes:
            L10n.tr("settings.general.refresh_frequency.fifteen_minutes", fallback: "15 min")
        case .thirtyMinutes:
            L10n.tr("settings.general.refresh_frequency.thirty_minutes", fallback: "30 min")
        }
    }
}

enum MenuBarMetricPreference: String, CaseIterable, Identifiable {
    case automatic
    case primary
    case secondary
    case average

    var id: String {
        self.rawValue
    }

    var label: String {
        switch self {
        case .automatic:
            L10n.tr("settings.providers.menu_bar_metric.option.automatic", fallback: "Automatic")
        case .primary:
            L10n.tr("settings.providers.menu_bar_metric.option.primary", fallback: "Primary")
        case .secondary:
            L10n.tr("settings.providers.menu_bar_metric.option.secondary", fallback: "Secondary")
        case .average:
            L10n.tr("settings.providers.menu_bar_metric.option.average", fallback: "Average")
        }
    }
}

enum AppLanguageOption: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    var id: String {
        self.rawValue
    }

    var label: String {
        switch self {
        case .system:
            return L10n.tr("settings.general.language.option.system", fallback: "System")
        case .english:
            return L10n.tr("settings.general.language.option.english", fallback: "English")
        case .simplifiedChinese:
            return L10n.tr("settings.general.language.option.zh_hans", fallback: "简体中文")
        }
    }
}

@MainActor
@Observable
final class SettingsStore {
    static let sharedDefaults = UserDefaults(suiteName: "group.com.steipete.codexbar")
    static let isRunningTests: Bool = {
        let env = ProcessInfo.processInfo.environment
        if env["XCTestConfigurationFilePath"] != nil { return true }
        if env["TESTING_LIBRARY_VERSION"] != nil { return true }
        if env["SWIFT_TESTING"] != nil { return true }
        return NSClassFromString("XCTestCase") != nil
    }()

    @ObservationIgnored let userDefaults: UserDefaults
    @ObservationIgnored let configStore: CodexBarConfigStore
    @ObservationIgnored var config: CodexBarConfig
    @ObservationIgnored var configPersistTask: Task<Void, Never>?
    @ObservationIgnored var configLoading = false
    @ObservationIgnored var tokenAccountsLoaded = false
    var defaultsState: SettingsDefaultsState
    var configRevision: Int = 0
    var providerOrder: [UsageProvider] = []
    var providerEnablement: [UsageProvider: Bool] = [:]

    init(
        userDefaults: UserDefaults = .standard,
        configStore: CodexBarConfigStore = CodexBarConfigStore(),
        zaiTokenStore: any ZaiTokenStoring = KeychainZaiTokenStore(),
        syntheticTokenStore: any SyntheticTokenStoring = KeychainSyntheticTokenStore(),
        codexCookieStore: any CookieHeaderStoring = KeychainCookieHeaderStore(
            account: "codex-cookie",
            promptKind: .codexCookie),
        claudeCookieStore: any CookieHeaderStoring = KeychainCookieHeaderStore(
            account: "claude-cookie",
            promptKind: .claudeCookie),
        cursorCookieStore: any CookieHeaderStoring = KeychainCookieHeaderStore(
            account: "cursor-cookie",
            promptKind: .cursorCookie),
        opencodeCookieStore: any CookieHeaderStoring = KeychainCookieHeaderStore(
            account: "opencode-cookie",
            promptKind: .opencodeCookie),
        factoryCookieStore: any CookieHeaderStoring = KeychainCookieHeaderStore(
            account: "factory-cookie",
            promptKind: .factoryCookie),
        minimaxCookieStore: any MiniMaxCookieStoring = KeychainMiniMaxCookieStore(),
        minimaxAPITokenStore: any MiniMaxAPITokenStoring = KeychainMiniMaxAPITokenStore(),
        kimiTokenStore: any KimiTokenStoring = KeychainKimiTokenStore(),
        kimiK2TokenStore: any KimiK2TokenStoring = KeychainKimiK2TokenStore(),
        augmentCookieStore: any CookieHeaderStoring = KeychainCookieHeaderStore(
            account: "augment-cookie",
            promptKind: .augmentCookie),
        ampCookieStore: any CookieHeaderStoring = KeychainCookieHeaderStore(
            account: "amp-cookie",
            promptKind: .ampCookie),
        copilotTokenStore: any CopilotTokenStoring = KeychainCopilotTokenStore(),
        tokenAccountStore: any ProviderTokenAccountStoring = FileTokenAccountStore())
    {
        let legacyStores = CodexBarConfigMigrator.LegacyStores(
            zaiTokenStore: zaiTokenStore,
            syntheticTokenStore: syntheticTokenStore,
            codexCookieStore: codexCookieStore,
            claudeCookieStore: claudeCookieStore,
            cursorCookieStore: cursorCookieStore,
            opencodeCookieStore: opencodeCookieStore,
            factoryCookieStore: factoryCookieStore,
            minimaxCookieStore: minimaxCookieStore,
            minimaxAPITokenStore: minimaxAPITokenStore,
            kimiTokenStore: kimiTokenStore,
            kimiK2TokenStore: kimiK2TokenStore,
            augmentCookieStore: augmentCookieStore,
            ampCookieStore: ampCookieStore,
            copilotTokenStore: copilotTokenStore,
            tokenAccountStore: tokenAccountStore)
        let config = CodexBarConfigMigrator.loadOrMigrate(
            configStore: configStore,
            userDefaults: userDefaults,
            stores: legacyStores)
        self.userDefaults = userDefaults
        self.configStore = configStore
        self.config = config
        self.configLoading = true
        self.defaultsState = Self.loadDefaultsState(userDefaults: userDefaults)
        if AppLanguageOption(rawValue: self.defaultsState.appLanguageRaw) == .system {
            self.userDefaults.removeObject(forKey: "AppleLanguages")
        }
        self.updateProviderState(config: config)
        self.migrateLegacyCodexCLIProxyDefaultsIfNeeded()
        self.configLoading = false
        CodexBarLog.setFileLoggingEnabled(self.debugFileLoggingEnabled)
        userDefaults.removeObject(forKey: "showCodexUsage")
        userDefaults.removeObject(forKey: "showClaudeUsage")
        LaunchAtLoginManager.setEnabled(self.launchAtLogin)
        self.runInitialProviderDetectionIfNeeded()
        self.applyTokenCostDefaultIfNeeded()
        if self.claudeUsageDataSource != .cli { self.claudeWebExtrasEnabled = false }
        self.openAIWebAccessEnabled = self.codexCookieSource.isEnabled
        Self.sharedDefaults?.set(self.debugDisableKeychainAccess, forKey: "debugDisableKeychainAccess")
        KeychainAccessGate.isDisabled = self.debugDisableKeychainAccess
    }
}

extension SettingsStore {
    private static func loadDefaultsState(userDefaults: UserDefaults) -> SettingsDefaultsState {
        let refreshRaw = userDefaults.string(forKey: "refreshFrequency") ?? RefreshFrequency.fiveMinutes.rawValue
        let refreshFrequency = RefreshFrequency(rawValue: refreshRaw) ?? .fiveMinutes
        let launchAtLogin = userDefaults.object(forKey: "launchAtLogin") as? Bool ?? false
        let debugMenuEnabled = userDefaults.object(forKey: "debugMenuEnabled") as? Bool ?? false
        let debugDisableKeychainAccess: Bool = {
            if let stored = userDefaults.object(forKey: "debugDisableKeychainAccess") as? Bool {
                return stored
            }
            if let shared = Self.sharedDefaults?.object(forKey: "debugDisableKeychainAccess") as? Bool {
                userDefaults.set(shared, forKey: "debugDisableKeychainAccess")
                return shared
            }
            return false
        }()
        let debugFileLoggingEnabled = userDefaults.object(forKey: "debugFileLoggingEnabled") as? Bool ?? false
        let debugLogLevelRaw = userDefaults.string(forKey: "debugLogLevel") ?? CodexBarLog.Level.verbose.rawValue
        if userDefaults.string(forKey: "debugLogLevel") == nil {
            userDefaults.set(debugLogLevelRaw, forKey: "debugLogLevel")
        }
        let debugLoadingPatternRaw = userDefaults.string(forKey: "debugLoadingPattern")
        let debugKeepCLISessionsAlive = userDefaults.object(forKey: "debugKeepCLISessionsAlive") as? Bool ?? false
        let statusChecksEnabled = userDefaults.object(forKey: "statusChecksEnabled") as? Bool ?? true
        let sessionQuotaDefault = userDefaults.object(forKey: "sessionQuotaNotificationsEnabled") as? Bool
        let sessionQuotaNotificationsEnabled = sessionQuotaDefault ?? true
        if sessionQuotaDefault == nil {
            userDefaults.set(true, forKey: "sessionQuotaNotificationsEnabled")
        }
        let usageBarsShowUsed = userDefaults.object(forKey: "usageBarsShowUsed") as? Bool ?? false
        let resetTimesShowAbsolute = userDefaults.object(forKey: "resetTimesShowAbsolute") as? Bool ?? false
        let menuBarShowsBrandIconWithPercent = userDefaults.object(
            forKey: "menuBarShowsBrandIconWithPercent") as? Bool ?? false
        let menuBarDisplayModeRaw = userDefaults.string(forKey: "menuBarDisplayMode")
            ?? MenuBarDisplayMode.percent.rawValue
        let showAllTokenAccountsInMenu = userDefaults.object(forKey: "showAllTokenAccountsInMenu") as? Bool ?? false
        let storedPreferences = userDefaults.dictionary(forKey: "menuBarMetricPreferences") as? [String: String] ?? [:]
        var resolvedPreferences = storedPreferences
        if resolvedPreferences.isEmpty,
           let menuBarMetricRaw = userDefaults.string(forKey: "menuBarMetricPreference"),
           let legacyPreference = MenuBarMetricPreference(rawValue: menuBarMetricRaw)
        {
            resolvedPreferences = Dictionary(
                uniqueKeysWithValues: UsageProvider.allCases.map { ($0.rawValue, legacyPreference.rawValue) })
        }
        let costUsageEnabled = userDefaults.object(forKey: "tokenCostUsageEnabled") as? Bool ?? false
        let hidePersonalInfo = userDefaults.object(forKey: "hidePersonalInfo") as? Bool ?? false
        let randomBlinkEnabled = userDefaults.object(forKey: "randomBlinkEnabled") as? Bool ?? false
        let menuBarShowsHighestUsage = userDefaults.object(forKey: "menuBarShowsHighestUsage") as? Bool ?? false
        let claudeWebExtrasEnabledRaw = userDefaults.object(forKey: "claudeWebExtrasEnabled") as? Bool ?? false
        let creditsExtrasDefault = userDefaults.object(forKey: "showOptionalCreditsAndExtraUsage") as? Bool
        let showOptionalCreditsAndExtraUsage = creditsExtrasDefault ?? true
        if creditsExtrasDefault == nil { userDefaults.set(true, forKey: "showOptionalCreditsAndExtraUsage") }
        let openAIWebAccessDefault = userDefaults.object(forKey: "openAIWebAccessEnabled") as? Bool
        let openAIWebAccessEnabled = openAIWebAccessDefault ?? true
        if openAIWebAccessDefault == nil { userDefaults.set(true, forKey: "openAIWebAccessEnabled") }
        let jetbrainsIDEBasePath = userDefaults.string(forKey: "jetbrainsIDEBasePath") ?? ""
        let mergeIcons = userDefaults.object(forKey: "mergeIcons") as? Bool ?? true
        let switcherShowsIcons = userDefaults.object(forKey: "switcherShowsIcons") as? Bool ?? true
        let selectedMenuProviderRaw = userDefaults.string(forKey: "selectedMenuProvider")
        let providerDetectionCompleted = userDefaults.object(forKey: "providerDetectionCompleted") as? Bool ?? false
        let appLanguageRaw = userDefaults.string(forKey: "appLanguageCode") ?? AppLanguageOption.system.rawValue
        let cliProxyGlobalBaseURL = userDefaults.string(forKey: "cliProxyGlobalBaseURL") ?? ""
        let cliProxyGlobalManagementKey = userDefaults.string(forKey: "cliProxyGlobalManagementKey") ?? ""
        let cliProxyGlobalAuthIndex = userDefaults.string(forKey: "cliProxyGlobalAuthIndex") ?? ""

        return SettingsDefaultsState(
            refreshFrequency: refreshFrequency,
            launchAtLogin: launchAtLogin,
            debugMenuEnabled: debugMenuEnabled,
            debugDisableKeychainAccess: debugDisableKeychainAccess,
            debugFileLoggingEnabled: debugFileLoggingEnabled,
            debugLogLevelRaw: debugLogLevelRaw,
            debugLoadingPatternRaw: debugLoadingPatternRaw,
            debugKeepCLISessionsAlive: debugKeepCLISessionsAlive,
            statusChecksEnabled: statusChecksEnabled,
            sessionQuotaNotificationsEnabled: sessionQuotaNotificationsEnabled,
            usageBarsShowUsed: usageBarsShowUsed,
            resetTimesShowAbsolute: resetTimesShowAbsolute,
            menuBarShowsBrandIconWithPercent: menuBarShowsBrandIconWithPercent,
            menuBarDisplayModeRaw: menuBarDisplayModeRaw,
            showAllTokenAccountsInMenu: showAllTokenAccountsInMenu,
            menuBarMetricPreferencesRaw: resolvedPreferences,
            costUsageEnabled: costUsageEnabled,
            hidePersonalInfo: hidePersonalInfo,
            randomBlinkEnabled: randomBlinkEnabled,
            menuBarShowsHighestUsage: menuBarShowsHighestUsage,
            claudeWebExtrasEnabledRaw: claudeWebExtrasEnabledRaw,
            showOptionalCreditsAndExtraUsage: showOptionalCreditsAndExtraUsage,
            openAIWebAccessEnabled: openAIWebAccessEnabled,
            jetbrainsIDEBasePath: jetbrainsIDEBasePath,
            mergeIcons: mergeIcons,
            switcherShowsIcons: switcherShowsIcons,
            selectedMenuProviderRaw: selectedMenuProviderRaw,
            providerDetectionCompleted: providerDetectionCompleted,
            appLanguageRaw: appLanguageRaw,
            cliProxyGlobalBaseURL: cliProxyGlobalBaseURL,
            cliProxyGlobalManagementKey: cliProxyGlobalManagementKey,
            cliProxyGlobalAuthIndex: cliProxyGlobalAuthIndex)
    }
}

extension SettingsStore {
    var configSnapshot: CodexBarConfig {
        _ = self.configRevision
        return self.config
    }

    func updateProviderState(config: CodexBarConfig) {
        let rawOrder = config.providers.map(\.id.rawValue)
        self.providerOrder = Self.effectiveProviderOrder(raw: rawOrder)
        let metadata = ProviderDescriptorRegistry.metadata
        var enablement: [UsageProvider: Bool] = [:]
        enablement.reserveCapacity(metadata.count)
        for provider in UsageProvider.allCases {
            let defaultEnabled = metadata[provider]?.defaultEnabled ?? false
            enablement[provider] = config.providerConfig(for: provider)?.enabled ?? defaultEnabled
        }
        self.providerEnablement = enablement
    }

    func orderedProviders() -> [UsageProvider] {
        if self.providerOrder.isEmpty {
            self.updateProviderState(config: self.configSnapshot)
        }
        return self.providerOrder
    }

    func moveProvider(fromOffsets: IndexSet, toOffset: Int) {
        var order = self.orderedProviders()
        order.move(fromOffsets: fromOffsets, toOffset: toOffset)
        self.setProviderOrder(order)
    }

    func isProviderEnabled(provider: UsageProvider, metadata: ProviderMetadata) -> Bool {
        self.providerEnablement[provider] ?? metadata.defaultEnabled
    }

    func isProviderEnabledCached(
        provider: UsageProvider,
        metadataByProvider: [UsageProvider: ProviderMetadata]) -> Bool
    {
        let defaultEnabled = metadataByProvider[provider]?.defaultEnabled ?? false
        return self.providerEnablement[provider] ?? defaultEnabled
    }

    func enabledProvidersOrdered(metadataByProvider: [UsageProvider: ProviderMetadata]) -> [UsageProvider] {
        _ = metadataByProvider
        return self.orderedProviders().filter { self.providerEnablement[$0] ?? false }
    }

    func setProviderEnabled(provider: UsageProvider, metadata _: ProviderMetadata, enabled: Bool) {
        CodexBarLog.logger(LogCategories.settings).debug(
            "Provider toggle updated",
            metadata: ["provider": provider.rawValue, "enabled": "\(enabled)"])
        self.updateProviderConfig(provider: provider) { entry in
            entry.enabled = enabled
        }
    }

    func rerunProviderDetection() {
        self.runInitialProviderDetectionIfNeeded(force: true)
    }
}

extension SettingsStore {
    private static func effectiveProviderOrder(raw: [String]) -> [UsageProvider] {
        var seen: Set<UsageProvider> = []
        var ordered: [UsageProvider] = []

        for rawValue in raw {
            guard let provider = UsageProvider(rawValue: rawValue) else { continue }
            guard !seen.contains(provider) else { continue }
            seen.insert(provider)
            ordered.append(provider)
        }

        if ordered.isEmpty {
            ordered = UsageProvider.allCases
            seen = Set(ordered)
        }

        if !seen.contains(.factory), let zaiIndex = ordered.firstIndex(of: .zai) {
            ordered.insert(.factory, at: zaiIndex)
            seen.insert(.factory)
        }

        if !seen.contains(.minimax), let zaiIndex = ordered.firstIndex(of: .zai) {
            let insertIndex = ordered.index(after: zaiIndex)
            ordered.insert(.minimax, at: insertIndex)
            seen.insert(.minimax)
        }

        for provider in UsageProvider.allCases where !seen.contains(provider) {
            ordered.append(provider)
        }

        return ordered
    }
}
