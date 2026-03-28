import Foundation

public enum UsageProvider: String, CaseIterable, Codable, Hashable, Sendable {
    case codex
    case claude

    public var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        }
    }
}

public struct RateWindow: Codable, Equatable, Sendable {
    public let usedPercent: Double
    public let windowMinutes: Int?
    public let resetsAt: Date?
    public let resetDescription: String?

    public init(usedPercent: Double, windowMinutes: Int?, resetsAt: Date?, resetDescription: String?) {
        self.usedPercent = usedPercent
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
        self.resetDescription = resetDescription
    }

    public var remainingPercent: Double {
        max(0, 100 - self.usedPercent)
    }
}

public struct WidgetSnapshot: Codable, Sendable, Equatable {
    public struct ProviderEntry: Codable, Sendable, Equatable {
        public let provider: UsageProvider
        public let updatedAt: Date
        public let primary: RateWindow?
        public let secondary: RateWindow?
        public let tertiary: RateWindow?
        public let creditsRemaining: Double?
        public let codeReviewRemainingPercent: Double?
        public let tokenUsage: TokenUsageSummary?
        public let dailyUsage: [DailyUsagePoint]

        public init(
            provider: UsageProvider,
            updatedAt: Date,
            primary: RateWindow?,
            secondary: RateWindow?,
            tertiary: RateWindow?,
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
            self.creditsRemaining = creditsRemaining
            self.codeReviewRemainingPercent = codeReviewRemainingPercent
            self.tokenUsage = tokenUsage
            self.dailyUsage = dailyUsage
        }
    }

    public struct TokenUsageSummary: Codable, Sendable, Equatable {
        public let sessionCostUSD: Double?
        public let sessionTokens: Int?
        public let last30DaysCostUSD: Double?
        public let last30DaysTokens: Int?

        public init(
            sessionCostUSD: Double?,
            sessionTokens: Int?,
            last30DaysCostUSD: Double?,
            last30DaysTokens: Int?)
        {
            self.sessionCostUSD = sessionCostUSD
            self.sessionTokens = sessionTokens
            self.last30DaysCostUSD = last30DaysCostUSD
            self.last30DaysTokens = last30DaysTokens
        }
    }

    public struct DailyUsagePoint: Codable, Sendable, Equatable {
        public let dayKey: String
        public let totalTokens: Int?
        public let costUSD: Double?

        public init(dayKey: String, totalTokens: Int?, costUSD: Double?) {
            self.dayKey = dayKey
            self.totalTokens = totalTokens
            self.costUSD = costUSD
        }
    }

    public let entries: [ProviderEntry]
    public let enabledProviders: [UsageProvider]
    public let generatedAt: Date

    public init(entries: [ProviderEntry], enabledProviders: [UsageProvider]? = nil, generatedAt: Date) {
        self.entries = entries
        self.enabledProviders = enabledProviders ?? entries.map(\.provider)
        self.generatedAt = generatedAt
    }
}

public enum WidgetPreviewData {
    public static func snapshot() -> WidgetSnapshot {
        let now = Date()
        return WidgetSnapshot(
            entries: [
                WidgetSnapshot.ProviderEntry(
                    provider: .codex,
                    updatedAt: now,
                    primary: RateWindow(
                        usedPercent: 41,
                        windowMinutes: 5 * 60,
                        resetsAt: now.addingTimeInterval(88 * 60),
                        resetDescription: DisplayFormat.resetDescription(from: now.addingTimeInterval(88 * 60))),
                    secondary: RateWindow(
                        usedPercent: 27,
                        windowMinutes: 7 * 24 * 60,
                        resetsAt: now.addingTimeInterval(39 * 60 * 60),
                        resetDescription: DisplayFormat.resetDescription(from: now.addingTimeInterval(39 * 60 * 60))),
                    tertiary: nil,
                    creditsRemaining: 48.5,
                    codeReviewRemainingPercent: nil,
                    tokenUsage: nil,
                    dailyUsage: []),
                WidgetSnapshot.ProviderEntry(
                    provider: .claude,
                    updatedAt: now,
                    primary: RateWindow(
                        usedPercent: 62,
                        windowMinutes: 5 * 60,
                        resetsAt: now.addingTimeInterval(52 * 60),
                        resetDescription: DisplayFormat.resetDescription(from: now.addingTimeInterval(52 * 60))),
                    secondary: RateWindow(
                        usedPercent: 33,
                        windowMinutes: 7 * 24 * 60,
                        resetsAt: now.addingTimeInterval(62 * 60 * 60),
                        resetDescription: DisplayFormat.resetDescription(from: now.addingTimeInterval(62 * 60 * 60))),
                    tertiary: RateWindow(
                        usedPercent: 18,
                        windowMinutes: 7 * 24 * 60,
                        resetsAt: now.addingTimeInterval(62 * 60 * 60),
                        resetDescription: DisplayFormat.resetDescription(from: now.addingTimeInterval(62 * 60 * 60))),
                    creditsRemaining: nil,
                    codeReviewRemainingPercent: nil,
                    tokenUsage: nil,
                    dailyUsage: []),
            ],
            enabledProviders: [.codex, .claude],
            generatedAt: now)
    }
}

public enum WidgetSnapshotStore {
    public static let appGroupInfoKey = "CodexBarAppGroupIdentifier"

    private static let filename = "widget-snapshot-ios.json"

    public static func load(bundleID: String? = Bundle.main.bundleIdentifier) -> WidgetSnapshot? {
        guard let url = self.snapshotURL(bundleID: bundleID) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? self.decoder.decode(WidgetSnapshot.self, from: data)
    }

    public static func save(_ snapshot: WidgetSnapshot, bundleID: String? = Bundle.main.bundleIdentifier) {
        guard let url = self.snapshotURL(bundleID: bundleID) else { return }
        do {
            let data = try self.encoder.encode(snapshot)
            try data.write(to: url, options: [.atomic])
        } catch {
            return
        }
    }

    private static func snapshotURL(bundleID: String?) -> URL? {
        let fm = FileManager.default
        if let groupID = self.groupID(for: bundleID),
           let container = fm.containerURL(forSecurityApplicationGroupIdentifier: groupID)
        {
            return container.appendingPathComponent(self.filename, isDirectory: false)
        }

        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("CodexBariOS", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(self.filename, isDirectory: false)
    }

    fileprivate static func groupID(for bundleID: String?) -> String? {
        if let configuredGroupID = Bundle.main.object(
            forInfoDictionaryKey: self.appGroupInfoKey) as? String
        {
            let trimmed = configuredGroupID.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        guard let bundleID, !bundleID.isEmpty else { return nil }
        return "group.\(self.baseBundleIdentifier(from: bundleID))"
    }

    private static func baseBundleIdentifier(from bundleID: String) -> String {
        var base = bundleID
        let suffixes = [".widget", ".shared", ".tests"]
        for suffix in suffixes where base.hasSuffix(suffix) {
            base.removeLast(suffix.count)
            break
        }
        return base
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

public struct WidgetRefreshDiagnostics: Codable, Sendable, Equatable {
    public enum Result: String, Codable, Sendable {
        case refreshed
        case cached
        case skipped
    }

    public enum Source: String, Codable, Sendable {
        case usageWidget
        case switcherWidget

        public var displayName: String {
            switch self {
            case .usageWidget: "usage"
            case .switcherWidget: "switcher"
            }
        }
    }

    public let requestCount: Int
    public let triggeredAt: Date
    public let completedAt: Date
    public let source: Source?
    public let result: Result
    public let networkAttempted: Bool
    public let message: String?
    public let snapshotGeneratedAt: Date?

    public init(
        requestCount: Int = 1,
        triggeredAt: Date,
        completedAt: Date,
        source: Source? = nil,
        result: Result,
        networkAttempted: Bool = false,
        message: String?,
        snapshotGeneratedAt: Date?)
    {
        self.requestCount = requestCount
        self.triggeredAt = triggeredAt
        self.completedAt = completedAt
        self.source = source
        self.result = result
        self.networkAttempted = networkAttempted
        self.message = message
        self.snapshotGeneratedAt = snapshotGeneratedAt
    }

    private enum CodingKeys: String, CodingKey {
        case requestCount
        case triggeredAt
        case completedAt
        case source
        case result
        case networkAttempted
        case message
        case snapshotGeneratedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.requestCount = try container.decodeIfPresent(Int.self, forKey: .requestCount) ?? 1
        self.triggeredAt = try container.decode(Date.self, forKey: .triggeredAt)
        self.completedAt = try container.decode(Date.self, forKey: .completedAt)
        self.source = try container.decodeIfPresent(Source.self, forKey: .source)
        self.result = try container.decode(Result.self, forKey: .result)
        self.networkAttempted = try container.decodeIfPresent(Bool.self, forKey: .networkAttempted) ?? false
        self.message = try container.decodeIfPresent(String.self, forKey: .message)
        self.snapshotGeneratedAt = try container.decodeIfPresent(Date.self, forKey: .snapshotGeneratedAt)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.requestCount, forKey: .requestCount)
        try container.encode(self.triggeredAt, forKey: .triggeredAt)
        try container.encode(self.completedAt, forKey: .completedAt)
        try container.encodeIfPresent(self.source, forKey: .source)
        try container.encode(self.result, forKey: .result)
        try container.encode(self.networkAttempted, forKey: .networkAttempted)
        try container.encodeIfPresent(self.message, forKey: .message)
        try container.encodeIfPresent(self.snapshotGeneratedAt, forKey: .snapshotGeneratedAt)
    }
}

public enum WidgetRefreshDiagnosticsStore {
    private static let filename = "widget-refresh-diagnostics-ios.json"

    public static func load(bundleID: String? = Bundle.main.bundleIdentifier) -> WidgetRefreshDiagnostics? {
        guard let url = self.diagnosticsURL(bundleID: bundleID) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? self.decoder.decode(WidgetRefreshDiagnostics.self, from: data)
    }

    public static func save(_ diagnostics: WidgetRefreshDiagnostics, bundleID: String? = Bundle.main.bundleIdentifier) {
        guard let url = self.diagnosticsURL(bundleID: bundleID) else { return }
        do {
            let data = try self.encoder.encode(diagnostics)
            try data.write(to: url, options: [.atomic])
        } catch {
            return
        }
    }

    private static func diagnosticsURL(bundleID: String?) -> URL? {
        let fm = FileManager.default
        if let groupID = WidgetSnapshotStore.groupID(for: bundleID),
           let container = fm.containerURL(forSecurityApplicationGroupIdentifier: groupID)
        {
            return container.appendingPathComponent(self.filename, isDirectory: false)
        }

        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("CodexBariOS", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(self.filename, isDirectory: false)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

public enum WidgetSelectionStore {
    private static let selectedProviderKey = "widgetSelectedProvider"

    public static func loadSelectedProvider(bundleID: String? = Bundle.main.bundleIdentifier) -> UsageProvider? {
        guard let defaults = self.sharedDefaults(bundleID: bundleID) else { return nil }
        guard let raw = defaults.string(forKey: self.selectedProviderKey) else { return nil }
        return UsageProvider(rawValue: raw)
    }

    public static func saveSelectedProvider(
        _ provider: UsageProvider,
        bundleID: String? = Bundle.main.bundleIdentifier)
    {
        guard let defaults = self.sharedDefaults(bundleID: bundleID) else { return }
        defaults.set(provider.rawValue, forKey: self.selectedProviderKey)
    }

    private static func sharedDefaults(bundleID: String?) -> UserDefaults? {
        guard let groupID = WidgetSnapshotStore.groupID(for: bundleID) else { return nil }
        return UserDefaults(suiteName: groupID)
    }
}
