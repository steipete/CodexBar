import Foundation

/// Grok Bot (internally "Sand") weekly included usage from Cursor's dashboard.
///
/// `POST /api/dashboard/get-sand-usage-status` with the same session cookie as
/// `/api/usage-summary`. Missing or failed responses must not fail Cursor usage.
public struct CursorSandUsageStatus: Decodable, Sendable, Equatable {
    public static let extraWindowID = "cursor-grok-bot"
    public static let extraWindowTitle = "Grok Bot"
    public static let endpointPath = "/api/dashboard/get-sand-usage-status"

    public let currentPeriodStart: String?
    public let nextResetTimestampUtc: String?
    public let usagePercent: Double?
    public let hasAvailableUsage: Bool?
    public let hasNonZeroIncludedLimit: Bool?

    public init(
        currentPeriodStart: String?,
        nextResetTimestampUtc: String?,
        usagePercent: Double?,
        hasAvailableUsage: Bool?,
        hasNonZeroIncludedLimit: Bool?)
    {
        self.currentPeriodStart = currentPeriodStart
        self.nextResetTimestampUtc = nextResetTimestampUtc
        self.usagePercent = usagePercent
        self.hasAvailableUsage = hasAvailableUsage
        self.hasNonZeroIncludedLimit = hasNonZeroIncludedLimit
    }

    /// Weekly Grok Bot bar, or `nil` when the account has no included Bot allowance.
    public func extraRateWindow(resetDescription: (Date) -> String) -> NamedRateWindow? {
        guard self.hasNonZeroIncludedLimit == true, let usagePercent = self.usagePercent else {
            return nil
        }
        let start = ISO8601DateParser.parse(self.currentPeriodStart)
        let resetsAt = ISO8601DateParser.parse(self.nextResetTimestampUtc)
        return NamedRateWindow(
            id: Self.extraWindowID,
            title: Self.extraWindowTitle,
            window: RateWindow(
                usedPercent: UsagePercent(raw: usagePercent).displayClamped,
                windowMinutes: Self.windowMinutes(start: start, end: resetsAt),
                resetsAt: resetsAt,
                resetDescription: resetsAt.map(resetDescription)))
    }

    static func windowMinutes(start: Date?, end: Date?) -> Int? {
        guard let start, let end else { return nil }
        let minutes = Int((end.timeIntervalSince(start) / 60).rounded())
        return minutes > 0 ? minutes : nil
    }
}
