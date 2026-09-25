import Foundation

/// Explicit transfer format. The allowlist is deliberately independent of defaults search domains.
public struct PreferencesDocument: Codable, Sendable {
    public enum Error: LocalizedError {
        case invalid(String)
        public var errorDescription: String? {
            switch self {
            case let .invalid(message): message
            }
        }
    }

    public static let pendingImportKey = "portablePreferencesPendingImport"
    public static let importNotification = "com.steipete.codexbar.preferencesImport"
    public static let defaultsDomain = "com.steipete.codexbar"
    private var version = 1
    private var preferences: [String: ProviderConfigExtensionValue] = [:]

    private static let boolKeys = Set([
        "statusChecksEnabled", "sessionQuotaNotificationsEnabled", "quotaWarningNotificationsEnabled",
        "predictivePaceWarningNotificationsEnabled", "quotaWarningSessionEnabled", "quotaWarningWeeklyEnabled",
        "quotaWarningSoundEnabled", "quotaWarningOnScreenAlertEnabled", "quotaWarningMarkersVisible", "paceVisible",
        "usageBarsShowUsed", "resetTimesShowAbsolute", "costUsageEnabled", "costComparisonPeriodsEnabled",
        "hidePersonalInfo", "randomBlinkEnabled", "confettiOnSessionLimitResetsEnabled",
        "confettiOnWeeklyLimitResetsEnabled", "menuBarShowsHighestUsage", "showOptionalCreditsAndExtraUsage",
        "providerChangelogLinksEnabled", "providersSortedAlphabetically", "refreshAllProvidersOnMenuOpen",
        "mergeIcons", "mergeIconsStacked", "switcherShowsIcons",
    ])
    private static let stringChoices: [String: [String]] = [
        "refreshFrequency": [
            "manual",
            "oneMinute",
            "twoMinutes",
            "fiveMinutes",
            "fifteenMinutes",
            "thirtyMinutes",
            "adaptive",
            "adaptiveAgentAware",
        ],
        "costSummaryDisplayStyle": ["inlineSummary", "costSubmenu", "both"],
        "workdayTickAppearance": ["hidden", "subtle", "highContrast"],
        "mergedOverviewLayout": ["detailed", "compact"],
    ]
    private static let thresholdKeys = Set([
        "quotaWarningThresholds", "quotaWarningSessionThresholds", "quotaWarningWeeklyThresholds",
    ])
    private static var keys: Set<String> {
        self.boolKeys.union(self.stringChoices.keys).union(self.thresholdKeys).union([
            "weeklyProgressWorkDays", "preferredCurrencyCode", "mergedOverviewSelectedProviders",
            "switcherShortcuts",
        ])
    }

    public init() {}

    public init(data: Data) throws {
        self = try JSONDecoder().decode(Self.self, from: data)
        try self.validate()
    }

    public func encoded() throws -> Data {
        try self.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public func value<T: Decodable>(_ key: String, as _: T.Type = T.self) throws -> T? {
        guard let value = self.preferences[key] else { return nil }
        return try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    public mutating func set(_ key: String, _ value: some Encodable) throws {
        self.preferences[key] = try JSONDecoder().decode(
            ProviderConfigExtensionValue.self, from: JSONEncoder().encode(value))
    }

    public func merging(_ incoming: Self) -> Self {
        var result = self
        result.preferences.merge(incoming.preferences) { _, new in new }
        return result
    }

    public init(defaults: UserDefaults) throws {
        for key in Self.keys {
            let defaultsKey = key == "costUsageEnabled" ? "tokenCostUsageEnabled" : key
            guard let value = defaults.object(forKey: defaultsKey) else { continue }
            let data = try JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed)
            self.preferences[key] = try JSONDecoder().decode(ProviderConfigExtensionValue.self, from: data)
        }
        if let pending = defaults.data(forKey: Self.pendingImportKey) {
            self = try self.merging(Self(data: pending))
        }
        try self.validate()
    }

    public func applying(to current: SyncedPreferences) throws -> SyncedPreferences {
        var values = try JSONDecoder().decode(
            [String: ProviderConfigExtensionValue].self, from: JSONEncoder().encode(current))
        // Optional fields omitted by the encoder still belong to the sync projection.
        let keys = Set(values.keys).union(["weeklyProgressWorkDays", "paceVisible", "workdayTickAppearance"])
        values.merge(self.preferences.filter { keys.contains($0.key) }) { _, new in new }
        return try JSONDecoder().decode(SyncedPreferences.self, from: JSONEncoder().encode(values))
    }

    public mutating func include(_ synced: SyncedPreferences) throws {
        try self.preferences.merge(JSONDecoder().decode(
            [String: ProviderConfigExtensionValue].self, from: JSONEncoder().encode(synced))) { _, new in new }
        if synced.weeklyProgressWorkDays == nil { self.preferences["weeklyProgressWorkDays"] = .null }
    }

    public func queueImport(in defaults: UserDefaults) throws {
        let previous = try defaults.data(forKey: Self.pendingImportKey).map(Self.init(data:)) ?? Self()
        try defaults.set(previous.merging(self).encoded(), forKey: Self.pendingImportKey)
        defaults.synchronize()
    }

    public func validate() throws {
        guard self.version == 1 else { throw Error.invalid("Unsupported preferences version") }
        for (key, value) in self.preferences {
            let valid: Bool
            switch value {
            case .bool: valid = Self.boolKeys.contains(key)
            case let .string(raw):
                valid = Self.stringChoices[key]?.contains(raw)
                    ??
                    (key == "preferredCurrencyCode" &&
                        (raw == "auto" || (raw.count == 3 && raw.utf8.allSatisfy { (65...90).contains($0) })))
            case let .integer(number): valid = key == "weeklyProgressWorkDays" && (1...7).contains(number)
            case .null: valid = key == "weeklyProgressWorkDays"
            case let .array(values):
                if Self.thresholdKeys.contains(key) {
                    valid = values
                        .allSatisfy {
                            if case let .integer(n) = $0 { return QuotaWarningThresholds.allowedRange.contains(Int(n))
                            }; return false
                        }
                } else {
                    valid = key == "mergedOverviewSelectedProviders" && values.count <= 6 && values.allSatisfy {
                        if case let .string(raw) = $0 { return UsageProvider(rawValue: raw) != nil }; return false
                    }
                }
            case .object:
                valid = key == "switcherShortcuts"
                if valid { _ = try ProviderSwitcherShortcuts.validated(self.value(key) ?? [:]) }
            default: valid = false
            }
            guard valid else { throw Error.invalid("Invalid or non-portable preference: \(key)") }
        }
    }
}
