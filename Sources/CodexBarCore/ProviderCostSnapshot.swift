import Foundation

/// Provider-specific spend/budget snapshot (e.g. Claude "Extra usage" monthly spend vs limit).
public struct ProviderCostSnapshot: Equatable, Codable, Sendable {
    public let used: Double
    public let limit: Double
    public let currencyCode: String
    /// Human-friendly period label (e.g. "Monthly"). Optional; some providers don't expose a period.
    public let period: String?
    /// Optional renewal/reset timestamp for the period.
    public let resetsAt: Date?
    /// Optional amount restored on the next regeneration tick for providers with rolling credit recovery.
    public let nextRegenAmount: Double?
    /// This account's own contribution when `used`/`limit` describe a shared/pooled budget
    /// (e.g. Cursor team on-demand pool). nil when the budget is already personal.
    public let personalUsed: Double?
    public let updatedAt: Date

    public init(
        used: Double,
        limit: Double,
        currencyCode: String,
        period: String? = nil,
        resetsAt: Date? = nil,
        nextRegenAmount: Double? = nil,
        personalUsed: Double? = nil,
        updatedAt: Date)
    {
        self.used = used
        self.limit = limit
        self.currencyCode = currencyCode
        self.period = period
        self.resetsAt = resetsAt
        self.nextRegenAmount = nextRegenAmount
        self.personalUsed = personalUsed
        self.updatedAt = updatedAt
    }
}
