import Foundation

public struct WidgetSnapshot: Codable, Sendable {
    public struct WidgetUsageRowSnapshot: Codable, Equatable, Sendable {
        public let id: String
        public let title: String
        public let percentLeft: Double?
        public let window: RateWindow?

        public init(id: String, title: String, percentLeft: Double?, window: RateWindow? = nil) {
            self.id = id
            self.title = title
            self.percentLeft = percentLeft
            self.window = window
        }
    }

    public struct ProviderEntry: Codable, Sendable {
        public let provider: ProviderInstanceID
        public let updatedAt: Date
        public let primary: RateWindow?
        public let secondary: RateWindow?
        public let tertiary: RateWindow?
        public let usageRows: [WidgetUsageRowSnapshot]?
        public let creditsRemaining: Double?
        public let codeReviewRemainingPercent: Double?
        public let tokenUsage: TokenUsageSummary?
        public let dailyUsage: [DailyUsagePoint]
        public let providerCost: ProviderCostSnapshot?
        public let quotaOwnerKey: String?

        public init(
            instanceID: ProviderInstanceID,
            updatedAt: Date,
            primary: RateWindow?,
            secondary: RateWindow?,
            tertiary: RateWindow?,
            usageRows: [WidgetUsageRowSnapshot]? = nil,
            creditsRemaining: Double?,
            codeReviewRemainingPercent: Double?,
            tokenUsage: TokenUsageSummary?,
            dailyUsage: [DailyUsagePoint],
            providerCost: ProviderCostSnapshot? = nil,
            quotaOwnerKey: String? = nil)
        {
            self.provider = instanceID
            self.updatedAt = updatedAt
            self.primary = primary
            self.secondary = secondary
            self.tertiary = tertiary
            self.usageRows = usageRows
            self.creditsRemaining = creditsRemaining
            self.codeReviewRemainingPercent = codeReviewRemainingPercent
            self.tokenUsage = tokenUsage
            self.dailyUsage = dailyUsage
            self.providerCost = providerCost
            self.quotaOwnerKey = quotaOwnerKey
        }

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
            dailyUsage: [DailyUsagePoint],
            providerCost: ProviderCostSnapshot? = nil,
            quotaOwnerKey: String? = nil)
        {
            self.init(
                instanceID: provider.instanceID,
                updatedAt: updatedAt,
                primary: primary,
                secondary: secondary,
                tertiary: tertiary,
                usageRows: usageRows,
                creditsRemaining: creditsRemaining,
                codeReviewRemainingPercent: codeReviewRemainingPercent,
                tokenUsage: tokenUsage,
                dailyUsage: dailyUsage,
                providerCost: providerCost,
                quotaOwnerKey: quotaOwnerKey)
        }
    }

    public struct TokenUsageSummary: Codable, Sendable {
        /// Token-cost rows refresh on a slower cadence than quota rows; beyond this lag the
        /// widget discloses their own age instead of inheriting `ProviderEntry.updatedAt`.
        public static let staleLagThreshold: TimeInterval = 10 * 60

        public let sessionCostUSD: Double?
        public let sessionTokens: Int?
        public let last30DaysCostUSD: Double?
        public let last30DaysTokens: Int?
        public let currencyCode: String
        public let sessionLabel: String
        public let last30DaysLabel: String
        public let updatedAt: Date?

        public init(
            sessionCostUSD: Double?,
            sessionTokens: Int?,
            last30DaysCostUSD: Double?,
            last30DaysTokens: Int?,
            currencyCode: String = "USD",
            sessionLabel: String = "Today",
            last30DaysLabel: String = "30d",
            updatedAt: Date? = nil)
        {
            self.sessionCostUSD = sessionCostUSD
            self.sessionTokens = sessionTokens
            self.last30DaysCostUSD = last30DaysCostUSD
            self.last30DaysTokens = last30DaysTokens
            self.currencyCode = currencyCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "USD"
                : currencyCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            self.sessionLabel = sessionLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Today"
                : sessionLabel
            self.last30DaysLabel = last30DaysLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "30d"
                : last30DaysLabel
            self.updatedAt = updatedAt
        }

        /// Unknown age (legacy snapshots) counts as fresh.
        public func isStale(comparedTo entryUpdatedAt: Date) -> Bool {
            guard let updatedAt else { return false }
            return entryUpdatedAt.timeIntervalSince(updatedAt) > Self.staleLagThreshold
        }

        private enum CodingKeys: String, CodingKey {
            case sessionCostUSD
            case sessionTokens
            case last30DaysCostUSD
            case last30DaysTokens
            case currencyCode
            case sessionLabel
            case last30DaysLabel
            case updatedAt
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
                last30DaysLabel: container.decodeIfPresent(String.self, forKey: .last30DaysLabel) ?? "30d",
                updatedAt: container.decodeIfPresent(Date.self, forKey: .updatedAt))
        }
    }

    public struct DailyUsagePoint: Codable, Sendable {
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
    public let enabledProviders: [ProviderInstanceID]
    public let usageBarsShowUsed: Bool
    public let generatedAt: Date

    public init(
        entries: [ProviderEntry],
        enabledProviders: [ProviderInstanceID]? = nil,
        usageBarsShowUsed: Bool = false,
        generatedAt: Date)
    {
        self.entries = entries
        self.enabledProviders = enabledProviders ?? entries.map(\.provider)
        self.usageBarsShowUsed = usageBarsShowUsed
        self.generatedAt = generatedAt
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
        self.enabledProviders = try container.decodeIfPresent([ProviderInstanceID].self, forKey: .enabledProviders)
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

public enum WidgetSnapshotStore {
    @usableFromInline
    static let defaultLoadTimeout: TimeInterval = 2.0

    @usableFromInline
    static let defaultSaveTimeout: TimeInterval = 10.0

    private static let filename = AppGroupSupport.widgetSnapshotFilename
    private static let boundedIOExecutionLock = NSLock()
    private static let boundedIOStateLock = NSLock()
    private nonisolated(unsafe) static var boundedIOCircuitBreakerTripped = false
    private static let log = CodexBarLog.logger("widget-snapshot")

    /// Access is synchronized by `lock`, so detached worker threads can safely publish a result.
    private final class BoundedResultBox<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value?

        func set(_ value: Value?) {
            self.lock.lock()
            self.value = value
            self.lock.unlock()
        }

        func get() -> Value? {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.value
        }
    }

    public static func load(bundleID: String? = Bundle.main.bundleIdentifier) -> WidgetSnapshot? {
        guard !self.isBoundedIOCircuitBreakerTripped() else { return nil }
        return self.load(from: self.snapshotURL(bundleID: bundleID))
    }

    public static func load(
        from url: URL,
        timeout: TimeInterval = WidgetSnapshotStore.defaultLoadTimeout) -> WidgetSnapshot?
    {
        guard let data: Data = self.performBounded(label: "load", timeout: timeout, operation: {
            try? Data(contentsOf: url)
        }) else { return nil }
        return try? self.decoder.decode(WidgetSnapshot.self, from: data)
    }

    public static func save(_ snapshot: WidgetSnapshot, bundleID: String? = Bundle.main.bundleIdentifier) {
        guard !self.isBoundedIOCircuitBreakerTripped() else { return }
        self.save(snapshot, to: self.snapshotURL(bundleID: bundleID))
    }

    public static func save(
        _ snapshot: WidgetSnapshot,
        to url: URL,
        timeout: TimeInterval = WidgetSnapshotStore.defaultSaveTimeout)
    {
        guard !self.isBoundedIOCircuitBreakerTripped(),
              let data = try? self.encoder.encode(snapshot)
        else { return }

        _ = self.performBounded(label: "save", timeout: timeout) {
            do {
                try data.write(to: url, options: [.atomic])
                return true
            } catch {
                return nil
            }
        }
    }

    static func _test_performBounded<T: Sendable>(
        timeout: TimeInterval,
        operation: @escaping @Sendable () -> T?) -> T?
    {
        self.performBounded(label: "test", timeout: timeout, operation: operation)
    }

    static func _test_resetBoundedIOState() {
        self.boundedIOStateLock.lock()
        self.boundedIOCircuitBreakerTripped = false
        self.boundedIOStateLock.unlock()
    }

    private static func performBounded<T: Sendable>(
        label: String,
        timeout: TimeInterval,
        operation: @escaping @Sendable () -> T?) -> T?
    {
        guard !self.isBoundedIOCircuitBreakerTripped() else { return nil }
        self.boundedIOExecutionLock.lock()
        defer { self.boundedIOExecutionLock.unlock() }
        guard !self.isBoundedIOCircuitBreakerTripped() else { return nil }

        let result = BoundedResultBox<T>()
        let completion = DispatchSemaphore(value: 0)
        let thread = Thread {
            result.set(operation())
            completion.signal()
        }
        thread.name = "CodexBar.widget-snapshot.\(label)"
        thread.start()

        guard completion.wait(timeout: .now() + timeout) == .success else {
            self.tripBoundedIOCircuitBreaker(label: label, timeout: timeout)
            return nil
        }
        return result.get()
    }

    private static func isBoundedIOCircuitBreakerTripped() -> Bool {
        self.boundedIOStateLock.lock()
        defer { self.boundedIOStateLock.unlock() }
        return self.boundedIOCircuitBreakerTripped
    }

    private static func tripBoundedIOCircuitBreaker(label: String, timeout: TimeInterval) {
        self.boundedIOStateLock.lock()
        let didTrip = !self.boundedIOCircuitBreakerTripped
        self.boundedIOCircuitBreakerTripped = true
        self.boundedIOStateLock.unlock()

        guard didTrip else { return }
        self.log.warning(
            "Widget snapshot I/O timed out; disabling container access for this process",
            metadata: ["operation": label, "timeoutSeconds": String(timeout)])
    }

    private static func snapshotURL(bundleID: String?) -> URL {
        AppGroupSupport.snapshotURL(bundleID: bundleID)
    }

    public static func appGroupID(for bundleID: String?) -> String? {
        AppGroupSupport.currentGroupID(for: bundleID)
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

    public static func loadSelectedProvider(bundleID: String? = Bundle.main.bundleIdentifier) -> ProviderInstanceID? {
        let defaults = self.sharedDefaults(bundleID: bundleID)
        guard let raw = defaults.string(forKey: self.selectedProviderKey) else { return nil }
        return ProviderInstanceID(rawValue: raw)
    }

    public static func saveSelectedProvider(
        instanceID: ProviderInstanceID,
        bundleID: String? = Bundle.main.bundleIdentifier)
    {
        let defaults = self.sharedDefaults(bundleID: bundleID)
        defaults.set(instanceID.rawValue, forKey: self.selectedProviderKey)
    }

    public static func saveSelectedProvider(
        _ provider: UsageProvider,
        bundleID: String? = Bundle.main.bundleIdentifier)
    {
        self.saveSelectedProvider(instanceID: provider.instanceID, bundleID: bundleID)
    }

    private static func sharedDefaults(bundleID: String?) -> UserDefaults {
        AppGroupSupport.sharedDefaults(bundleID: bundleID) ?? .standard
    }
}
