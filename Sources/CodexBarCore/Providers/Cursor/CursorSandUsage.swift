import Foundation

/// Grok Bot (internally "Sand") included or trial usage from Cursor's dashboard.
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
    public let sandTrialExpiresAt: String?

    private enum CodingKeys: String, CodingKey {
        case currentPeriodStart, nextResetTimestampUtc, usagePercent, hasAvailableUsage, hasNonZeroIncludedLimit
        case sandTrialExpiresAt
    }

    public init(
        currentPeriodStart: String?,
        nextResetTimestampUtc: String?,
        usagePercent: Double?,
        hasAvailableUsage: Bool?,
        hasNonZeroIncludedLimit: Bool?,
        sandTrialExpiresAt: String? = nil)
    {
        self.currentPeriodStart = currentPeriodStart
        self.nextResetTimestampUtc = nextResetTimestampUtc
        self.usagePercent = usagePercent
        self.hasAvailableUsage = hasAvailableUsage
        self.hasNonZeroIncludedLimit = hasNonZeroIncludedLimit
        self.sandTrialExpiresAt = sandTrialExpiresAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.currentPeriodStart = try container.decodeIfPresent(String.self, forKey: .currentPeriodStart)
        self.nextResetTimestampUtc = try container.decodeIfPresent(String.self, forKey: .nextResetTimestampUtc)
        self.usagePercent = try container.decodeIfPresent(Double.self, forKey: .usagePercent)
        self.hasAvailableUsage = try container.decodeIfPresent(Bool.self, forKey: .hasAvailableUsage)
        self.hasNonZeroIncludedLimit = try container.decodeIfPresent(Bool.self, forKey: .hasNonZeroIncludedLimit)
        // An optional trial field must not discard an otherwise valid paid allowance.
        self.sandTrialExpiresAt = try? container.decodeIfPresent(String.self, forKey: .sandTrialExpiresAt)
    }

    /// Grok Bot bar, or `nil` when neither an included allowance nor an unexpired trial is reported.
    public func extraRateWindow(now: Date = .init(), resetDescription: (Date) -> String) -> NamedRateWindow? {
        let isTrial = Self.parseISO8601(self.sandTrialExpiresAt).map { $0 > now } ?? false
        guard self.hasNonZeroIncludedLimit == true || isTrial, let usagePercent = self.usagePercent else {
            return nil
        }
        // Trial credit expires rather than replenishing; neither reset text nor weekly semantics apply.
        let start = isTrial ? nil : Self.parseISO8601(self.currentPeriodStart)
        let resetsAt = isTrial ? nil : Self.parseISO8601(self.nextResetTimestampUtc)
        return NamedRateWindow(
            id: Self.extraWindowID,
            title: Self.extraWindowTitle,
            window: RateWindow(
                usedPercent: UsagePercent(raw: usagePercent).displayClamped,
                windowMinutes: Self.windowMinutes(start: start, end: resetsAt),
                resetsAt: resetsAt,
                resetDescription: resetsAt.map(resetDescription)))
    }

    static func parseISO8601(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }

    static func windowMinutes(start: Date?, end: Date?) -> Int? {
        guard let start, let end else { return nil }
        let minutes = Int((end.timeIntervalSince(start) / 60).rounded())
        return minutes > 0 ? minutes : nil
    }
}
