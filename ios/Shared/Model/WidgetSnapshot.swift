import Foundation

// MARK: - Wire contract mirror
//
// These value types are a faithful, Foundation-only mirror of the macOS
// `CodexBarCore.WidgetSnapshot` / `RateWindow` types. CodexBarCore cannot compile
// for iOS (it pulls in SweetCookieKit, sqlite3, Security, AppKit), so the iOS app,
// widget, and Live Activity share these standalone copies instead.
//
// The JSON contract is the source of truth: coding keys here MUST match the macOS
// encoder exactly (see `Sources/CodexBarCore/WidgetSnapshot.swift`). A round-trip
// contract test lives in `Tests/CodexBarTests/MobileSnapshotContractTests.swift`
// to catch drift.

public struct RateWindow: Codable, Equatable, Sendable {
    public let usedPercent: Double
    public let windowMinutes: Int?
    public let resetsAt: Date?
    public let resetDescription: String?
    public let nextRegenPercent: Double?
    public let isSyntheticPlaceholder: Bool

    public init(
        usedPercent: Double,
        windowMinutes: Int? = nil,
        resetsAt: Date? = nil,
        resetDescription: String? = nil,
        nextRegenPercent: Double? = nil,
        isSyntheticPlaceholder: Bool = false)
    {
        self.usedPercent = usedPercent
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
        self.resetDescription = resetDescription
        self.nextRegenPercent = nextRegenPercent
        self.isSyntheticPlaceholder = isSyntheticPlaceholder
    }

    /// Percentage of the window still available (0...100), clamped.
    public var remainingPercent: Double {
        max(0, min(100, 100 - self.usedPercent))
    }

    private enum CodingKeys: String, CodingKey {
        case usedPercent
        case windowMinutes
        case resetsAt
        case resetDescription
        case nextRegenPercent
        case isSyntheticPlaceholder
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.usedPercent = try container.decode(Double.self, forKey: .usedPercent)
        self.windowMinutes = try container.decodeIfPresent(Int.self, forKey: .windowMinutes)
        self.resetsAt = try container.decodeIfPresent(Date.self, forKey: .resetsAt)
        self.resetDescription = try container.decodeIfPresent(String.self, forKey: .resetDescription)
        self.nextRegenPercent = try container.decodeIfPresent(Double.self, forKey: .nextRegenPercent)
        self.isSyntheticPlaceholder =
            try container.decodeIfPresent(Bool.self, forKey: .isSyntheticPlaceholder) ?? false
    }
}

public struct WidgetSnapshot: Codable, Sendable {
    public struct WidgetUsageRowSnapshot: Codable, Equatable, Sendable, Identifiable {
        public let id: String
        public let title: String
        public let percentLeft: Double?

        public init(id: String, title: String, percentLeft: Double?) {
            self.id = id
            self.title = title
            self.percentLeft = percentLeft
        }
    }

    public struct ProviderEntry: Codable, Sendable, Identifiable {
        public let provider: UsageProvider
        public let updatedAt: Date
        public let primary: RateWindow?
        public let secondary: RateWindow?
        public let tertiary: RateWindow?
        public let usageRows: [WidgetUsageRowSnapshot]?
        public let creditsRemaining: Double?
        public let codeReviewRemainingPercent: Double?
        public let tokenUsage: TokenUsageSummary?
        public let dailyUsage: [DailyUsagePoint]

        public var id: UsageProvider { self.provider }

        public init(
            provider: UsageProvider,
            updatedAt: Date,
            primary: RateWindow?,
            secondary: RateWindow?,
            tertiary: RateWindow?,
            usageRows: [WidgetUsageRowSnapshot]? = nil,
            creditsRemaining: Double?,
            codeReviewRemainingPercent: Double?,
            tokenUsage: TokenUsageSummary?,
            dailyUsage: [DailyUsagePoint])
        {
            self.provider = provider
            self.updatedAt = updatedAt
            self.primary = primary
            self.secondary = secondary
            self.tertiary = tertiary
            self.usageRows = usageRows
            self.creditsRemaining = creditsRemaining
            self.codeReviewRemainingPercent = codeReviewRemainingPercent
            self.tokenUsage = tokenUsage
            self.dailyUsage = dailyUsage
        }

        /// Rows suitable for display, falling back to primary/secondary/tertiary windows when the
        /// precomputed `usageRows` are absent (older snapshots).
        public var displayRows: [WidgetUsageRowSnapshot] {
            if let usageRows, !usageRows.isEmpty { return usageRows }
            var rows: [WidgetUsageRowSnapshot] = []
            if let primary {
                rows.append(.init(id: "primary", title: "Session", percentLeft: primary.remainingPercent))
            }
            if let secondary {
                rows.append(.init(id: "secondary", title: "Weekly", percentLeft: secondary.remainingPercent))
            }
            if let tertiary {
                rows.append(.init(id: "tertiary", title: "Opus", percentLeft: tertiary.remainingPercent))
            }
            return rows
        }

        /// The single most relevant "remaining %" for compact surfaces (menu bar / lock screen),
        /// preferring the lowest available window so warnings surface first.
        public var headlineRemainingPercent: Double? {
            let candidates = self.displayRows.compactMap(\.percentLeft)
            return candidates.min()
        }
    }

    public struct TokenUsageSummary: Codable, Sendable {
        public let sessionCostUSD: Double?
        public let sessionTokens: Int?
        public let last30DaysCostUSD: Double?
        public let last30DaysTokens: Int?
        public let currencyCode: String
        public let sessionLabel: String
        public let last30DaysLabel: String

        public init(
            sessionCostUSD: Double?,
            sessionTokens: Int?,
            last30DaysCostUSD: Double?,
            last30DaysTokens: Int?,
            currencyCode: String = "USD",
            sessionLabel: String = "Today",
            last30DaysLabel: String = "30d")
        {
            self.sessionCostUSD = sessionCostUSD
            self.sessionTokens = sessionTokens
            self.last30DaysCostUSD = last30DaysCostUSD
            self.last30DaysTokens = last30DaysTokens
            let trimmedCurrency = currencyCode.trimmingCharacters(in: .whitespacesAndNewlines)
            self.currencyCode = trimmedCurrency.isEmpty ? "USD" : trimmedCurrency.uppercased()
            let trimmedSession = sessionLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            self.sessionLabel = trimmedSession.isEmpty ? "Today" : sessionLabel
            let trimmedMonth = last30DaysLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            self.last30DaysLabel = trimmedMonth.isEmpty ? "30d" : last30DaysLabel
        }

        private enum CodingKeys: String, CodingKey {
            case sessionCostUSD
            case sessionTokens
            case last30DaysCostUSD
            case last30DaysTokens
            case currencyCode
            case sessionLabel
            case last30DaysLabel
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try self.init(
                sessionCostUSD: container.decodeIfPresent(Double.self, forKey: .sessionCostUSD),
                sessionTokens: container.decodeIfPresent(Int.self, forKey: .sessionTokens),
                last30DaysCostUSD: container.decodeIfPresent(Double.self, forKey: .last30DaysCostUSD),
                last30DaysTokens: container.decodeIfPresent(Int.self, forKey: .last30DaysTokens),
                currencyCode: container.decodeIfPresent(String.self, forKey: .currencyCode) ?? "USD",
                sessionLabel: container.decodeIfPresent(String.self, forKey: .sessionLabel) ?? "Today",
                last30DaysLabel: container.decodeIfPresent(String.self, forKey: .last30DaysLabel) ?? "30d")
        }
    }

    public struct DailyUsagePoint: Codable, Sendable, Identifiable {
        public let dayKey: String
        public let totalTokens: Int?
        public let costUSD: Double?

        public var id: String { self.dayKey }

        public init(dayKey: String, totalTokens: Int?, costUSD: Double?) {
            self.dayKey = dayKey
            self.totalTokens = totalTokens
            self.costUSD = costUSD
        }
    }

    public let entries: [ProviderEntry]
    public let enabledProviders: [UsageProvider]
    public let usageBarsShowUsed: Bool
    public let generatedAt: Date

    public init(
        entries: [ProviderEntry],
        enabledProviders: [UsageProvider]? = nil,
        usageBarsShowUsed: Bool = false,
        generatedAt: Date)
    {
        self.entries = entries
        self.enabledProviders = enabledProviders ?? entries.map(\.provider)
        self.usageBarsShowUsed = usageBarsShowUsed
        self.generatedAt = generatedAt
    }

    /// Entries filtered to enabled providers, in the provider's declared order.
    public var enabledEntries: [ProviderEntry] {
        let enabled = Set(self.enabledProviders)
        return self.entries.filter { enabled.contains($0.provider) }
    }

    private enum CodingKeys: String, CodingKey {
        case entries
        case enabledProviders
        case usageBarsShowUsed
        case generatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.entries = try container.decode([ProviderEntry].self, forKey: .entries)
        self.generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        self.enabledProviders = try container.decodeIfPresent([UsageProvider].self, forKey: .enabledProviders)
            ?? self.entries.map(\.provider)
        self.usageBarsShowUsed = try container.decodeIfPresent(Bool.self, forKey: .usageBarsShowUsed) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.entries, forKey: .entries)
        try container.encode(self.enabledProviders, forKey: .enabledProviders)
        try container.encode(self.usageBarsShowUsed, forKey: .usageBarsShowUsed)
        try container.encode(self.generatedAt, forKey: .generatedAt)
    }
}

// MARK: - JSON coding helpers shared by transport + store

public enum SnapshotCoding {
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
