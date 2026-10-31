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
    /// Keys that ride the machine-local pending queue but never a transferred file.
    private static let queueOnlyKeys = Set(["agentSessionsManualHosts", "costUsageHosts"])
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
        "confettiOnWeeklyLimitResetsEnabled", "limitResetNotificationsEnabled", "menuBarShowsHighestUsage",
        "codexResetCreditExpiryNotificationsEnabled",
        "upcomingResetNotificationsEnabled",
        "showOptionalCreditsAndExtraUsage", "providerChangelogLinksEnabled", "providersSortedAlphabetically",
        "refreshAllProvidersOnMenuOpen", "mergeIcons", "mergeIconsStacked", "switcherShowsIcons",
        "menuBarColorByProvider",
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
        "unifiedIconSource": ["currentSelection", "highestUsage", "frontmostApp"],
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

    /// The file/import ingress: structurally valid documents that carry machine-local
    /// queue-only keys (host lists) are refused rather than applied on another machine.
    public init(data: Data) throws {
        self = try JSONDecoder().decode(Self.self, from: data)
        try self.validate()
        for key in Self.queueOnlyKeys where self.preferences[key] != nil {
            throw Error.invalid("Machine-local preference does not transfer: \(key)")
        }
    }

    /// The machine-local pending queue: written by this Mac's CLI, so queue-only keys ride it.
    public init(queueData: Data) throws {
        self = try JSONDecoder().decode(Self.self, from: queueData)
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
        result.preferences.merge(incoming.importingPreferences) { _, new in new }
        return result
    }

    private var importingPreferences: [String: ProviderConfigExtensionValue] {
        var values = self.preferences
        // Older exports must still replace a newer icon-source choice, including queued CLI imports.
        if values["unifiedIconSource"] == nil, case let .bool(highest)? = values["menuBarShowsHighestUsage"] {
            values["unifiedIconSource"] = .string(highest ? "highestUsage" : "currentSelection")
        }
        return values
    }

    public init(defaults: UserDefaults) throws {
        for key in Self.keys {
            let defaultsKey = key == "costUsageEnabled" ? "tokenCostUsageEnabled" : key
            guard let value = defaults.object(forKey: defaultsKey) else { continue }
            let data = try JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed)
            self.preferences[key] = try JSONDecoder().decode(ProviderConfigExtensionValue.self, from: data)
        }
        if let pending = defaults.data(forKey: Self.pendingImportKey) {
            var queued = try Self(queueData: pending)
            // Queue-only keys (host lists) stay machine-local even while queued.
            queued.preferences = queued.preferences.filter { Self.keys.contains($0.key) }
            self = try self.merging(queued)
        }
        try self.validate()
    }

    public func applying(to current: SyncedPreferences) throws -> SyncedPreferences {
        var values = try JSONDecoder().decode(
            [String: ProviderConfigExtensionValue].self, from: JSONEncoder().encode(current))
        // Optional fields omitted by the encoder still belong to the sync projection.
        let keys = Set(values.keys).union([
            "weeklyProgressWorkDays", "paceVisible", "workdayTickAppearance", "unifiedIconSource",
        ])
        values.merge(self.importingPreferences.filter { keys.contains($0.key) }) { _, new in new }
        return try JSONDecoder().decode(SyncedPreferences.self, from: JSONEncoder().encode(values))
    }

    public mutating func include(_ synced: SyncedPreferences) throws {
        try self.preferences.merge(JSONDecoder().decode(
            [String: ProviderConfigExtensionValue].self, from: JSONEncoder().encode(synced))) { _, new in new }
        if synced.weeklyProgressWorkDays == nil { self.preferences["weeklyProgressWorkDays"] = .null }
    }

    public static var importLockURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("CodexBar/preferences-import.lock", isDirectory: false)
    }

    /// Host read/modify/write, queue merges, and app consumption share one transaction.
    /// Waiting keeps a notification arriving during a CLI write from leaving its queue unapplied.
    public static func withImportLock<T>(
        in defaults: UserDefaults,
        lockURL: URL? = Self.importLockURL,
        operation: () throws -> T) throws -> T
    {
        try ManagedCodexAccountLock.withLock(at: lockURL, wait: true) {
            defaults.synchronize()
            return try operation()
        }
    }

    public func queueImport(in defaults: UserDefaults, lockURL: URL? = Self.importLockURL) throws {
        try Self.withImportLock(in: defaults, lockURL: lockURL) {
            let previous = try defaults.data(forKey: Self.pendingImportKey).map(Self.init(queueData:)) ?? Self()
            try defaults.set(previous.merging(self).encoded(), forKey: Self.pendingImportKey)
            defaults.synchronize()
        }
    }

    public static func consumePendingImport(
        in defaults: UserDefaults,
        lockURL: URL? = Self.importLockURL,
        apply: (Self) throws -> Void) throws
    {
        try self.withImportLock(in: defaults, lockURL: lockURL) {
            guard let data = defaults.data(forKey: Self.pendingImportKey) else { return }
            try apply(Self(queueData: data))
            defaults.removeObject(forKey: Self.pendingImportKey)
            defaults.synchronize()
        }
    }

    public func validate() throws {
        guard self.version == 1 else { throw Error.invalid("Unsupported preferences version") }
        for (key, value) in self.preferences {
            let valid: Bool
            switch value {
            case .bool: valid = Self.boolKeys.contains(key)
            case let .string(raw):
                valid = key == "agentSessionsManualHosts"
                    || (Self.stringChoices[key]?.contains(raw)
                        ?? (key == "preferredCurrencyCode" &&
                            (raw == "auto" || (raw.count == 3 && raw.utf8.allSatisfy { (65...90).contains($0) }))))
            case let .integer(number): valid = key == "weeklyProgressWorkDays" && (1...7).contains(number)
            case .null: valid = key == "weeklyProgressWorkDays"
            case let .array(values):
                if Self.thresholdKeys.contains(key) {
                    valid = values
                        .allSatisfy {
                            if case let .integer(n) = $0 { return QuotaWarningThresholds.allowedRange.contains(Int(n))
                            }; return false
                        }
                } else if key == "costUsageHosts" {
                    // Spend membership is re-filtered against the manual hosts by the app's setter.
                    valid = values.allSatisfy {
                        if case .string = $0 { return true }; return false
                    }
                } else {
                    valid = key == "mergedOverviewSelectedProviders" && values.count <= 6 && values.allSatisfy {
                        if case let .string(raw) = $0 { return ProviderInstanceID(rawValue: raw) != nil }; return false
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
