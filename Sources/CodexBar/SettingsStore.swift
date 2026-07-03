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
        case .manual: L("refresh_manual")
        case .oneMinute: L("refresh_1min")
        case .twoMinutes: L("refresh_2min")
        case .fiveMinutes: L("refresh_5min")
        case .fifteenMinutes: L("refresh_15min")
        case .thirtyMinutes: L("refresh_30min")
        }
    }
}

enum MenuBarMetricPreference: String, CaseIterable, Identifiable {
    case automatic
    case primary
    case secondary
    case primaryAndSecondary
    case tertiary
    case extraUsage
    case average
    case monthlyPlan

    var id: String {
        self.rawValue
    }

    var label: String {
        switch self {
        case .automatic: L("metric_pref_automatic")
        case .primary: L("metric_pref_primary")
        case .secondary: L("metric_pref_secondary")
        case .primaryAndSecondary: "\(L("metric_pref_primary")) + \(L("metric_pref_secondary"))"
        case .tertiary: L("metric_pref_tertiary")
        case .extraUsage: L("metric_pref_extra_usage")
        case .average: L("metric_pref_average")
        case .monthlyPlan: L("metric_mistral_monthly_plan")
        }
    }
}

enum KiroMenuBarDisplayMode: String, CaseIterable, Identifiable {
    case automatic
    case hidden
    case creditsLeft
    case percentLeft
    case creditsAndPercent
    case usedAndTotal
    case overageCreditsWhenExhausted
    case overageCostWhenExhausted
    case overageCreditsAndCostWhenExhausted

    var id: String {
        self.rawValue
    }

    var label: String {
        switch self {
        case .automatic: L("Automatic")
        case .hidden: L("Hidden")
        case .creditsLeft: L("Credits left")
        case .percentLeft: L("Percent left")
        case .creditsAndPercent: L("Credits + percent")
        case .usedAndTotal: L("Used / total")
        case .overageCreditsWhenExhausted: L("Overage credits at zero")
        case .overageCostWhenExhausted: L("Overage cost at zero")
        case .overageCreditsAndCostWhenExhausted: L("Overage credits + cost at zero")
        }
    }
}

enum MultiAccountMenuLayout: String, CaseIterable, Identifiable {
    case segmented
    case stacked

    var id: String {
        self.rawValue
    }

    var label: String {
        switch self {
        case .segmented: L("multi_account_layout_segmented")
        case .stacked: L("multi_account_layout_stacked")
        }
    }
}

enum CostSummaryDisplayStyle: String, CaseIterable, Identifiable {
    case inlineSummary
    case costSubmenu
    case both

    var id: String {
        self.rawValue
    }

    var label: String {
        switch self {
        case .inlineSummary: L("cost_summary_style_inline")
        case .costSubmenu: L("cost_summary_style_submenu")
        case .both: L("cost_summary_style_both")
        }
    }

    var helpText: String {
        switch self {
        case .inlineSummary: L("cost_summary_style_inline_help")
        case .costSubmenu: L("cost_summary_style_submenu_help")
        case .both: L("cost_summary_style_both_help")
        }
    }

    var showsInlineSummary: Bool {
        self != .costSubmenu
    }

    var showsCostSubmenu: Bool {
        self != .inlineSummary
    }
}

struct CachedCodexAccountReconciliationSnapshot {
    let activeSource: CodexActiveSource
    let loadedAt: Date
    let snapshot: CodexAccountReconciliationSnapshot
}

struct CachedCodexAccountMenuProjection: Equatable {
    let activeSource: CodexActiveSource
    let loadedAt: Date
    let projection: CodexVisibleAccountProjection
}

enum CodexAccountMenuProjectionRevalidationResult: Equatable {
    case skipped
    case discarded
    case unchanged
    case updated
}

@MainActor
@Observable
final class SettingsStore {
    static let sharedDefaults = AppGroupSupport.sharedDefaults()
    static let mergedOverviewProviderLimit = 3
    static let productionCodexAccountReconciliationSnapshotCacheInterval: TimeInterval = 2
    static let isRunningTests: Bool = {
        let env = ProcessInfo.processInfo.environment
        if env["XCTestConfigurationFilePath"] != nil { return true }
        if env["TESTING_LIBRARY_VERSION"] != nil { return true }
        if env["SWIFT_TESTING"] != nil { return true }
        return NSClassFromString("XCTestCase") != nil
    }()

    #if DEBUG
    static var codexAccountReconciliationSnapshotCacheIntervalOverrideForTesting: TimeInterval?
    #endif

    @ObservationIgnored let userDefaults: UserDefaults
    @ObservationIgnored let configStore: CodexBarConfigStore
    @ObservationIgnored let antigravityOAuthCredentialsStore: AntigravityOAuthCredentialsStore
    @ObservationIgnored var config: CodexBarConfig
    @ObservationIgnored var configPersistTask: Task<Void, Never>?
    @ObservationIgnored var configLoading = false
    @ObservationIgnored var tokenAccountsLoaded = false
    @ObservationIgnored var cachedCodexAccountReconciliationSnapshot:
        CachedCodexAccountReconciliationSnapshot?
    @ObservationIgnored var cachedCodexAccountMenuProjection: CachedCodexAccountMenuProjection?
    @ObservationIgnored var codexAccountReconciliationGeneration: UInt = 0
    #if DEBUG
    @ObservationIgnored var _test_codexAccountSnapshotLoader:
        (@Sendable (CodexActiveSource) -> CodexAccountReconciliationSnapshot)?
    #endif
    @ObservationIgnored var mergedMenuLastSelectedWasOverviewStorage = false
    @ObservationIgnored var selectedMenuProviderRawStorage: String?
    var defaultsState: SettingsDefaultsState
    var configRevision: Int = 0
    var providerOrder: [UsageProvider] = []
    var providerEnablement: [UsageProvider: Bool] = [:]

    static func shouldBridgeSharedDefaults(for userDefaults: UserDefaults) -> Bool {
        if !self.isRunningTests { return true }
        if userDefaults === UserDefaults.standard { return true }
        if let shared = sharedDefaults, userDefaults === shared { return true }
        return false
    }

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
        tokenAccountStore: any ProviderTokenAccountStoring = FileTokenAccountStore(),
        antigravityOAuthCredentialsStore: AntigravityOAuthCredentialsStore = AntigravityOAuthCredentialsStore(),
        performInitialProviderDetection: Bool = !SettingsStore.isRunningTests)
    {
        let appGroupID = AppGroupSupport.currentGroupID()
        let appGroupMigration: AppGroupSupport.MigrationResult
        if Self.isRunningTests {
            appGroupMigration = AppGroupSupport.migrateLegacyDataIfNeeded(standardDefaults: userDefaults)
        } else {
            Self.scheduleAppGroupMigration()
            appGroupMigration = AppGroupSupport.MigrationResult(status: .targetUnavailable)
        }
        let sharedDefaultsAvailable = Self.sharedDefaults != nil
        if !Self.isRunningTests {
            CodexBarLog.logger(LogCategories.settings).info(
                "App group resolved",
                metadata: [
                    "groupID": appGroupID,
                    "sharedDefaultsAvailable": sharedDefaultsAvailable ? "1" : "0",
                    "migrationStatus": appGroupMigration.status.rawValue,
                    "migratedSnapshot": appGroupMigration.copiedSnapshot ? "1" : "0",
                    "migratedDefaults": "\(appGroupMigration.copiedDefaults)",
                ])
        }

        if userDefaults.object(forKey: "openAIWebAccessEnabled") == nil,
           let legacyOpenAIWebAccess = userDefaults.object(forKey: "openAIWebAccess") as? Bool
        {
            userDefaults.set(legacyOpenAIWebAccess, forKey: "openAIWebAccessEnabled")
        }
        let hasStoredOpenAIWebAccessPreference = userDefaults.object(forKey: "openAIWebAccessEnabled") != nil
        let hadExistingConfig = (try? configStore.load()) != nil
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
        self.antigravityOAuthCredentialsStore = antigravityOAuthCredentialsStore
        self.config = config
        self.configLoading = true
        let defaultsState = Self.loadDefaultsState(userDefaults: userDefaults)
        self.defaultsState = defaultsState
        self.mergedMenuLastSelectedWasOverviewStorage = defaultsState.mergedMenuLastSelectedWasOverview
        self.selectedMenuProviderRawStorage = defaultsState.selectedMenuProviderRaw
        self.updateProviderState(config: config)
        self.configLoading = false
        CodexBarLog.setFileLoggingEnabled(self.debugFileLoggingEnabled)
        userDefaults.removeObject(forKey: "showCodexUsage")
        userDefaults.removeObject(forKey: "showClaudeUsage")
        LaunchAtLoginManager.setEnabled(self.launchAtLogin)
        if performInitialProviderDetection {
            self.runInitialProviderDetectionIfNeeded()
        }
        self.ensureAlibabaProviderAutoEnabledIfNeeded()
        self.applyTokenCostDefaultIfNeeded()
        if self.claudeUsageDataSource != .cli {
            if Self.isRunningTests {
                self.claudeWebExtrasEnabled = false
            } else {
                self.defaultsState.claudeWebExtrasEnabledRaw = false
            }
        }
        let resolvedOpenAIWebAccessEnabled = if hasStoredOpenAIWebAccessPreference {
            self.defaultsState.openAIWebAccessEnabled
        } else {
            Self.inferredInitialOpenAIWebAccessEnabled(
                config: config,
                hadExistingConfig: hadExistingConfig)
        }
        if Self.isRunningTests {
            self.openAIWebAccessEnabled = resolvedOpenAIWebAccessEnabled
        } else {
            self.defaultsState.openAIWebAccessEnabled = resolvedOpenAIWebAccessEnabled
        }
        KeychainAccessGate.isDisabled = self.debugDisableKeychainAccess
    }
}

extension SettingsStore {
    private static func scheduleAppGroupMigration() {
        Task.detached(priority: .utility) {
            let result = AppGroupSupport.migrateLegacyDataIfNeeded()
            CodexBarLog.logger(LogCategories.settings).info(
                "App group migration completed",
                metadata: [
                    "migrationStatus": result.status.rawValue,
                    "migratedSnapshot": result.copiedSnapshot ? "1" : "0",
                    "migratedDefaults": "\(result.copiedDefaults)",
                ])
        }
    }

    private static func inferredInitialOpenAIWebAccessEnabled(
        config: CodexBarConfig,
        hadExistingConfig: Bool) -> Bool
    {
        guard let codex = config.providerConfig(for: .codex) else { return false }
        if let cookieSource = codex.cookieSource { return cookieSource.isEnabled }
        if codex.sanitizedCookieHeader != nil { return true }
        return hadExistingConfig
    }

    private static func loadDefaultsState(userDefaults: UserDefaults) -> SettingsDefaultsState {
        let refreshDefault = userDefaults.string(forKey: "refreshFrequency")
            .flatMap(RefreshFrequency.init(rawValue:))
        let refreshFrequency = refreshDefault ?? .fiveMinutes
        if Self.isRunningTests, refreshDefault == nil {
            userDefaults.set(refreshFrequency.rawValue, forKey: "refreshFrequency")
        }
        let refreshAllProvidersOnMenuOpen = userDefaults.object(
            forKey: "refreshAllProvidersOnMenuOpen") as? Bool ?? false
        let launchAtLogin = userDefaults.object(forKey: "launchAtLogin") as? Bool ?? false
        let debugMenuEnabled = userDefaults.object(forKey: "debugMenuEnabled") as? Bool ?? false
        let debugDisableKeychainAccess = Self.loadDebugDisableKeychainAccess(userDefaults: userDefaults)
        let debugFileLoggingEnabled = userDefaults.object(forKey: "debugFileLoggingEnabled") as? Bool ?? false
        let debugLogLevelRaw = userDefaults.string(forKey: "debugLogLevel") ?? CodexBarLog.Level.verbose.rawValue
        if Self.isRunningTests, userDefaults.string(forKey: "debugLogLevel") == nil {
            userDefaults.set(debugLogLevelRaw, forKey: "debugLogLevel")
        }
        let debugLoadingPatternRaw = userDefaults.string(forKey: "debugLoadingPattern")
        let debugKeepCLISessionsAlive = userDefaults.object(forKey: "debugKeepCLISessionsAlive") as? Bool ?? false
        let statusChecksEnabled = userDefaults.object(forKey: "statusChecksEnabled") as? Bool ?? true
        let sessionQuotaNotificationsEnabled = Self.loadSessionQuotaNotificationsDefault(userDefaults: userDefaults)
        let quotaWarnings = Self.loadQuotaWarningDefaults(userDefaults: userDefaults)
        let quotaWarningMarkersVisibleDefault = userDefaults.object(forKey: "quotaWarningMarkersVisible") as? Bool
        let quotaWarningMarkersVisible = quotaWarningMarkersVisibleDefault ?? true
        if Self.isRunningTests, quotaWarningMarkersVisibleDefault == nil {
            userDefaults.set(true, forKey: "quotaWarningMarkersVisible")
        }
        let weeklyProgressWorkDays = userDefaults.object(forKey: "weeklyProgressWorkDays") as? Int
        let usageBarsShowUsed = userDefaults.object(forKey: "usageBarsShowUsed") as? Bool ?? false
        let resetTimesShowAbsolute = userDefaults.object(forKey: "resetTimesShowAbsolute") as? Bool ?? false
        let providerChangelogLinksEnabled = userDefaults.object(
            forKey: "providerChangelogLinksEnabled") as? Bool ?? false
        let menuBarShowsBrandIconWithPercent = userDefaults.object(
            forKey: "menuBarShowsBrandIconWithPercent") as? Bool ?? false
        let menuBarHidesCritters = userDefaults.object(forKey: "menuBarHidesCritters") as? Bool ?? false
        let menuBarDisplayModeRaw = userDefaults.string(forKey: "menuBarDisplayMode")
            ?? MenuBarDisplayMode.percent.rawValue
        let kiroMenuBarDisplayModeRaw = userDefaults.string(forKey: "kiroMenuBarDisplayMode")
            ?? KiroMenuBarDisplayMode.automatic.rawValue
        let historicalTrackingEnabled = userDefaults.object(forKey: "historicalTrackingEnabled") as? Bool ?? false
        let multiAccountMenuLayoutRaw = Self.loadMultiAccountMenuLayoutRaw(userDefaults: userDefaults)
        let resolvedPreferences = Self.loadMenuBarMetricPreferences(userDefaults: userDefaults)
        let copilotBudgetExtrasEnabled = userDefaults.object(forKey: "copilotBudgetExtrasEnabled") as? Bool ?? false
        let copilotIconSecondaryWindowIDRaw = Self.loadCopilotIconSecondaryWindowIDRaw(userDefaults: userDefaults)
        let costUsageEnabled = userDefaults.object(forKey: "tokenCostUsageEnabled") as? Bool ?? false
        let rawCostUsageHistoryDays = userDefaults.object(forKey: "tokenCostUsageHistoryDays") as? Int ?? 30
        let costUsageHistoryDays = max(1, min(365, rawCostUsageHistoryDays))
        let costSummaryDisplayStyleRaw = Self.loadCostSummaryDisplayStyleRaw(
            userDefaults: userDefaults,
            costUsageEnabled: costUsageEnabled)
        let hidePersonalInfo = userDefaults.object(forKey: "hidePersonalInfo") as? Bool ?? false
        let randomBlinkEnabled = userDefaults.object(forKey: "randomBlinkEnabled") as? Bool ?? false
        let confettiOnReset = Self.loadConfettiOnResetDefaults(userDefaults: userDefaults)
        let menuBarShowsHighestUsage = userDefaults.object(forKey: "menuBarShowsHighestUsage") as? Bool ?? false
        let claudeOAuthKeychainPromptModeRaw = userDefaults.string(forKey: "claudeOAuthKeychainPromptMode")
        let claudeOAuthKeychainReadStrategyRaw = userDefaults.string(forKey: "claudeOAuthKeychainReadStrategy")
        let claudeWebExtrasEnabledRaw = userDefaults.object(forKey: "claudeWebExtrasEnabled") as? Bool ?? false
        let creditsExtrasDefault = userDefaults.object(forKey: "showOptionalCreditsAndExtraUsage") as? Bool
        let showOptionalCreditsAndExtraUsage = creditsExtrasDefault ?? true
        if Self.isRunningTests, creditsExtrasDefault == nil {
            userDefaults.set(true, forKey: "showOptionalCreditsAndExtraUsage")
        }
        let openAIWebAccessDefault = userDefaults.object(forKey: "openAIWebAccessEnabled") as? Bool
        let openAIWebAccessEnabled = openAIWebAccessDefault ?? false
        if Self.isRunningTests, openAIWebAccessDefault == nil {
            userDefaults.set(false, forKey: "openAIWebAccessEnabled")
        }
        let openAIWebBatterySaverDefault = userDefaults.object(forKey: "openAIWebBatterySaverEnabled") as? Bool
        let openAIWebBatterySaverEnabled = openAIWebBatterySaverDefault ?? false
        if Self.isRunningTests, openAIWebBatterySaverDefault == nil {
            userDefaults.set(false, forKey: "openAIWebBatterySaverEnabled")
        }
        let providerStorageFootprintsDefault = userDefaults.object(forKey: "providerStorageFootprintsEnabled") as? Bool
        let providerStorageFootprintsEnabled = providerStorageFootprintsDefault ?? false
        if Self.isRunningTests, providerStorageFootprintsDefault == nil {
            userDefaults.set(false, forKey: "providerStorageFootprintsEnabled")
        }
        let jetbrainsIDEBasePath = userDefaults.string(forKey: "jetbrainsIDEBasePath") ?? ""
        let mergeIcons = userDefaults.object(forKey: "mergeIcons") as? Bool ?? true
        let switcherShowsIcons = userDefaults.object(forKey: "switcherShowsIcons") as? Bool ?? true
        let mergedMenuLastSelectedWasOverview = userDefaults.object(
            forKey: "mergedMenuLastSelectedWasOverview") as? Bool ?? false
        let mergedOverviewSelectedProvidersRaw = userDefaults.array(
            forKey: "mergedOverviewSelectedProviders") as? [String] ?? []
        let selectedMenuProviderRaw = userDefaults.string(forKey: "selectedMenuProvider")
        let providerDetectionCompleted = userDefaults.object(forKey: "providerDetectionCompleted") as? Bool ?? false
        let providersSortedAlphabetically = userDefaults.object(
            forKey: "providersSortedAlphabetically") as? Bool ?? false
        let appLanguageRaw = userDefaults.string(forKey: "appLanguage")
        return SettingsDefaultsState(
            refreshFrequency: refreshFrequency,
            refreshAllProvidersOnMenuOpen: refreshAllProvidersOnMenuOpen,
            launchAtLogin: launchAtLogin,
            debugMenuEnabled: debugMenuEnabled,
            debugDisableKeychainAccess: debugDisableKeychainAccess,
            debugFileLoggingEnabled: debugFileLoggingEnabled,
            debugLogLevelRaw: debugLogLevelRaw,
            debugLoadingPatternRaw: debugLoadingPatternRaw,
            debugKeepCLISessionsAlive: debugKeepCLISessionsAlive,
            statusChecksEnabled: statusChecksEnabled,
            sessionQuotaNotificationsEnabled: sessionQuotaNotificationsEnabled,
            quotaWarningNotificationsEnabled: quotaWarnings.notificationsEnabled,
            quotaWarningThresholdsRaw: quotaWarnings.thresholdsRaw,
            quotaWarningSessionThresholdsRaw: quotaWarnings.sessionThresholdsRaw,
            quotaWarningWeeklyThresholdsRaw: quotaWarnings.weeklyThresholdsRaw,
            quotaWarningSessionEnabled: quotaWarnings.sessionEnabled,
            quotaWarningWeeklyEnabled: quotaWarnings.weeklyEnabled,
            quotaWarningSoundEnabled: quotaWarnings.soundEnabled,
            quotaWarningOnScreenAlertEnabled: quotaWarnings.onScreenAlertEnabled,
            quotaWarningMarkersVisible: quotaWarningMarkersVisible,
            weeklyProgressWorkDays: weeklyProgressWorkDays,
            usageBarsShowUsed: usageBarsShowUsed,
            resetTimesShowAbsolute: resetTimesShowAbsolute,
            providerChangelogLinksEnabled: providerChangelogLinksEnabled,
            menuBarShowsBrandIconWithPercent: menuBarShowsBrandIconWithPercent,
            menuBarHidesCritters: menuBarHidesCritters,
            menuBarDisplayModeRaw: menuBarDisplayModeRaw,
            kiroMenuBarDisplayModeRaw: kiroMenuBarDisplayModeRaw,
            historicalTrackingEnabled: historicalTrackingEnabled,
            multiAccountMenuLayoutRaw: multiAccountMenuLayoutRaw,
            menuBarMetricPreferencesRaw: resolvedPreferences,
            copilotBudgetExtrasEnabled: copilotBudgetExtrasEnabled,
            copilotIconSecondaryWindowIDRaw: copilotIconSecondaryWindowIDRaw,
            costUsageEnabled: costUsageEnabled,
            costUsageHistoryDays: costUsageHistoryDays,
            costSummaryDisplayStyleRaw: costSummaryDisplayStyleRaw,
            hidePersonalInfo: hidePersonalInfo,
            randomBlinkEnabled: randomBlinkEnabled,
            confettiOnSessionLimitResetsEnabled: confettiOnReset.session,
            confettiOnWeeklyLimitResetsEnabled: confettiOnReset.weekly,
            menuBarShowsHighestUsage: menuBarShowsHighestUsage,
            claudeOAuthKeychainPromptModeRaw: claudeOAuthKeychainPromptModeRaw,
            claudeOAuthKeychainReadStrategyRaw: claudeOAuthKeychainReadStrategyRaw,
            claudeWebExtrasEnabledRaw: claudeWebExtrasEnabledRaw,
            showOptionalCreditsAndExtraUsage: showOptionalCreditsAndExtraUsage,
            openAIWebAccessEnabled: openAIWebAccessEnabled,
            openAIWebBatterySaverEnabled: openAIWebBatterySaverEnabled,
            providerStorageFootprintsEnabled: providerStorageFootprintsEnabled,
            jetbrainsIDEBasePath: jetbrainsIDEBasePath,
            mergeIcons: mergeIcons,
            switcherShowsIcons: switcherShowsIcons,
            mergedMenuLastSelectedWasOverview: mergedMenuLastSelectedWasOverview,
            mergedOverviewSelectedProvidersRaw: mergedOverviewSelectedProvidersRaw,
            selectedMenuProviderRaw: selectedMenuProviderRaw,
            providerDetectionCompleted: providerDetectionCompleted,
            providersSortedAlphabetically: providersSortedAlphabetically,
            appLanguageRaw: appLanguageRaw,
            terminalAppRaw: userDefaults.string(forKey: "terminalApp"))
    }

    private static func loadCostSummaryDisplayStyleRaw(
        userDefaults: UserDefaults,
        costUsageEnabled: Bool) -> String
    {
        if let storedCostSummaryDisplayStyle = userDefaults.string(forKey: "costSummaryDisplayStyle"),
           CostSummaryDisplayStyle(rawValue: storedCostSummaryDisplayStyle) != nil
        {
            return storedCostSummaryDisplayStyle
        }
        let migratedStyle = CostSummaryDisplayStyle.both.rawValue
        if costUsageEnabled || userDefaults.object(forKey: "costSummaryDisplayStyle") != nil {
            userDefaults.set(migratedStyle, forKey: "costSummaryDisplayStyle")
        }
        return migratedStyle
    }

    private static func loadConfettiOnResetDefaults(userDefaults: UserDefaults) -> (session: Bool, weekly: Bool) {
        (
            session: userDefaults.object(forKey: "confettiOnSessionLimitResetsEnabled") as? Bool ?? false,
            weekly: userDefaults.object(forKey: "confettiOnWeeklyLimitResetsEnabled") as? Bool ?? false)
    }

    private static func loadMenuBarMetricPreferences(userDefaults: UserDefaults) -> [String: String] {
        let storedPreferences = userDefaults.dictionary(forKey: "menuBarMetricPreferences") as? [String: String] ?? [:]
        let preferences: [String: String] = if !storedPreferences.isEmpty {
            storedPreferences
        } else if let menuBarMetricRaw = userDefaults.string(forKey: "menuBarMetricPreference"),
                  let legacyPreference = MenuBarMetricPreference(rawValue: menuBarMetricRaw)
        {
            Dictionary(
                uniqueKeysWithValues: UsageProvider.allCases.map { ($0.rawValue, legacyPreference.rawValue) })
        } else {
            [:]
        }

        let migrationKey = "antigravityTwoPoolMetricPreferenceMigrated"
        guard !userDefaults.bool(forKey: migrationKey) else { return preferences }

        // Tagged builds through v0.35 used primary=Claude, secondary=Gemini Pro,
        // and tertiary=Gemini Flash. Remap those meanings once to the two-pool schema.
        var migrated = preferences
        switch MenuBarMetricPreference(rawValue: migrated[UsageProvider.antigravity.rawValue] ?? "") {
        case .primary:
            migrated[UsageProvider.antigravity.rawValue] = MenuBarMetricPreference.secondary.rawValue
        case .secondary:
            migrated[UsageProvider.antigravity.rawValue] = MenuBarMetricPreference.primary.rawValue
        case .tertiary:
            migrated[UsageProvider.antigravity.rawValue] = MenuBarMetricPreference.primary.rawValue
        case .automatic, .primaryAndSecondary, .extraUsage, .average, .monthlyPlan, .none:
            break
        }
        userDefaults.set(migrated, forKey: "menuBarMetricPreferences")
        userDefaults.set(true, forKey: migrationKey)
        return migrated
    }

    private static func loadMultiAccountMenuLayoutRaw(userDefaults: UserDefaults) -> String {
        if let layout = userDefaults.string(forKey: "multiAccountMenuLayout") {
            return layout
        }
        let legacyShowAll = userDefaults.object(forKey: "showAllTokenAccountsInMenu") as? Bool ?? false
        return legacyShowAll ? MultiAccountMenuLayout.stacked.rawValue : MultiAccountMenuLayout.segmented.rawValue
    }

    private static func loadCopilotIconSecondaryWindowIDRaw(userDefaults: UserDefaults) -> String {
        userDefaults.string(forKey: "copilotIconSecondaryWindowID") ?? CopilotIconSecondaryWindowSelection.chat
    }

    private static func loadDebugDisableKeychainAccess(userDefaults: UserDefaults) -> Bool {
        if let stored = userDefaults.object(forKey: "debugDisableKeychainAccess") as? Bool {
            return stored
        }
        if Self.shouldBridgeSharedDefaults(for: userDefaults),
           let shared = Self.sharedDefaults?.object(forKey: "debugDisableKeychainAccess") as? Bool
        {
            if Self.isRunningTests {
                userDefaults.set(shared, forKey: "debugDisableKeychainAccess")
            }
            return shared
        }
        return false
    }

    private struct LoadedQuotaWarningDefaults {
        var notificationsEnabled: Bool
        var thresholdsRaw: [Int]
        var sessionThresholdsRaw: [Int]
        var weeklyThresholdsRaw: [Int]
        var sessionEnabled: Bool
        var weeklyEnabled: Bool
        var soundEnabled: Bool
        var onScreenAlertEnabled: Bool
    }

    private static func loadSessionQuotaNotificationsDefault(userDefaults: UserDefaults) -> Bool {
        let stored = userDefaults.object(forKey: "sessionQuotaNotificationsEnabled") as? Bool
        if Self.isRunningTests, stored == nil {
            userDefaults.set(true, forKey: "sessionQuotaNotificationsEnabled")
        }
        return stored ?? true
    }

    private static func loadQuotaWarningDefaults(userDefaults: UserDefaults) -> LoadedQuotaWarningDefaults {
        let notificationsEnabled = userDefaults.object(forKey: "quotaWarningNotificationsEnabled") as? Bool ?? false
        let rawThresholds = userDefaults.array(forKey: "quotaWarningThresholds") as? [Int]
        let thresholdsRaw = QuotaWarningThresholds.sanitized(rawThresholds ?? QuotaWarningThresholds.defaults)
        if Self.isRunningTests, rawThresholds != thresholdsRaw {
            userDefaults.set(thresholdsRaw, forKey: "quotaWarningThresholds")
        }
        let rawSessionThresholds = userDefaults.array(forKey: "quotaWarningSessionThresholds") as? [Int]
        let sessionThresholdsRaw = QuotaWarningThresholds.sanitized(rawSessionThresholds ?? thresholdsRaw)
        if Self.isRunningTests, rawSessionThresholds != sessionThresholdsRaw {
            userDefaults.set(sessionThresholdsRaw, forKey: "quotaWarningSessionThresholds")
        }
        let rawWeeklyThresholds = userDefaults.array(forKey: "quotaWarningWeeklyThresholds") as? [Int]
        let weeklyThresholdsRaw = QuotaWarningThresholds.sanitized(rawWeeklyThresholds ?? thresholdsRaw)
        if Self.isRunningTests, rawWeeklyThresholds != weeklyThresholdsRaw {
            userDefaults.set(weeklyThresholdsRaw, forKey: "quotaWarningWeeklyThresholds")
        }

        let sessionDefault = userDefaults.object(forKey: "quotaWarningSessionEnabled") as? Bool
        let sessionEnabled = sessionDefault ?? true
        if Self.isRunningTests, sessionDefault == nil {
            userDefaults.set(true, forKey: "quotaWarningSessionEnabled")
        }

        let weeklyDefault = userDefaults.object(forKey: "quotaWarningWeeklyEnabled") as? Bool
        let weeklyEnabled = weeklyDefault ?? true
        if Self.isRunningTests, weeklyDefault == nil {
            userDefaults.set(true, forKey: "quotaWarningWeeklyEnabled")
        }

        let soundDefault = userDefaults.object(forKey: "quotaWarningSoundEnabled") as? Bool
        let soundEnabled = soundDefault ?? true
        if Self.isRunningTests, soundDefault == nil {
            userDefaults.set(true, forKey: "quotaWarningSoundEnabled")
        }

        let onScreenAlertDefault = userDefaults.object(forKey: "quotaWarningOnScreenAlertEnabled") as? Bool
        let onScreenAlertEnabled = onScreenAlertDefault ?? false
        if Self.isRunningTests, onScreenAlertDefault == nil {
            userDefaults.set(false, forKey: "quotaWarningOnScreenAlertEnabled")
        }

        return LoadedQuotaWarningDefaults(
            notificationsEnabled: notificationsEnabled,
            thresholdsRaw: thresholdsRaw,
            sessionThresholdsRaw: sessionThresholdsRaw,
            weeklyThresholdsRaw: weeklyThresholdsRaw,
            sessionEnabled: sessionEnabled,
            weeklyEnabled: weeklyEnabled,
            soundEnabled: soundEnabled,
            onScreenAlertEnabled: onScreenAlertEnabled)
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
        if !enabled, self.selectedMenuProvider == provider {
            self.selectedMenuProvider = nil
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
