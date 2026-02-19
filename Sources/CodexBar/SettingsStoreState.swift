import Foundation

struct SettingsDefaultsState: Sendable {
    var refreshFrequency: RefreshFrequency
    var launchAtLogin: Bool
    var debugMenuEnabled: Bool
    var debugDisableKeychainAccess: Bool
    var debugFileLoggingEnabled: Bool
    var debugLogLevelRaw: String?
    var debugLoadingPatternRaw: String?
    var debugKeepCLISessionsAlive: Bool
    var statusChecksEnabled: Bool
    var sessionQuotaNotificationsEnabled: Bool
    var usageBarsShowUsed: Bool
    var resetTimesShowAbsolute: Bool
    var menuBarShowsBrandIconWithPercent: Bool
    var menuBarDisplayModeRaw: String?
    var showAllTokenAccountsInMenu: Bool
    var menuBarMetricPreferencesRaw: [String: String]
    var costUsageEnabled: Bool
    var hidePersonalInfo: Bool
    var randomBlinkEnabled: Bool
    var menuBarShowsHighestUsage: Bool
    var claudeOAuthKeychainPromptModeRaw: String?
    var claudeOAuthKeychainReadStrategyRaw: String?
    var claudeWebExtrasEnabledRaw: Bool
    var showOptionalCreditsAndExtraUsage: Bool
    var openAIWebAccessEnabled: Bool
    var jetbrainsIDEBasePath: String
    var mergeIcons: Bool
    var switcherShowsIcons: Bool
    var selectedMenuProviderRaw: String?
    var providerDetectionCompleted: Bool
}
