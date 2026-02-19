import Foundation

extension SettingsStore {
    var menuObservationToken: Int {
        _ = self.providerOrder
        _ = self.providerEnablement
        _ = self.refreshFrequency
        _ = self.launchAtLogin
        _ = self.debugMenuEnabled
        _ = self.debugDisableKeychainAccess
        _ = self.debugKeepCLISessionsAlive
        _ = self.statusChecksEnabled
        _ = self.sessionQuotaNotificationsEnabled
        _ = self.usageBarsShowUsed
        _ = self.resetTimesShowAbsolute
        _ = self.menuBarShowsBrandIconWithPercent
        _ = self.menuBarShowsHighestUsage
        _ = self.menuBarDisplayMode
        _ = self.showAllTokenAccountsInMenu
        _ = self.menuBarMetricPreferencesRaw
        _ = self.costUsageEnabled
        _ = self.hidePersonalInfo
        _ = self.randomBlinkEnabled
        _ = self.claudeOAuthKeychainPromptMode
        _ = self.claudeOAuthKeychainReadStrategy
        _ = self.claudeWebExtrasEnabled
        _ = self.showOptionalCreditsAndExtraUsage
        _ = self.openAIWebAccessEnabled
        _ = self.codexUsageDataSource
        _ = self.claudeUsageDataSource
        _ = self.codexCookieSource
        _ = self.claudeCookieSource
        _ = self.cursorCookieSource
        _ = self.opencodeCookieSource
        _ = self.factoryCookieSource
        _ = self.minimaxCookieSource
        _ = self.minimaxAPIRegion
        _ = self.kimiCookieSource
        _ = self.augmentCookieSource
        _ = self.ampCookieSource
        _ = self.ollamaCookieSource
        _ = self.mergeIcons
        _ = self.switcherShowsIcons
        _ = self.zaiAPIToken
        _ = self.syntheticAPIToken
        _ = self.codexCookieHeader
        _ = self.claudeCookieHeader
        _ = self.cursorCookieHeader
        _ = self.opencodeCookieHeader
        _ = self.opencodeWorkspaceID
        _ = self.factoryCookieHeader
        _ = self.minimaxCookieHeader
        _ = self.minimaxAPIToken
        _ = self.kimiManualCookieHeader
        _ = self.kimiK2APIToken
        _ = self.augmentCookieHeader
        _ = self.ampCookieHeader
        _ = self.ollamaCookieHeader
        _ = self.copilotAPIToken
        _ = self.warpAPIToken
        _ = self.tokenAccountsByProvider
        _ = self.debugLoadingPattern
        _ = self.selectedMenuProvider
        _ = self.configRevision
        return 0
    }
}
