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
