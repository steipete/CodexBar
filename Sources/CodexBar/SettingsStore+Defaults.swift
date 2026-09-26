import CodexBarCore
import Foundation
import ServiceManagement

extension SettingsStore {
    static let mergedOverviewSelectionEditedActiveProvidersKey = "mergedOverviewSelectionEditedActiveProviders"

    func setDefault<Value>(_ path: WritableKeyPath<SettingsDefaultsState, Value>, _ value: Value, key: String) {
        self.defaultsState[keyPath: path] = value
        self.userDefaults.set(value, forKey: key)
    }

    private func setOptionalDefault<Value>(
        _ path: WritableKeyPath<SettingsDefaultsState, Value?>,
        _ value: Value?,
        key: String)
    {
        self.defaultsState[keyPath: path] = value
        if let value {
            self.userDefaults.set(value, forKey: key)
        } else {
            self.userDefaults.removeObject(forKey: key)
        }
    }

    private func setCostDefault<Value: Equatable>(
        _ path: WritableKeyPath<SettingsDefaultsState, Value>,
        _ value: Value,
        key: String)
    {
        let changed = self.defaultsState[keyPath: path] != value
        self.setDefault(path, value, key: key)
        if changed { self.costUsageSettingsRevision &+= 1 }
    }

    func noteBackgroundWorkSettingsChanged() {
        self.backgroundWorkSettingsRevision &+= 1
    }

    var refreshFrequency: RefreshFrequency {
        get { self.defaultsState.refreshFrequency }
        set {
            let previousValue = self.defaultsState.refreshFrequency
            if newValue == .adaptiveAgentAware,
               previousValue != .adaptiveAgentAware,
               self.defaultsState.adaptiveActivityScanConsent == .declined
            {
                self.defaultsState.adaptiveActivityScanConsent = .undecided
                self.userDefaults.set(
                    AdaptiveActivityScanConsent.undecided.rawValue,
                    forKey: "adaptiveActivityScanConsent")
            }
            self.defaultsState.refreshFrequency = newValue
            self.userDefaults.set(newValue.rawValue, forKey: "refreshFrequency")
            self.noteBackgroundWorkSettingsChanged()
        }
    }

    var adaptiveActivityScanConsent: AdaptiveActivityScanConsent {
        get { self.defaultsState.adaptiveActivityScanConsent }
        set {
            self.defaultsState.adaptiveActivityScanConsent = newValue
            self.userDefaults.set(newValue.rawValue, forKey: "adaptiveActivityScanConsent")
            self.noteBackgroundWorkSettingsChanged()
        }
    }

    var adaptiveActivityScanningEnabled: Bool {
        self.refreshFrequency == .adaptiveAgentAware && self.adaptiveActivityScanConsent == .allowed
    }

    var shouldRequestAdaptiveActivityScanConsent: Bool {
        self.refreshFrequency == .adaptiveAgentAware && self.adaptiveActivityScanConsent == .undecided
    }

    /// When enabled, keeping the menu open through its short refresh delay fetches usage for every
    /// enabled provider. The periodic refresh clock remains unchanged. See `scheduleOpenMenuRefresh`.
    var refreshAllProvidersOnMenuOpen: Bool {
        get { self.defaultsState.refreshAllProvidersOnMenuOpen }
        set { self.setDefault(\.refreshAllProvidersOnMenuOpen, newValue, key: "refreshAllProvidersOnMenuOpen") }
    }

    var launchAtLogin: Bool {
        get { self.defaultsState.launchAtLogin }
        set {
            self.setDefault(\.launchAtLogin, newValue, key: "launchAtLogin")
            LaunchAtLoginManager.setEnabled(newValue)
        }
    }

    var debugMenuEnabled: Bool {
        get { self.defaultsState.debugMenuEnabled }
        set { self.setDefault(\.debugMenuEnabled, newValue, key: "debugMenuEnabled") }
    }

    var debugDisableKeychainAccess: Bool {
        get { self.defaultsState.debugDisableKeychainAccess }
        set {
            self.setDefault(\.debugDisableKeychainAccess, newValue, key: "debugDisableKeychainAccess")
            if Self.shouldBridgeSharedDefaults(for: self.userDefaults) {
                Self.sharedDefaults?.set(newValue, forKey: "debugDisableKeychainAccess")
            }
            self.keychainAccessPolicy.setDisabled(newValue)
            self.noteBackgroundWorkSettingsChanged()
        }
    }

    var debugFileLoggingEnabled: Bool {
        get { self.defaultsState.debugFileLoggingEnabled }
        set {
            self.setDefault(\.debugFileLoggingEnabled, newValue, key: "debugFileLoggingEnabled")
            CodexBarLog.setFileLoggingEnabled(newValue)
        }
    }

    var debugLogLevel: CodexBarLog.Level {
        get {
            let raw = self.defaultsState.debugLogLevelRaw
            return CodexBarLog.parseLevel(raw) ?? .verbose
        }
        set {
            self.setOptionalDefault(\.debugLogLevelRaw, newValue.rawValue, key: "debugLogLevel")
            CodexBarLog.setLogLevel(newValue)
        }
    }

    var debugKeepCLISessionsAlive: Bool {
        get { self.defaultsState.debugKeepCLISessionsAlive }
        set {
            self.setDefault(\.debugKeepCLISessionsAlive, newValue, key: "debugKeepCLISessionsAlive")
            self.noteBackgroundWorkSettingsChanged()
        }
    }

    var isVerboseLoggingEnabled: Bool {
        self.debugLogLevel.rank <= CodexBarLog.Level.verbose.rank
    }

    var statusChecksEnabled: Bool {
        get { self.defaultsState.statusChecksEnabled }
        set {
            self.setDefault(\.statusChecksEnabled, newValue, key: "statusChecksEnabled")
            self.noteBackgroundWorkSettingsChanged()
        }
    }

    var stayAwakeEnabled: Bool {
        get { self.defaultsState.stayAwakeEnabled }
        set { self.setDefault(\.stayAwakeEnabled, newValue, key: "stayAwakeEnabled") }
    }

    var credentialExpiryNotificationsEnabled: Bool {
        get { self.defaultsState.credentialExpiryNotificationsEnabled }
        set { self.setDefault(
            \.credentialExpiryNotificationsEnabled,
            newValue,
            key: "credentialExpiryNotificationsEnabled") }
    }

    var sessionQuotaNotificationsEnabled: Bool {
        get { self.defaultsState.sessionQuotaNotificationsEnabled }
        set {
            self.setDefault(\.sessionQuotaNotificationsEnabled, newValue, key: "sessionQuotaNotificationsEnabled")
            self.noteBackgroundWorkSettingsChanged()
        }
    }

    var quotaWarningNotificationsEnabled: Bool {
        get { self.defaultsState.quotaWarningNotificationsEnabled }
        set {
            self.setDefault(\.quotaWarningNotificationsEnabled, newValue, key: "quotaWarningNotificationsEnabled")
            self.noteBackgroundWorkSettingsChanged()
        }
    }

    var predictivePaceWarningNotificationsEnabled: Bool {
        get { self.defaultsState.predictivePaceWarningNotificationsEnabled }
        set {
            guard self.defaultsState.predictivePaceWarningNotificationsEnabled != newValue else { return }
            self.setDefault(
                \.predictivePaceWarningNotificationsEnabled,
                newValue,
                key: "predictivePaceWarningNotificationsEnabled")
            self.noteBackgroundWorkSettingsChanged()
        }
    }

    var quotaWarningThresholds: [Int] {
        get { QuotaWarningThresholds.sanitized(self.defaultsState.quotaWarningThresholdsRaw) }
        set {
            let sanitized = QuotaWarningThresholds.sanitized(newValue)
            guard QuotaWarningThresholds.sanitized(self.defaultsState.quotaWarningThresholdsRaw) != sanitized
                || QuotaWarningThresholds.sanitized(self.defaultsState.quotaWarningSessionThresholdsRaw) != sanitized
                || QuotaWarningThresholds.sanitized(self.defaultsState.quotaWarningWeeklyThresholdsRaw) != sanitized
            else {
                return
            }
            self.defaultsState.quotaWarningThresholdsRaw = sanitized
            self.defaultsState.quotaWarningSessionThresholdsRaw = sanitized
            self.defaultsState.quotaWarningWeeklyThresholdsRaw = sanitized
            self.userDefaults.set(sanitized, forKey: "quotaWarningThresholds")
            self.userDefaults.set(sanitized, forKey: "quotaWarningSessionThresholds")
            self.userDefaults.set(sanitized, forKey: "quotaWarningWeeklyThresholds")
            self.noteBackgroundWorkSettingsChanged()
        }
    }

    func quotaWarningThresholds(_ window: QuotaWarningWindow) -> [Int] {
        switch window {
        case .session:
            QuotaWarningThresholds.sanitized(self.defaultsState.quotaWarningSessionThresholdsRaw)
        case .weekly:
            QuotaWarningThresholds.sanitized(self.defaultsState.quotaWarningWeeklyThresholdsRaw)
        }
    }

    func setQuotaWarningThresholds(_ window: QuotaWarningWindow, thresholds: [Int]) {
        let sanitized = QuotaWarningThresholds.sanitized(thresholds)
        guard self.quotaWarningThresholds(window) != sanitized else { return }
        switch window {
        case .session:
            self.setDefault(\.quotaWarningSessionThresholdsRaw, sanitized, key: "quotaWarningSessionThresholds")
        case .weekly:
            self.setDefault(\.quotaWarningWeeklyThresholdsRaw, sanitized, key: "quotaWarningWeeklyThresholds")
        }
        self.noteBackgroundWorkSettingsChanged()
    }

    func quotaWarningWindowEnabled(_ window: QuotaWarningWindow) -> Bool {
        switch window {
        case .session:
            self.defaultsState.quotaWarningSessionEnabled
        case .weekly:
            self.defaultsState.quotaWarningWeeklyEnabled
        }
    }

    func setQuotaWarningWindowEnabled(_ window: QuotaWarningWindow, enabled: Bool) {
        switch window {
        case .session:
            self.setDefault(\.quotaWarningSessionEnabled, enabled, key: "quotaWarningSessionEnabled")
        case .weekly:
            self.setDefault(\.quotaWarningWeeklyEnabled, enabled, key: "quotaWarningWeeklyEnabled")
        }
        self.noteBackgroundWorkSettingsChanged()
    }

    var quotaWarningSoundEnabled: Bool {
        get { self.defaultsState.quotaWarningSoundEnabled }
        set {
            self.setDefault(\.quotaWarningSoundEnabled, newValue, key: "quotaWarningSoundEnabled")
            self.noteBackgroundWorkSettingsChanged()
        }
    }

    var quotaWarningOnScreenAlertEnabled: Bool {
        get { self.defaultsState.quotaWarningOnScreenAlertEnabled }
        set { self.setDefault(\.quotaWarningOnScreenAlertEnabled, newValue, key: "quotaWarningOnScreenAlertEnabled") }
    }

    var quotaWarningMarkersVisible: Bool {
        get { self.defaultsState.quotaWarningMarkersVisible }
        set { self.setDefault(\.quotaWarningMarkersVisible, newValue, key: "quotaWarningMarkersVisible") }
    }

    var paceVisible: Bool {
        get { self.defaultsState.paceVisible }
        set { self.setDefault(\.paceVisible, newValue, key: "paceVisible") }
    }

    var weeklyProgressWorkDays: Int? {
        get { self.defaultsState.weeklyProgressWorkDays }
        set { self.setOptionalDefault(\.weeklyProgressWorkDays, newValue, key: "weeklyProgressWorkDays") }
    }

    var workdayTickAppearance: WorkdayTickAppearance {
        get { WorkdayTickAppearance(rawValue: self.defaultsState.workdayTickAppearanceRaw) ?? .subtle }
        set { self.setDefault(\.workdayTickAppearanceRaw, newValue.rawValue, key: "workdayTickAppearance") }
    }

    var usageBarsShowUsed: Bool {
        get { self.defaultsState.usageBarsShowUsed }
        set { self.setDefault(\.usageBarsShowUsed, newValue, key: "usageBarsShowUsed") }
    }

    var resetTimesShowAbsolute: Bool {
        get { self.defaultsState.resetTimesShowAbsolute }
        set { self.setDefault(\.resetTimesShowAbsolute, newValue, key: "resetTimesShowAbsolute") }
    }

    var providerChangelogLinksEnabled: Bool {
        get { self.defaultsState.providerChangelogLinksEnabled }
        set { self.setDefault(\.providerChangelogLinksEnabled, newValue, key: "providerChangelogLinksEnabled") }
    }

    var menuBarShowsBrandIconWithPercent: Bool {
        get { self.defaultsState.menuBarShowsBrandIconWithPercent }
        set { self.setDefault(\.menuBarShowsBrandIconWithPercent, newValue, key: "menuBarShowsBrandIconWithPercent") }
    }

    var menuBarHidesCritters: Bool {
        get { self.defaultsState.menuBarHidesCritters }
        set { self.setDefault(\.menuBarHidesCritters, newValue, key: "menuBarHidesCritters") }
    }

    var menuBarColorPace: Bool {
        get { self.defaultsState.menuBarColorPace }
        set { self.setDefault(\.menuBarColorPace, newValue, key: "menuBarColorPace") }
    }

    var menuBarHighContrastOnInactiveDisplays: Bool {
        get { self.defaultsState.menuBarHighContrastOnInactiveDisplays }
        set { self.setDefault(
            \.menuBarHighContrastOnInactiveDisplays,
            newValue,
            key: "menuBarHighContrastOnInactiveDisplays") }
    }

    var menuBarDisplayMode: MenuBarDisplayMode {
        get { MenuBarDisplayMode(rawValue: self.defaultsState.menuBarDisplayModeRaw ?? "") ?? .percent }
        set { self.setOptionalDefault(\.menuBarDisplayModeRaw, newValue.rawValue, key: "menuBarDisplayMode") }
    }

    var menuBarShowsResetTimeWhenExhausted: Bool {
        get { self.defaultsState.menuBarShowsResetTimeWhenExhausted }
        set {
            self.setDefault(\.menuBarShowsResetTimeWhenExhausted, newValue, key: "menuBarShowsResetTimeWhenExhausted")
        }
    }

    var kiroMenuBarDisplayMode: KiroMenuBarDisplayMode {
        get { KiroMenuBarDisplayMode(rawValue: self.defaultsState.kiroMenuBarDisplayModeRaw ?? "") ?? .automatic }
        set { self.setOptionalDefault(\.kiroMenuBarDisplayModeRaw, newValue.rawValue, key: "kiroMenuBarDisplayMode") }
    }

    var accountWidgetsEnabled: Bool {
        get { self.defaultsState.accountWidgetsEnabled }
        set { self.setDefault(\.accountWidgetsEnabled, newValue, key: "accountWidgetsEnabled") }
    }

    var multiAccountMenuLayout: MultiAccountMenuLayout {
        get { MultiAccountMenuLayout(rawValue: self.defaultsState.multiAccountMenuLayoutRaw) ?? .segmented }
        set {
            self.setDefault(\.multiAccountMenuLayoutRaw, newValue.rawValue, key: "multiAccountMenuLayout")
            self.noteBackgroundWorkSettingsChanged()
        }
    }

    var showAllTokenAccountsInMenu: Bool {
        get { self.multiAccountMenuLayout == .stacked }
        set { self.multiAccountMenuLayout = newValue ? .stacked : .segmented }
    }

    var historicalTrackingEnabled: Bool {
        get { self.defaultsState.historicalTrackingEnabled }
        set {
            self.setDefault(\.historicalTrackingEnabled, newValue, key: "historicalTrackingEnabled")
            self.noteBackgroundWorkSettingsChanged()
        }
    }

    var menuBarMetricPreferencesRaw: [String: String] {
        get { self.defaultsState.menuBarMetricPreferencesRaw }
        set { self.setDefault(\.menuBarMetricPreferencesRaw, newValue, key: "menuBarMetricPreferences") }
    }

    var menuBarLayout: MenuBarLayout {
        get {
            self.defaultsState.storedMenuBarLayout ?? MenuBarLayout.migrated(
                displayMode: self.menuBarDisplayMode,
                metricPreference: .automatic,
                resetTimeDisplayStyle: self.resetTimeDisplayStyle)
        }
        set {
            self.defaultsState.storedMenuBarLayout = newValue
            self.persistMenuBarLayout(newValue)
        }
    }

    var menuBarLayoutConditionals: [MenuBarLayoutConditional] {
        get { self.defaultsState.menuBarLayoutConditionals }
        set {
            self.defaultsState.menuBarLayoutConditionals = newValue
            self.persistMenuBarLayoutConditionals()
        }
    }

    func removeMenuBarLayoutConditional(id: UUID) {
        self.menuBarLayoutConditionals.removeAll { $0.id == id }
        if let stored = self.defaultsState.storedMenuBarLayout,
           let stripped = stored.removingConditional(id: id)
        {
            self.menuBarLayout = stripped
        }
        for (key, layout) in self.defaultsState.menuBarLayoutOverridesRaw {
            guard let stripped = layout.removingConditional(id: id) else { continue }
            self.defaultsState.menuBarLayoutOverridesRaw[key] = stripped
        }
        self.persistMenuBarLayoutOverrides()
    }

    var hasStoredMenuBarLayout: Bool {
        self.defaultsState.storedMenuBarLayout != nil
    }

    var menuBarLayoutOverrides: [UsageProvider: MenuBarLayout] {
        Dictionary(uniqueKeysWithValues: self.defaultsState.menuBarLayoutOverridesRaw.compactMap { key, value in
            UsageProvider(rawValue: key).map { ($0, value) }
        })
    }

    func menuBarLayout(for provider: UsageProvider) -> MenuBarLayout {
        self.menuBarLayoutResolution(for: provider).layout
    }

    func menuBarLayoutForGlobalEditing(representativeProvider: UsageProvider?) -> MenuBarLayout {
        if let stored = self.defaultsState.storedMenuBarLayout {
            return stored
        }
        guard let representativeProvider else { return self.menuBarLayout }
        return self.menuBarLayoutResolution(for: representativeProvider).layout
    }

    func menuBarLayoutResolution(for provider: UsageProvider) -> MenuBarLayoutResolution {
        if let override = self.defaultsState.menuBarLayoutOverridesRaw[provider.rawValue] {
            return .stored(override)
        }
        if let stored = self.defaultsState.storedMenuBarLayout {
            return .stored(stored)
        }
        return .legacy(
            displayMode: self.menuBarDisplayMode,
            metricPreference: self.menuBarMetricPreference(for: provider),
            resetTimeDisplayStyle: self.resetTimeDisplayStyle,
            provider: provider)
    }

    func setMenuBarLayout(_ layout: MenuBarLayout, for provider: UsageProvider?) {
        if let provider {
            self.defaultsState.menuBarLayoutOverridesRaw[provider.rawValue] = layout
            self.persistMenuBarLayoutOverrides()
        } else {
            self.menuBarLayout = layout
        }
    }

    func removeMenuBarLayoutOverride(for provider: UsageProvider) {
        guard self.defaultsState.menuBarLayoutOverridesRaw.removeValue(forKey: provider.rawValue) != nil else { return }
        self.persistMenuBarLayoutOverrides()
    }

    var menuBarLayoutSize: MenuBarLayoutSize {
        get { MenuBarLayoutSize(rawValue: self.defaultsState.menuBarLayoutSizeRaw) ?? .regular }
        set { self.setDefault(\.menuBarLayoutSizeRaw, newValue.rawValue, key: "menuBarLayoutSize") }
    }

    var menuBarLayoutGap: MenuBarLayoutGap {
        get { MenuBarLayoutGap(rawValue: self.defaultsState.menuBarLayoutGapRaw) ?? .regular }
        set { self.setDefault(\.menuBarLayoutGapRaw, newValue.rawValue, key: "menuBarLayoutGap") }
    }

    /// User-tunable vertical nudge for the menu bar title, clamped to -20...20.
    /// Positive moves content up, negative moves it down; 0 keeps the optical default.
    var menuBarLayoutVerticalAdjustment: Int {
        get { self.defaultsState.menuBarLayoutVerticalAdjustment }
        set {
            let clamped = max(-20, min(20, newValue))
            self.setDefault(\.menuBarLayoutVerticalAdjustment, clamped, key: "menuBarLayoutVerticalAdjustment")
        }
    }

    private func persistMenuBarLayout(_ layout: MenuBarLayout) {
        guard let blobs = try? MenuBarLayoutPersistence.encoded(layout) else { return }
        self.userDefaults.set(blobs.current, forKey: MenuBarLayoutUserDefaultsKey.layoutCurrent)
        self.userDefaults.set(blobs.v3, forKey: MenuBarLayoutUserDefaultsKey.layoutV3)
        self.userDefaults.set(blobs.released, forKey: MenuBarLayoutUserDefaultsKey.layoutReleased)
        self.userDefaults.set(blobs.legacy, forKey: MenuBarLayoutUserDefaultsKey.layout)
    }

    private func persistMenuBarLayoutConditionals() {
        guard let blobs = try? MenuBarLayoutPersistence
            .encodedLibrary(self.defaultsState.menuBarLayoutConditionals)
        else { return }
        self.userDefaults.set(blobs.current, forKey: MenuBarLayoutUserDefaultsKey.conditionalsCurrent)
        self.userDefaults.set(blobs.v3, forKey: MenuBarLayoutUserDefaultsKey.conditionalsV3)
        self.userDefaults.set(blobs.released, forKey: MenuBarLayoutUserDefaultsKey.conditionalsReleased)
        self.userDefaults.set(blobs.legacy, forKey: MenuBarLayoutUserDefaultsKey.conditionals)
    }

    private func persistMenuBarLayoutOverrides() {
        guard let blobs = try? MenuBarLayoutPersistence.encodedOverrides(self.defaultsState.menuBarLayoutOverridesRaw)
        else { return }
        self.userDefaults.set(blobs.current, forKey: MenuBarLayoutUserDefaultsKey.overridesCurrent)
        self.userDefaults.set(blobs.v3, forKey: MenuBarLayoutUserDefaultsKey.overridesV3)
        self.userDefaults.set(blobs.released, forKey: MenuBarLayoutUserDefaultsKey.overridesReleased)
        self.userDefaults.set(blobs.legacy, forKey: MenuBarLayoutUserDefaultsKey.overrides)
    }

    var copilotIconSecondaryWindowIDRaw: String {
        get { self.defaultsState.copilotIconSecondaryWindowIDRaw }
        set { self.setDefault(\.copilotIconSecondaryWindowIDRaw, newValue, key: "copilotIconSecondaryWindowID") }
    }

    var costUsageEnabled: Bool {
        get { self.defaultsState.costUsageEnabled }
        set {
            self.setCostDefault(\.costUsageEnabled, newValue, key: "tokenCostUsageEnabled")
            if newValue {
                self.pinCostUsageBucketTimeZoneIfNeeded()
            }
            self.noteBackgroundWorkSettingsChanged()
        }
    }

    var codexLocalSessionCostLedgerEnabled: Bool {
        get { self.defaultsState.codexLocalSessionCostLedgerEnabled }
        set {
            self.setDefault(\.codexLocalSessionCostLedgerEnabled, newValue, key: "codexLocalSessionCostLedgerEnabled")
            self.noteBackgroundWorkSettingsChanged()
        }
    }

    var costUsageHistoryDays: Int {
        get { self.costReportingPeriod.days(now: Date(), calendar: self.costUsageBucketCalendar) }
        set { self.costReportingPeriod = .rolling(days: max(1, min(365, newValue))) }
    }

    var costReportingPeriod: CostReportingPeriod {
        get { self.defaultsState.costReportingPeriod }
        set {
            guard self.defaultsState.costReportingPeriod != newValue else { return }
            self.defaultsState.costReportingPeriod = newValue
            self.userDefaults.set(newValue.rawValue, forKey: CostReportingPeriod.defaultsKey)
            self.costUsageSettingsRevision &+= 1
            self.noteBackgroundWorkSettingsChanged()
        }
    }

    var costUsageBucketTimeZoneIdentifier: String {
        get { self.defaultsState.costUsageBucketTimeZoneIdentifier }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = CostUsageBucketTimeZone.isValidIdentifier(trimmed) ? trimmed : ""
            self.setCostDefault(\.costUsageBucketTimeZoneIdentifier, normalized, key: "tokenCostUsageBucketTimeZone")
        }
    }

    var costUsageBucketCalendar: Calendar {
        CostUsageBucketTimeZone.calendar(identifier: self.costUsageBucketTimeZoneIdentifier)
    }

    var openCodexUsageLogsEnabled: Bool {
        get { self.defaultsState.openCodexUsageLogsEnabled }
        set {
            self.setCostDefault(\.openCodexUsageLogsEnabled, newValue, key: "openCodexUsageLogsEnabled")
        }
    }

    var hideNativeCodexCostWhenOpenCodexPresent: Bool {
        get { self.defaultsState.hideNativeCodexCostWhenOpenCodexPresent }
        set {
            self.setCostDefault(
                \.hideNativeCodexCostWhenOpenCodexPresent,
                newValue,
                key: "hideNativeCodexCostWhenOpenCodexPresent")
        }
    }

    var spendDashboardHiddenSourceIDs: [String] {
        get { self.defaultsState.spendDashboardHiddenSourceIDs }
        set {
            let normalized = Array(Set(newValue.filter { !$0.isEmpty })).sorted()
            self.setCostDefault(\.spendDashboardHiddenSourceIDs, normalized, key: "spendDashboardHiddenSourceIDs")
        }
    }

    func pinCostUsageBucketTimeZoneIfNeeded() {
        guard self.costUsageBucketTimeZoneIdentifier.isEmpty else { return }
        self.costUsageBucketTimeZoneIdentifier = CostUsageBucketTimeZone.pinIdentifier()
    }

    var costComparisonPeriodsEnabled: Bool {
        get { self.defaultsState.costComparisonPeriodsEnabled }
        set { self.setDefault(\.costComparisonPeriodsEnabled, newValue, key: "costComparisonPeriodsEnabled") }
    }

    var costSummaryDisplayStyleRaw: String {
        get { self.defaultsState.costSummaryDisplayStyleRaw }
        set { self.setDefault(\.costSummaryDisplayStyleRaw, newValue, key: "costSummaryDisplayStyle") }
    }

    var costSummaryDisplayStyle: CostSummaryDisplayStyle {
        get { CostSummaryDisplayStyle(rawValue: self.costSummaryDisplayStyleRaw) ?? .both }
        set { self.costSummaryDisplayStyleRaw = newValue.rawValue }
    }

    var hidePersonalInfo: Bool {
        get { self.defaultsState.hidePersonalInfo }
        set { self.setDefault(\.hidePersonalInfo, newValue, key: "hidePersonalInfo") }
    }

    var randomBlinkEnabled: Bool {
        get { self.defaultsState.randomBlinkEnabled }
        set { self.setDefault(\.randomBlinkEnabled, newValue, key: "randomBlinkEnabled") }
    }

    var confettiOnSessionLimitResetsEnabled: Bool {
        get { self.defaultsState.confettiOnSessionLimitResetsEnabled }
        set { self.setDefault(
            \.confettiOnSessionLimitResetsEnabled,
            newValue,
            key: "confettiOnSessionLimitResetsEnabled") }
    }

    var confettiOnWeeklyLimitResetsEnabled: Bool {
        get { self.defaultsState.confettiOnWeeklyLimitResetsEnabled }
        set {
            self.setDefault(\.confettiOnWeeklyLimitResetsEnabled, newValue, key: "confettiOnWeeklyLimitResetsEnabled")
        }
    }

    var menuBarShowsHighestUsage: Bool {
        get { self.defaultsState.menuBarShowsHighestUsage }
        set { self.setDefault(\.menuBarShowsHighestUsage, newValue, key: "menuBarShowsHighestUsage") }
    }

    var claudeOAuthKeychainPromptMode: ClaudeOAuthKeychainPromptMode {
        get {
            let raw = self.defaultsState.claudeOAuthKeychainPromptModeRaw
            return ClaudeOAuthKeychainPromptMode(rawValue: raw ?? "") ?? .onlyOnUserAction
        }
        set {
            self.setOptionalDefault(
                \.claudeOAuthKeychainPromptModeRaw,
                newValue.rawValue,
                key: "claudeOAuthKeychainPromptMode")
            self.noteBackgroundWorkSettingsChanged()
        }
    }

    var claudeOAuthKeychainReadStrategy: ClaudeOAuthKeychainReadStrategy {
        get {
            guard let raw = self.defaultsState.claudeOAuthKeychainReadStrategyRaw else {
                return .securityFramework
            }
            let strategy = ClaudeOAuthKeychainReadStrategy(rawValue: raw) ?? .securityFramework
            return strategy == .securityCLIExperimental ? .securityFramework : strategy
        }
        set {
            self.setOptionalDefault(
                \.claudeOAuthKeychainReadStrategyRaw,
                newValue.rawValue,
                key: "claudeOAuthKeychainReadStrategy")
            self.noteBackgroundWorkSettingsChanged()
        }
    }

    /// Explicit opt-in for reading Claude Code's own Keychain item (#2634). Feeds
    /// `ClaudeOAuthDirectKeychainReadConsent`, the single consent source behind
    /// `ClaudeOAuthCredentialsStore.keychainAccessAllowed`.
    var claudeOAuthDirectKeychainReadAllowed: Bool {
        get { self.defaultsState.claudeOAuthDirectKeychainReadAllowed }
        set {
            let wasAllowed = self.defaultsState.claudeOAuthDirectKeychainReadAllowed
            self.setDefault(
                \.claudeOAuthDirectKeychainReadAllowed,
                newValue,
                key: ClaudeOAuthDirectKeychainReadConsent.userDefaultsKey)
            CodexBarLog.logger(LogCategories.settings).info(
                "Claude direct Keychain read consent updated",
                metadata: ["allowed": newValue ? "1" : "0"])
            if wasAllowed, !newValue {
                // Revoking consent must also revoke what consent obtained: credentials copied from Claude
                // Code's Keychain while consent was on live in CodexBar's memory and Keychain caches, and
                // those caches are consulted before the direct-read gate. Advance the global revocation epoch
                // before dropping the active cache so previously used profile caches also fail closed on lookup
                // (CodexBar-owned state only — Claude Code's item is untouched).
                ClaudeOAuthCredentialsStore.revokeDirectKeychainReadConsent()
            }
            self.noteBackgroundWorkSettingsChanged()
        }
    }

    var claudeOAuthPromptFreeCredentialsEnabled: Bool {
        get { self.claudeOAuthKeychainPromptMode == .never }
        set {
            self.claudeOAuthKeychainReadStrategy = .securityFramework
            if newValue {
                self.claudeOAuthKeychainPromptMode = .never
            } else if self.claudeOAuthKeychainPromptMode == .never {
                self.claudeOAuthKeychainPromptMode = .onlyOnUserAction
            }
        }
    }

    var copilotBudgetExtrasEnabled: Bool {
        get { self.defaultsState.copilotBudgetExtrasEnabled }
        set {
            self.setDefault(\.copilotBudgetExtrasEnabled, newValue, key: "copilotBudgetExtrasEnabled")
            CodexBarLog.logger(LogCategories.settings).info(
                "Copilot budget extras updated",
                metadata: ["enabled": newValue ? "1" : "0"])
            self.noteBackgroundWorkSettingsChanged()
        }
    }

    var copilotSeatCreditEntitlementRaw: String {
        get { self.defaultsState.copilotSeatCreditEntitlementRaw }
        set {
            self.setDefault(\.copilotSeatCreditEntitlementRaw, newValue, key: "copilotSeatCreditEntitlement")
            self.noteBackgroundWorkSettingsChanged()
        }
    }

    var claudeWebExtrasEnabled: Bool {
        get { self.defaultsState.claudeWebExtrasEnabledRaw }
        set {
            self.setDefault(\.claudeWebExtrasEnabledRaw, newValue, key: "claudeWebExtrasEnabled")
            CodexBarLog.logger(LogCategories.settings).info(
                "Claude web extras updated",
                metadata: ["enabled": newValue ? "1" : "0"])
            self.noteBackgroundWorkSettingsChanged()
        }
    }

    var showOptionalCreditsAndExtraUsage: Bool {
        get { self.defaultsState.showOptionalCreditsAndExtraUsage }
        set {
            self.setDefault(\.showOptionalCreditsAndExtraUsage, newValue, key: "showOptionalCreditsAndExtraUsage")
            // This flag also controls ProviderFetchContext.includeOptionalUsage, so it is not display-only.
            self.noteBackgroundWorkSettingsChanged()
        }
    }

    var claudeDailyRoutinesUsageVisible: Bool {
        get { self.defaultsState.claudeDailyRoutinesUsageVisible }
        set { self.setDefault(\.claudeDailyRoutinesUsageVisible, newValue, key: "claudeDailyRoutinesUsageVisible") }
    }

    var claudeModelScopedWeeklyUsageVisible: Bool {
        get { self.defaultsState.claudeModelScopedWeeklyUsageVisible }
        set { self.setDefault(
            \.claudeModelScopedWeeklyUsageVisible,
            newValue,
            key: "claudeModelScopedWeeklyUsageVisible") }
    }

    var codexSparkUsageVisible: Bool {
        get { self.defaultsState.codexSparkUsageVisible }
        set { self.setDefault(\.codexSparkUsageVisible, newValue, key: "codexSparkUsageVisible") }
    }

    var codexExternalOAuthSourcesAllowed: Bool {
        get { self.defaultsState.codexExternalOAuthSourcesAllowed }
        set {
            self.setDefault(\.codexExternalOAuthSourcesAllowed, newValue, key: "codexExternalOAuthSourcesAllowed")
            self.noteBackgroundWorkSettingsChanged()
        }
    }

    var openAIWebAccessEnabled: Bool {
        get { self.defaultsState.openAIWebAccessEnabled }
        set {
            self.setDefault(\.openAIWebAccessEnabled, newValue, key: "openAIWebAccessEnabled")
            CodexBarLog.logger(LogCategories.settings).info(
                "OpenAI web access updated",
                metadata: ["enabled": newValue ? "1" : "0"])
            self.noteBackgroundWorkSettingsChanged()
        }
    }

    var openAIWebBatterySaverEnabled: Bool {
        get { self.defaultsState.openAIWebBatterySaverEnabled }
        set {
            self.setDefault(\.openAIWebBatterySaverEnabled, newValue, key: "openAIWebBatterySaverEnabled")
            CodexBarLog.logger(LogCategories.settings).info(
                "OpenAI web battery saver updated",
                metadata: ["enabled": newValue ? "1" : "0"])
            self.noteBackgroundWorkSettingsChanged()
        }
    }

    var backgroundWorkLowPowerModePreference: LowPowerModePreference {
        get { self.defaultsState.backgroundWorkLowPowerModePreference }
        set {
            self.defaultsState.backgroundWorkLowPowerModePreference = newValue
            self.userDefaults.set(newValue.rawValue, forKey: "backgroundWorkLowPowerModePreference")
            CodexBarLog.logger(LogCategories.settings).info(
                "Background work low power mode preference updated",
                metadata: ["preference": newValue.rawValue])
            self.noteBackgroundWorkSettingsChanged()
        }
    }

    /// Resolves `backgroundWorkLowPowerModePreference` against the live system Low Power Mode state
    /// when the preference is `.automatic`.
    var backgroundWorkLowPowerModeEnabled: Bool {
        switch self.backgroundWorkLowPowerModePreference {
        case .off: false
        case .on: true
        case .automatic: ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    }

    var effectiveOpenAIWebBatterySaverEnabled: Bool {
        self.openAIWebBatterySaverEnabled || self.backgroundWorkLowPowerModeEnabled
    }

    var providerStorageFootprintsEnabled: Bool {
        get { self.defaultsState.providerStorageFootprintsEnabled }
        set {
            self.setDefault(\.providerStorageFootprintsEnabled, newValue, key: "providerStorageFootprintsEnabled")
            CodexBarLog.logger(LogCategories.settings).info(
                "Provider storage footprints updated",
                metadata: ["enabled": newValue ? "1" : "0"])
            self.noteBackgroundWorkSettingsChanged()
        }
    }

    var jetbrainsIDEBasePath: String {
        get { self.defaultsState.jetbrainsIDEBasePath }
        set { self.setDefault(\.jetbrainsIDEBasePath, newValue, key: "jetbrainsIDEBasePath") }
    }

    var mergeIcons: Bool {
        get { self.defaultsState.mergeIcons }
        set { self.setDefault(\.mergeIcons, newValue, key: "mergeIcons") }
    }

    var mergedOverviewLayout: MergedOverviewLayout {
        get { MergedOverviewLayout(rawValue: self.defaultsState.mergedOverviewLayoutRaw) ?? .detailed }
        set { self.setDefault(\.mergedOverviewLayoutRaw, newValue.rawValue, key: "mergedOverviewLayout") }
    }

    var switcherShowsIcons: Bool {
        get { self.defaultsState.switcherShowsIcons }
        set { self.setDefault(\.switcherShowsIcons, newValue, key: "switcherShowsIcons") }
    }

    var mergeIconsStacked: Bool {
        get { self.defaultsState.mergeIconsStacked }
        set { self.setDefault(\.mergeIconsStacked, newValue, key: "mergeIconsStacked") }
    }

    var mergeIconStackedTopProviderRaw: String? {
        get { self.defaultsState.mergeIconStackedTopProviderRaw }
        set { self.setOptionalDefault(\.mergeIconStackedTopProviderRaw, newValue, key: "mergeIconStackedTopProvider") }
    }

    var mergeIconStackedBottomProviderRaw: String? {
        get { self.defaultsState.mergeIconStackedBottomProviderRaw }
        set { self.setOptionalDefault(
            \.mergeIconStackedBottomProviderRaw,
            newValue,
            key: "mergeIconStackedBottomProvider") }
    }

    var mergedMenuLastSelectedWasOverview: Bool {
        get { self.mergedMenuLastSelectedWasOverviewStorage }
        set {
            self.mergedMenuLastSelectedWasOverviewStorage = newValue
            self.userDefaults.set(newValue, forKey: "mergedMenuLastSelectedWasOverview")
        }
    }

    private var mergedOverviewSelectedProvidersRaw: [String] {
        get { self.defaultsState.mergedOverviewSelectedProvidersRaw }
        set { self.setDefault(\.mergedOverviewSelectedProvidersRaw, newValue, key: "mergedOverviewSelectedProviders") }
    }

    private var selectedMenuProviderRaw: String? {
        get { self.selectedMenuProviderRawStorage }
        set {
            self.selectedMenuProviderRawStorage = newValue
            if let raw = newValue {
                self.userDefaults.set(raw, forKey: "selectedMenuProvider")
            } else {
                self.userDefaults.removeObject(forKey: "selectedMenuProvider")
            }
        }
    }

    var selectedMenuProvider: ProviderInstanceID? {
        get { self.selectedMenuProviderRaw.flatMap(ProviderInstanceID.init(rawValue:)) }
        set {
            self.selectedMenuProviderRaw = newValue?.rawValue
        }
    }

    var mergedOverviewSelectedProviders: [UsageProvider] {
        get {
            Self.normalizeProviders(
                self.mergedOverviewSelectedProvidersRaw.compactMap(UsageProvider.init(rawValue:)),
                maxCount: Self.mergedOverviewProviderLimit)
        }
        set {
            let normalized = Self.normalizeProviders(newValue, maxCount: Self.mergedOverviewProviderLimit)
            self.mergedOverviewSelectedProvidersRaw = normalized.map(\.rawValue)
        }
    }

    private var hasMergedOverviewSelectionPreference: Bool {
        self.userDefaults.object(forKey: "mergedOverviewSelectedProviders") != nil
    }

    private var mergedOverviewSelectionEditedActiveProvidersRaw: [String]? {
        get {
            self.userDefaults.array(forKey: Self.mergedOverviewSelectionEditedActiveProvidersKey) as? [String]
        }
        set {
            if let newValue {
                self.userDefaults.set(newValue, forKey: Self.mergedOverviewSelectionEditedActiveProvidersKey)
            } else {
                self.userDefaults.removeObject(forKey: Self.mergedOverviewSelectionEditedActiveProvidersKey)
            }
        }
    }

    private func mergedOverviewSelectionApplies(to activeProviders: [UsageProvider]) -> Bool {
        guard let editedRaw = self.mergedOverviewSelectionEditedActiveProvidersRaw else { return false }
        let editedSet = Set(editedRaw)
        let activeSet = Set(Self.normalizeProviders(activeProviders).map(\.rawValue))
        return editedSet == activeSet
    }

    private func markMergedOverviewSelectionEdited(for activeProviders: [UsageProvider]) {
        let signature = Set(Self.normalizeProviders(activeProviders).map(\.rawValue))
        self.mergedOverviewSelectionEditedActiveProvidersRaw = Array(signature).sorted()
    }

    private func clearMergedOverviewSelectionPreference() {
        self.defaultsState.mergedOverviewSelectedProvidersRaw = []
        self.userDefaults.removeObject(forKey: "mergedOverviewSelectedProviders")
        self.mergedOverviewSelectionEditedActiveProvidersRaw = nil
    }

    func resolvedMergedOverviewProviders(
        activeProviders: [UsageProvider],
        maxVisibleProviders: Int = SettingsStore.mergedOverviewProviderLimit) -> [UsageProvider]
    {
        guard maxVisibleProviders > 0 else { return [] }
        let normalizedActive = Self.normalizeProviders(activeProviders)
        guard self.hasMergedOverviewSelectionPreference else {
            return Array(normalizedActive.prefix(maxVisibleProviders))
        }
        if normalizedActive.count <= maxVisibleProviders,
           !self.mergedOverviewSelectionApplies(to: normalizedActive)
        {
            return normalizedActive
        }

        let selectedSet = Set(self.mergedOverviewSelectedProviders)
        return Array(normalizedActive.filter { selectedSet.contains($0) }.prefix(maxVisibleProviders))
    }

    @discardableResult
    func reconcileMergedOverviewSelectedProviders(
        activeProviders: [UsageProvider],
        maxVisibleProviders: Int = SettingsStore.mergedOverviewProviderLimit) -> [UsageProvider]
    {
        guard maxVisibleProviders > 0 else {
            self.clearMergedOverviewSelectionPreference()
            return []
        }

        let normalizedActive = Self.normalizeProviders(activeProviders)
        if normalizedActive.isEmpty {
            self.clearMergedOverviewSelectionPreference()
            return []
        }

        let shouldPersistResolvedSelection = normalizedActive.count > maxVisibleProviders ||
            self.mergedOverviewSelectionApplies(to: normalizedActive)

        if self.hasMergedOverviewSelectionPreference, shouldPersistResolvedSelection {
            let selectedSet = Set(self.mergedOverviewSelectedProviders)
            let sanitizedSelection = Array(
                normalizedActive
                    .filter { selectedSet.contains($0) }
                    .prefix(maxVisibleProviders))
            if sanitizedSelection != self.mergedOverviewSelectedProviders {
                self.mergedOverviewSelectedProviders = sanitizedSelection
            }
        }

        return self.resolvedMergedOverviewProviders(
            activeProviders: normalizedActive,
            maxVisibleProviders: maxVisibleProviders)
    }

    @discardableResult
    func setMergedOverviewProviderSelection(
        provider: UsageProvider,
        isSelected: Bool,
        activeProviders: [UsageProvider],
        maxVisibleProviders: Int = SettingsStore.mergedOverviewProviderLimit) -> [UsageProvider]
    {
        guard maxVisibleProviders > 0 else {
            self.clearMergedOverviewSelectionPreference()
            return []
        }

        let normalizedActive = Self.normalizeProviders(activeProviders)
        guard normalizedActive.contains(provider) else {
            return self.resolvedMergedOverviewProviders(
                activeProviders: normalizedActive,
                maxVisibleProviders: maxVisibleProviders)
        }

        let currentSelection = self.resolvedMergedOverviewProviders(
            activeProviders: normalizedActive,
            maxVisibleProviders: maxVisibleProviders)
        var updatedSet = Set(currentSelection)

        if isSelected {
            guard updatedSet.contains(provider) || currentSelection.count < maxVisibleProviders else {
                return currentSelection
            }
            updatedSet.insert(provider)
        } else {
            updatedSet.remove(provider)
        }

        let updatedSelection = Array(
            normalizedActive
                .filter { updatedSet.contains($0) }
                .prefix(maxVisibleProviders))
        self.mergedOverviewSelectedProviders = updatedSelection
        self.markMergedOverviewSelectionEdited(for: normalizedActive)
        return updatedSelection
    }

    var providerDetectionCompleted: Bool {
        get { self.defaultsState.providerDetectionCompleted }
        set { self.setDefault(\.providerDetectionCompleted, newValue, key: "providerDetectionCompleted") }
    }

    /// Whether the Providers settings pane displays providers sorted alphabetically (enabled on
    /// top). Defaults to `false`. Purely a display preference — it never rewrites the stored manual
    /// order, so turning it on sorts the display without losing the user's hand-arranged sequence.
    var providersSortedAlphabetically: Bool {
        get { self.defaultsState.providersSortedAlphabetically }
        set { self.setDefault(\.providersSortedAlphabetically, newValue, key: "providersSortedAlphabetically") }
    }

    var appLanguage: String {
        get { self.defaultsState.appLanguageRaw ?? "" }
        set {
            let stored = newValue.isEmpty ? nil : newValue
            self.defaultsState.appLanguageRaw = stored
            if let stored {
                self.userDefaults.set(stored, forKey: "appLanguage")
                if self.userDefaults !== UserDefaults.standard {
                    UserDefaults.standard.set(stored, forKey: "appLanguage")
                }
                UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            } else {
                self.userDefaults.removeObject(forKey: "appLanguage")
                if self.userDefaults !== UserDefaults.standard {
                    UserDefaults.standard.removeObject(forKey: "appLanguage")
                }
                UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            }
            resetCodexBarLocalizationCache()
        }
    }

    var debugLoadingPattern: LoadingPattern? {
        get { self.defaultsState.debugLoadingPatternRaw.flatMap(LoadingPattern.init(rawValue:)) }
        set { self.setOptionalDefault(\.debugLoadingPatternRaw, newValue?.rawValue, key: "debugLoadingPattern") }
    }

    var terminalApp: TerminalApp {
        get { TerminalApp(rawValue: self.defaultsState.terminalAppRaw ?? "") ?? .terminal }
        set { self.setOptionalDefault(\.terminalAppRaw, newValue.rawValue, key: "terminalApp") }
    }

    var agentSessionsEnabled: Bool {
        get { self.defaultsState.agentSessionsEnabled }
        set { self.setDefault(\.agentSessionsEnabled, newValue, key: "agentSessionsEnabled") }
    }

    var agentSessionLabelStyle: AgentSessionLabelStyle {
        get { AgentSessionLabelStyle(rawValue: self.defaultsState.agentSessionLabelStyleRaw) ?? .project }
        set { self.setDefault(\.agentSessionLabelStyleRaw, newValue.rawValue, key: "agentSessionLabelStyle") }
    }

    var agentSessionsManualHosts: String {
        get { self.defaultsState.agentSessionsManualHosts }
        set { self.setDefault(\.agentSessionsManualHosts, newValue, key: "agentSessionsManualHosts") }
    }

    var agentSessionsHideUnreachableHosts: Bool {
        get { self.defaultsState.agentSessionsHideUnreachableHosts }
        set { self.setDefault(\.agentSessionsHideUnreachableHosts, newValue, key: "agentSessionsHideUnreachableHosts") }
    }

    var preferredCurrencyCode: String {
        get { self.defaultsState.preferredCurrencyCode }
        set { self.setDefault(\.preferredCurrencyCode, newValue, key: "preferredCurrencyCode") }
    }
}

extension SettingsStore {
    private static func normalizeProviders(_ providers: [UsageProvider], maxCount: Int? = nil) -> [UsageProvider] {
        var seen: Set<UsageProvider> = []
        var normalized: [UsageProvider] = []
        for provider in providers where !seen.contains(provider) {
            seen.insert(provider)
            normalized.append(provider)
            if let maxCount, normalized.count >= maxCount {
                break
            }
        }
        return normalized
    }
}
