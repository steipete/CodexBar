import CodexBarCore
import Foundation

extension SettingsStore {
    var iCloudSyncEnabled: Bool {
        get { self.defaultsState.iCloudSyncEnabled }
        set {
            self.defaultsState.iCloudSyncEnabled = newValue
            self.userDefaults.set(newValue, forKey: "iCloudSyncEnabled")
        }
    }

    var iCloudSyncIncludeSecrets: Bool {
        get { self.defaultsState.iCloudSyncIncludeSecrets }
        set {
            self.defaultsState.iCloudSyncIncludeSecrets = newValue
            self.userDefaults.set(newValue, forKey: "iCloudSyncIncludeSecrets")
        }
    }

    var iCloudSyncSnapshotsEnabled: Bool {
        get { self.defaultsState.iCloudSyncSnapshotsEnabled }
        set {
            self.defaultsState.iCloudSyncSnapshotsEnabled = newValue
            self.userDefaults.set(newValue, forKey: "iCloudSyncSnapshotsEnabled")
        }
    }

    var iCloudSyncShowFleetAccounts: Bool {
        get { self.defaultsState.iCloudSyncShowFleetAccounts }
        set {
            self.defaultsState.iCloudSyncShowFleetAccounts = newValue
            self.userDefaults.set(newValue, forKey: "iCloudSyncShowFleetAccounts")
        }
    }

    var iCloudSyncDeviceID: String {
        get { self.defaultsState.iCloudSyncDeviceID }
        set {
            self.defaultsState.iCloudSyncDeviceID = newValue
            self.userDefaults.set(newValue, forKey: "iCloudSyncDeviceID")
        }
    }

    var syncedPreferences: SyncedPreferences {
        SyncedPreferences(
            statusChecksEnabled: self.statusChecksEnabled,
            sessionQuotaNotificationsEnabled: self.sessionQuotaNotificationsEnabled,
            quotaWarningNotificationsEnabled: self.quotaWarningNotificationsEnabled,
            predictivePaceWarningNotificationsEnabled: self.predictivePaceWarningNotificationsEnabled,
            quotaWarningThresholds: self.quotaWarningThresholds,
            quotaWarningSessionThresholds: self.quotaWarningThresholds(.session),
            quotaWarningWeeklyThresholds: self.quotaWarningThresholds(.weekly),
            quotaWarningSessionEnabled: self.quotaWarningWindowEnabled(.session),
            quotaWarningWeeklyEnabled: self.quotaWarningWindowEnabled(.weekly),
            quotaWarningSoundEnabled: self.quotaWarningSoundEnabled,
            quotaWarningOnScreenAlertEnabled: self.quotaWarningOnScreenAlertEnabled,
            quotaWarningMarkersVisible: self.quotaWarningMarkersVisible,
            weeklyProgressWorkDays: self.weeklyProgressWorkDays,
            workdayTickAppearance: self.workdayTickAppearance.rawValue,
            usageBarsShowUsed: self.usageBarsShowUsed,
            resetTimesShowAbsolute: self.resetTimesShowAbsolute,
            costUsageEnabled: self.costUsageEnabled,
            costComparisonPeriodsEnabled: self.costComparisonPeriodsEnabled,
            costSummaryDisplayStyle: self.costSummaryDisplayStyleRaw,
            hidePersonalInfo: self.hidePersonalInfo,
            randomBlinkEnabled: self.randomBlinkEnabled,
            confettiOnSessionLimitResetsEnabled: self.confettiOnSessionLimitResetsEnabled,
            confettiOnWeeklyLimitResetsEnabled: self.confettiOnWeeklyLimitResetsEnabled,
            menuBarShowsHighestUsage: self.menuBarShowsHighestUsage,
            showOptionalCreditsAndExtraUsage: self.showOptionalCreditsAndExtraUsage,
            providerChangelogLinksEnabled: self.providerChangelogLinksEnabled,
            preferredCurrencyCode: self.preferredCurrencyCode,
            providersSortedAlphabetically: self.providersSortedAlphabetically,
            refreshFrequency: self.refreshFrequency.rawValue,
            refreshAllProvidersOnMenuOpen: self.refreshAllProvidersOnMenuOpen)
    }

    func applySyncedPreferences(_ preferences: SyncedPreferences) {
        self.statusChecksEnabled = preferences.statusChecksEnabled
        self.sessionQuotaNotificationsEnabled = preferences.sessionQuotaNotificationsEnabled
        self.quotaWarningNotificationsEnabled = preferences.quotaWarningNotificationsEnabled
        self.predictivePaceWarningNotificationsEnabled = preferences.predictivePaceWarningNotificationsEnabled
        self.quotaWarningThresholds = preferences.quotaWarningThresholds
        self.setQuotaWarningThresholds(.session, thresholds: preferences.quotaWarningSessionThresholds)
        self.setQuotaWarningThresholds(.weekly, thresholds: preferences.quotaWarningWeeklyThresholds)
        self.setQuotaWarningWindowEnabled(.session, enabled: preferences.quotaWarningSessionEnabled)
        self.setQuotaWarningWindowEnabled(.weekly, enabled: preferences.quotaWarningWeeklyEnabled)
        self.quotaWarningSoundEnabled = preferences.quotaWarningSoundEnabled
        self.quotaWarningOnScreenAlertEnabled = preferences.quotaWarningOnScreenAlertEnabled
        self.quotaWarningMarkersVisible = preferences.quotaWarningMarkersVisible
        self.weeklyProgressWorkDays = preferences.weeklyProgressWorkDays
        if let rawAppearance = preferences.workdayTickAppearance,
           let appearance = WorkdayTickAppearance(rawValue: rawAppearance)
        {
            self.workdayTickAppearance = appearance
        }
        self.usageBarsShowUsed = preferences.usageBarsShowUsed
        self.resetTimesShowAbsolute = preferences.resetTimesShowAbsolute
        self.costUsageEnabled = preferences.costUsageEnabled
        self.costComparisonPeriodsEnabled = preferences.costComparisonPeriodsEnabled
        self.costSummaryDisplayStyleRaw = preferences.costSummaryDisplayStyle
        self.hidePersonalInfo = preferences.hidePersonalInfo
        self.randomBlinkEnabled = preferences.randomBlinkEnabled
        self.confettiOnSessionLimitResetsEnabled = preferences.confettiOnSessionLimitResetsEnabled
        self.confettiOnWeeklyLimitResetsEnabled = preferences.confettiOnWeeklyLimitResetsEnabled
        self.menuBarShowsHighestUsage = preferences.menuBarShowsHighestUsage
        self.showOptionalCreditsAndExtraUsage = preferences.showOptionalCreditsAndExtraUsage
        self.providerChangelogLinksEnabled = preferences.providerChangelogLinksEnabled
        self.preferredCurrencyCode = preferences.preferredCurrencyCode
        self.providersSortedAlphabetically = preferences.providersSortedAlphabetically
        if let refreshFrequency = RefreshFrequency(rawValue: preferences.refreshFrequency) {
            self.refreshFrequency = refreshFrequency
        }
        self.refreshAllProvidersOnMenuOpen = preferences.refreshAllProvidersOnMenuOpen
    }

    func canEnableProviderFromSync(_ provider: UsageProvider, localConfig: ProviderConfig) -> Bool {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: provider)
        let source = localConfig.source ?? .auto
        let nonCLIModes: Set<ProviderSourceMode> = [.web, .oauth, .api]
        let requiresCLI = source == .cli
            || (source == .auto
                && descriptor.fetchPlan.sourceModes.contains(.cli)
                && descriptor.fetchPlan.sourceModes.isDisjoint(with: nonCLIModes))
        guard requiresCLI else { return true }
        if let binaryLocator = descriptor.cli.binaryLocator {
            return binaryLocator() != nil
        }
        return ([descriptor.cli.name] + descriptor.cli.aliases).contains { TTYCommandRunner.which($0) != nil }
    }
}
