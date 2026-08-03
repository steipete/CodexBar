import Foundation

public enum CodexBarSyncSchema {
    public static let currentVersion = 1

    public static func canApply(_ schemaVersion: Int) -> Bool {
        schemaVersion <= self.currentVersion
    }
}

public enum SyncRecordType: String, Sendable {
    case providerIntent = "ProviderIntent"
    case device = "Device"
    case accountSnapshot = "AccountSnapshot"
    case preferences = "Preferences"
}

public enum ProviderIntentSecretField: String, CaseIterable, Sendable {
    case apiKey
    case secretKey
    case cookieHeader
    case tokenAccounts
}

/// The portable, non-secret provider configuration. Machine routing fields and hooks deliberately have no
/// representation in this type, so untrusted sync payloads cannot change them.
public struct ProviderIntentPayload: Codable, Sendable {
    public let schemaVersion: Int
    public let provider: UsageProvider
    public var enabled: Bool?
    public var extrasEnabled: Bool?
    public var region: String?
    public var workspaceID: String?
    public var enterpriseHost: String?
    public var claudeSwapEnabled: Bool?
    public var claudeSwapShowSingleAccount: Bool?
    public var antigravityPrioritizeExhaustedQuotas: Bool?
    public var quotaWarnings: QuotaWarningConfig?
    public var kiloKnownOrganizations: [KiloOrganization]?
    public var kiloEnabledOrganizationIDs: [String]?
    public var deepseekProfileID: String?
    public var deepseekProfileScope: String?

    public init(config: ProviderConfig, schemaVersion: Int = CodexBarSyncSchema.currentVersion) {
        self.schemaVersion = schemaVersion
        self.provider = config.id
        self.enabled = config.enabled
        self.extrasEnabled = config.extrasEnabled
        self.region = config.region
        self.workspaceID = config.workspaceID
        self.enterpriseHost = config.enterpriseHost
        self.claudeSwapEnabled = config.claudeSwapEnabled
        self.claudeSwapShowSingleAccount = config.claudeSwapShowSingleAccount
        self.antigravityPrioritizeExhaustedQuotas = config.antigravityPrioritizeExhaustedQuotas
        self.quotaWarnings = config.quotaWarnings
        self.kiloKnownOrganizations = config.kiloKnownOrganizations
        self.kiloEnabledOrganizationIDs = config.kiloEnabledOrganizationIDs
        self.deepseekProfileID = config.deepseekProfileID
        self.deepseekProfileScope = config.deepseekProfileScope
    }

    public func applying(
        to local: ProviderConfig,
        secretFields: [String: String],
        canEnable: (UsageProvider, ProviderConfig) -> Bool) throws -> ProviderConfig
    {
        precondition(local.id == self.provider)
        var result = local
        if self.enabled == true {
            if canEnable(self.provider, local) {
                result.enabled = true
            }
        } else {
            // Disabling and returning to the provider default are always safe to apply.
            result.enabled = self.enabled
        }
        result.extrasEnabled = self.extrasEnabled
        result.region = self.region
        result.workspaceID = self.workspaceID
        result.enterpriseHost = self.enterpriseHost
        result.claudeSwapEnabled = self.claudeSwapEnabled
        result.claudeSwapShowSingleAccount = self.claudeSwapShowSingleAccount
        result.antigravityPrioritizeExhaustedQuotas = self.antigravityPrioritizeExhaustedQuotas
        result.quotaWarnings = self.quotaWarnings
        result.kiloKnownOrganizations = self.kiloKnownOrganizations
        result.kiloEnabledOrganizationIDs = self.kiloEnabledOrganizationIDs
        result.deepseekProfileID = self.deepseekProfileID
        result.deepseekProfileScope = self.deepseekProfileScope

        if let value = secretFields[ProviderIntentSecretField.apiKey.rawValue] {
            result.apiKey = value.isEmpty ? nil : value
        }
        if let value = secretFields[ProviderIntentSecretField.secretKey.rawValue] {
            result.secretKey = value.isEmpty ? nil : value
        }
        if let value = secretFields[ProviderIntentSecretField.cookieHeader.rawValue] {
            result.cookieHeader = value.isEmpty ? nil : value
        }
        if let value = secretFields[ProviderIntentSecretField.tokenAccounts.rawValue] {
            result.tokenAccounts = value.isEmpty
                ? nil
                : try CanonicalSyncJSON.decode(ProviderTokenAccountData.self, from: value)
        }
        return result
    }

    public static func secretFields(
        for config: ProviderConfig,
        includeSecrets: Bool,
        previouslyUploadedFields: Set<String> = []) throws -> [String: String]
    {
        guard includeSecrets else { return [:] }
        var fields: [String: String] = [:]
        func set(_ field: ProviderIntentSecretField, value: String?) {
            if let value {
                fields[field.rawValue] = value
            } else if previouslyUploadedFields.contains(field.rawValue) {
                fields[field.rawValue] = ""
            }
        }
        set(.apiKey, value: config.apiKey)
        set(.secretKey, value: config.secretKey)
        set(.cookieHeader, value: config.cookieHeader)
        let accounts = try config.tokenAccounts.map(CanonicalSyncJSON.string)
        set(.tokenAccounts, value: accounts)
        return fields
    }

    public static func recordName(for provider: UsageProvider) -> String {
        "intent-\(provider.rawValue)"
    }
}

public struct DeviceSyncPayload: Codable, Sendable {
    public let schemaVersion: Int
    public let deviceID: String
    public let hostName: String
    public let model: String
    public let appVersion: String
    public let lastSeen: Date

    public init(
        deviceID: String,
        hostName: String,
        model: String,
        appVersion: String,
        lastSeen: Date,
        schemaVersion: Int = CodexBarSyncSchema.currentVersion)
    {
        self.schemaVersion = schemaVersion
        self.deviceID = deviceID
        self.hostName = hostName
        self.model = model
        self.appVersion = appVersion
        self.lastSeen = lastSeen
    }

    public var recordName: String {
        "device-\(self.deviceID)"
    }
}

public struct AccountSnapshotSyncPayload: Codable, Sendable {
    public let schemaVersion: Int
    public let provider: UsageProvider
    public let deviceID: String
    public let accountKey: String
    public let fetchedAt: Date
    public let displayLabel: String
    public let usage: UsageSnapshot

    public init(
        provider: UsageProvider,
        deviceID: String,
        accountIdentity: String?,
        displayLabel: String,
        usage: UsageSnapshot,
        schemaVersion: Int = CodexBarSyncSchema.currentVersion)
    {
        self.schemaVersion = schemaVersion
        self.provider = provider
        self.deviceID = deviceID
        self.accountKey = Self.accountKey(for: accountIdentity)
        self.fetchedAt = usage.updatedAt
        self.displayLabel = displayLabel
        self.usage = usage
    }

    public init(
        provider: UsageProvider,
        deviceID: String,
        accountKey: String,
        fetchedAt: Date,
        displayLabel: String,
        usage: UsageSnapshot,
        schemaVersion: Int = CodexBarSyncSchema.currentVersion)
    {
        self.schemaVersion = schemaVersion
        self.provider = provider
        self.deviceID = deviceID
        self.accountKey = accountKey
        self.fetchedAt = fetchedAt
        self.displayLabel = displayLabel
        self.usage = usage
    }

    public var recordName: String {
        "snap-\(self.provider.rawValue)-\(self.accountKey)"
    }

    public static func accountKey(for identity: String?) -> String {
        guard let identity = identity?.trimmingCharacters(in: .whitespacesAndNewlines), !identity.isEmpty else {
            return "default"
        }
        return CanonicalSyncJSON.hash(data: Data(identity.lowercased().utf8))
    }
}

public struct SyncedPreferences: Codable, Sendable {
    public var statusChecksEnabled: Bool
    public var sessionQuotaNotificationsEnabled: Bool
    public var quotaWarningNotificationsEnabled: Bool
    public var predictivePaceWarningNotificationsEnabled: Bool
    public var quotaWarningThresholds: [Int]
    public var quotaWarningSessionThresholds: [Int]
    public var quotaWarningWeeklyThresholds: [Int]
    public var quotaWarningSessionEnabled: Bool
    public var quotaWarningWeeklyEnabled: Bool
    public var quotaWarningSoundEnabled: Bool
    public var quotaWarningOnScreenAlertEnabled: Bool
    public var quotaWarningMarkersVisible: Bool
    public var weeklyProgressWorkDays: Int?
    public var usageBarsShowUsed: Bool
    public var resetTimesShowAbsolute: Bool
    public var costUsageEnabled: Bool
    public var costComparisonPeriodsEnabled: Bool
    public var costSummaryDisplayStyle: String
    public var hidePersonalInfo: Bool
    public var randomBlinkEnabled: Bool
    public var confettiOnSessionLimitResetsEnabled: Bool
    public var confettiOnWeeklyLimitResetsEnabled: Bool
    public var menuBarShowsHighestUsage: Bool
    public var showOptionalCreditsAndExtraUsage: Bool
    public var providerChangelogLinksEnabled: Bool
    public var preferredCurrencyCode: String
    public var providersSortedAlphabetically: Bool
    public var refreshFrequency: String
    public var refreshAllProvidersOnMenuOpen: Bool

    public init(
        statusChecksEnabled: Bool,
        sessionQuotaNotificationsEnabled: Bool,
        quotaWarningNotificationsEnabled: Bool,
        predictivePaceWarningNotificationsEnabled: Bool,
        quotaWarningThresholds: [Int],
        quotaWarningSessionThresholds: [Int],
        quotaWarningWeeklyThresholds: [Int],
        quotaWarningSessionEnabled: Bool,
        quotaWarningWeeklyEnabled: Bool,
        quotaWarningSoundEnabled: Bool,
        quotaWarningOnScreenAlertEnabled: Bool,
        quotaWarningMarkersVisible: Bool,
        weeklyProgressWorkDays: Int?,
        usageBarsShowUsed: Bool,
        resetTimesShowAbsolute: Bool,
        costUsageEnabled: Bool,
        costComparisonPeriodsEnabled: Bool,
        costSummaryDisplayStyle: String,
        hidePersonalInfo: Bool,
        randomBlinkEnabled: Bool,
        confettiOnSessionLimitResetsEnabled: Bool,
        confettiOnWeeklyLimitResetsEnabled: Bool,
        menuBarShowsHighestUsage: Bool,
        showOptionalCreditsAndExtraUsage: Bool,
        providerChangelogLinksEnabled: Bool,
        preferredCurrencyCode: String,
        providersSortedAlphabetically: Bool,
        refreshFrequency: String,
        refreshAllProvidersOnMenuOpen: Bool)
    {
        self.statusChecksEnabled = statusChecksEnabled
        self.sessionQuotaNotificationsEnabled = sessionQuotaNotificationsEnabled
        self.quotaWarningNotificationsEnabled = quotaWarningNotificationsEnabled
        self.predictivePaceWarningNotificationsEnabled = predictivePaceWarningNotificationsEnabled
        self.quotaWarningThresholds = quotaWarningThresholds
        self.quotaWarningSessionThresholds = quotaWarningSessionThresholds
        self.quotaWarningWeeklyThresholds = quotaWarningWeeklyThresholds
        self.quotaWarningSessionEnabled = quotaWarningSessionEnabled
        self.quotaWarningWeeklyEnabled = quotaWarningWeeklyEnabled
        self.quotaWarningSoundEnabled = quotaWarningSoundEnabled
        self.quotaWarningOnScreenAlertEnabled = quotaWarningOnScreenAlertEnabled
        self.quotaWarningMarkersVisible = quotaWarningMarkersVisible
        self.weeklyProgressWorkDays = weeklyProgressWorkDays
        self.usageBarsShowUsed = usageBarsShowUsed
        self.resetTimesShowAbsolute = resetTimesShowAbsolute
        self.costUsageEnabled = costUsageEnabled
        self.costComparisonPeriodsEnabled = costComparisonPeriodsEnabled
        self.costSummaryDisplayStyle = costSummaryDisplayStyle
        self.hidePersonalInfo = hidePersonalInfo
        self.randomBlinkEnabled = randomBlinkEnabled
        self.confettiOnSessionLimitResetsEnabled = confettiOnSessionLimitResetsEnabled
        self.confettiOnWeeklyLimitResetsEnabled = confettiOnWeeklyLimitResetsEnabled
        self.menuBarShowsHighestUsage = menuBarShowsHighestUsage
        self.showOptionalCreditsAndExtraUsage = showOptionalCreditsAndExtraUsage
        self.providerChangelogLinksEnabled = providerChangelogLinksEnabled
        self.preferredCurrencyCode = preferredCurrencyCode
        self.providersSortedAlphabetically = providersSortedAlphabetically
        self.refreshFrequency = refreshFrequency
        self.refreshAllProvidersOnMenuOpen = refreshAllProvidersOnMenuOpen
    }
}

public struct PreferencesSyncPayload: Codable, Sendable {
    public let schemaVersion: Int
    public var preferences: SyncedPreferences

    public init(
        preferences: SyncedPreferences,
        schemaVersion: Int = CodexBarSyncSchema.currentVersion)
    {
        self.schemaVersion = schemaVersion
        self.preferences = preferences
    }

    public static let recordName = "prefs-global"
}

public struct SyncConflictValue<Value: Sendable>: Sendable {
    public let value: Value
    public let editCount: Int64
    public let modifiedAt: Date

    public init(value: Value, editCount: Int64, modifiedAt: Date) {
        self.value = value
        self.editCount = editCount
        self.modifiedAt = modifiedAt
    }
}

public enum SyncConflictResolver {
    public static func winner<Value>(
        local: SyncConflictValue<Value>,
        server: SyncConflictValue<Value>) -> SyncConflictValue<Value>
    {
        if local.editCount != server.editCount {
            return local.editCount > server.editCount ? local : server
        }
        return local.modifiedAt > server.modifiedAt ? local : server
    }
}
