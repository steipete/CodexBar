import Foundation

public struct iOSWidgetSnapshot: Codable, Equatable, Sendable {
    public struct ProviderEntry: Codable, Equatable, Sendable {
        public let providerID: String
        public let updatedAt: Date
        public let primary: RateWindow?
        public let secondary: RateWindow?
        public let tertiary: RateWindow?
        public let creditsRemaining: Double?
        public let codeReviewRemainingPercent: Double?
        public let tokenUsage: TokenUsageSummary?
        public let dailyUsage: [DailyUsagePoint]

        public init(
            providerID: String,
            updatedAt: Date,
            primary: RateWindow?,
            secondary: RateWindow?,
            tertiary: RateWindow?,
            creditsRemaining: Double?,
            codeReviewRemainingPercent: Double?,
            tokenUsage: TokenUsageSummary?,
            dailyUsage: [DailyUsagePoint])
        {
            self.providerID = providerID
            self.updatedAt = updatedAt
            self.primary = primary
            self.secondary = secondary
            self.tertiary = tertiary
            self.creditsRemaining = creditsRemaining
            self.codeReviewRemainingPercent = codeReviewRemainingPercent
            self.tokenUsage = tokenUsage
            self.dailyUsage = dailyUsage
        }

        private enum CodingKeys: String, CodingKey {
            case providerID = "provider"
            case updatedAt
            case primary
            case secondary
            case tertiary
            case creditsRemaining
            case codeReviewRemainingPercent
            case tokenUsage
            case dailyUsage
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

    public struct TokenUsageSummary: Codable, Equatable, Sendable {
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

    public struct DailyUsagePoint: Codable, Equatable, Sendable {
        public let dayKey: String
        public let totalTokens: Int?
        public let costUSD: Double?

        public init(dayKey: String, totalTokens: Int?, costUSD: Double?) {
            self.dayKey = dayKey
            self.totalTokens = totalTokens
            self.costUSD = costUSD
        }
    }

    public struct ProviderSummary: Equatable, Sendable {
        public let providerID: String
        public let displayName: String
        public let updatedAt: Date
        public let sessionRemainingPercent: Double?
        public let weeklyRemainingPercent: Double?
        public let creditsRemaining: Double?
        public let codeReviewRemainingPercent: Double?
        public let todayCostUSD: Double?
        public let last30DaysCostUSD: Double?
        public let todayTokens: Int?
        public let last30DaysTokens: Int?
    }

    public let entries: [ProviderEntry]
    public let enabledProviderIDs: [String]
    public let generatedAt: Date

    public init(entries: [ProviderEntry], enabledProviderIDs: [String], generatedAt: Date) {
        self.entries = entries
        self.enabledProviderIDs = enabledProviderIDs
        self.generatedAt = generatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case entries
        case enabledProviderIDs = "enabledProviders"
        case generatedAt
    }

    public var providerSummaries: [ProviderSummary] {
        self.entries.map { entry in
            ProviderSummary(
                providerID: entry.providerID,
                displayName: iOSProviderCatalog.displayName(for: entry.providerID),
                updatedAt: entry.updatedAt,
                sessionRemainingPercent: entry.primary?.remainingPercent,
                weeklyRemainingPercent: entry.secondary?.remainingPercent,
                creditsRemaining: entry.creditsRemaining,
                codeReviewRemainingPercent: entry.codeReviewRemainingPercent,
                todayCostUSD: entry.tokenUsage?.sessionCostUSD,
                last30DaysCostUSD: entry.tokenUsage?.last30DaysCostUSD,
                todayTokens: entry.tokenUsage?.sessionTokens,
                last30DaysTokens: entry.tokenUsage?.last30DaysTokens)
        }
    }

    public var availableProviderIDs: [String] {
        let source = self.enabledProviderIDs.isEmpty ? self.entries.map(\.providerID) : self.enabledProviderIDs
        var seen: Set<String> = []
        return source.filter { seen.insert($0).inserted }
    }

    public func selectedProviderID(preferred: String?) -> String? {
        let available = self.availableProviderIDs
        guard !available.isEmpty else { return nil }
        if let preferred, available.contains(preferred) {
            return preferred
        }
        return available.first
    }

    public static func decode(from data: Data) throws -> iOSWidgetSnapshot {
        try self.decoder.decode(iOSWidgetSnapshot.self, from: data)
    }

    public func encode() throws -> Data {
        try Self.encoder.encode(self)
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

public enum iOSWidgetSnapshotStore {
    public static let appGroupID = "group.com.steipete.codexbar"
    private static let filename = "widget-snapshot.json"
    private static let selectedProviderKey = "widgetSelectedProvider"

    public static func load(bundleID: String? = Bundle.main.bundleIdentifier) -> iOSWidgetSnapshot? {
        guard let url = self.snapshotURL(bundleID: bundleID) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? iOSWidgetSnapshot.decode(from: data)
    }

    public static func save(_ snapshot: iOSWidgetSnapshot, bundleID: String? = Bundle.main.bundleIdentifier) {
        guard let url = self.snapshotURL(bundleID: bundleID) else { return }
        guard let data = try? snapshot.encode() else { return }
        try? data.write(to: url, options: [.atomic])
    }

    public static func loadSelectedProviderID(bundleID: String? = Bundle.main.bundleIdentifier) -> String? {
        guard let defaults = self.sharedDefaults(bundleID: bundleID) else { return nil }
        return defaults.string(forKey: self.selectedProviderKey)
    }

    public static func saveSelectedProviderID(_ providerID: String, bundleID: String? = Bundle.main.bundleIdentifier) {
        guard let defaults = self.sharedDefaults(bundleID: bundleID) else { return }
        defaults.set(providerID, forKey: self.selectedProviderKey)
    }

    private static func sharedDefaults(bundleID: String?) -> UserDefaults? {
        guard let groupID = self.groupID(for: bundleID) else { return nil }
        return UserDefaults(suiteName: groupID)
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
        let dir = base.appendingPathComponent("CodexBar", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(self.filename, isDirectory: false)
    }

    private static func groupID(for bundleID: String?) -> String? {
        guard let bundleID, !bundleID.isEmpty else { return self.appGroupID }
        if bundleID.contains(".debug") {
            return "group.com.steipete.codexbar.debug"
        }
        return self.appGroupID
    }
}

public enum iOSProviderCatalog {
    public static func displayName(for providerID: String) -> String {
        self.metadata[providerID] ?? providerID.capitalized
    }

    private static let metadata: [String: String] = [
        "codex": "Codex",
        "claude": "Claude",
        "gemini": "Gemini",
        "antigravity": "Antigravity",
        "cursor": "Cursor",
        "opencode": "OpenCode",
        "zai": "z.ai",
        "factory": "Droid",
        "copilot": "Copilot",
        "minimax": "MiniMax",
        "vertexai": "Vertex AI",
        "kiro": "Kiro",
        "augment": "Augment",
        "jetbrains": "JetBrains",
        "kimi": "Kimi",
        "kimik2": "Kimi K2",
        "amp": "Amp",
        "synthetic": "Synthetic",
    ]
}

public enum iOSWidgetPreviewData {
    public static func snapshot() -> iOSWidgetSnapshot {
        iOSWidgetSnapshot(
            entries: [
                .init(
                    providerID: "codex",
                    updatedAt: Date(),
                    primary: .init(usedPercent: 32, windowMinutes: 300, resetsAt: nil, resetDescription: "Resets in 3h"),
                    secondary: .init(
                        usedPercent: 58,
                        windowMinutes: 10_080,
                        resetsAt: nil,
                        resetDescription: "Resets in 4d"),
                    tertiary: nil,
                    creditsRemaining: 1243.4,
                    codeReviewRemainingPercent: 77,
                    tokenUsage: .init(
                        sessionCostUSD: 12.4,
                        sessionTokens: 420_000,
                        last30DaysCostUSD: 923.8,
                        last30DaysTokens: 12_400_000),
                    dailyUsage: [
                        .init(dayKey: "2026-02-02", totalTokens: 120_000, costUSD: 15.2),
                        .init(dayKey: "2026-02-03", totalTokens: 80_000, costUSD: 10.1),
                        .init(dayKey: "2026-02-04", totalTokens: 140_000, costUSD: 17.9),
                        .init(dayKey: "2026-02-05", totalTokens: 90_000, costUSD: 11.4),
                        .init(dayKey: "2026-02-06", totalTokens: 160_000, costUSD: 19.8),
                    ]),
            ],
            enabledProviderIDs: ["codex"],
            generatedAt: Date())
    }
}
