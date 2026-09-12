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
    /// Remaining prepaid balance, when the provider exposes it separately from spend and budget.
    public let balance: Double?
    /// Balance observation, including a confirmed absent or unavailable balance; independent of the budget age.
    public let balanceUpdatedAt: Date?
    /// Codex shared workspace provenance; nil for other providers and legacy balance observations.
    public let balanceIsWorkspace: Bool?
    public let updatedAt: Date
    /// Codex-only unavailable observation. Optional for compatibility with successful and legacy snapshots.
    var balanceIsUnavailable: Bool?

    public init(
        used: Double,
        limit: Double,
        currencyCode: String,
        period: String? = nil,
        resetsAt: Date? = nil,
        nextRegenAmount: Double? = nil,
        personalUsed: Double? = nil,
        balance: Double? = nil,
        balanceUpdatedAt: Date? = nil,
        balanceIsWorkspace: Bool? = nil,
        updatedAt: Date)
    {
        self.used = used
        self.limit = limit
        self.currencyCode = currencyCode
        self.period = period
        self.resetsAt = resetsAt
        self.nextRegenAmount = nextRegenAmount
        self.personalUsed = personalUsed
        self.balance = balance
        self.balanceUpdatedAt = balanceUpdatedAt
        self.balanceIsWorkspace = balanceIsWorkspace
        self.updatedAt = updatedAt
        self.balanceIsUnavailable = nil
    }

    /// Projects a positive spend budget into a quota meter without assigning it a time-window cadence.
    package var spendLimitWindow: RateWindow? {
        guard self.limit > 0 else { return nil }
        return RateWindow(
            usedPercent: max(0, min(100, (self.used / self.limit) * 100)),
            windowMinutes: nil,
            resetsAt: self.resetsAt,
            resetDescription: nil)
    }

    func replacing(balance: Double?) -> Self {
        self.replacing(
            balance: balance,
            balanceUpdatedAt: self.balanceUpdatedAt,
            balanceIsWorkspace: self.balanceIsWorkspace,
            balanceIsUnavailable: self.balanceIsUnavailable)
    }

    func replacing(
        balance: Double?,
        balanceUpdatedAt: Date?,
        balanceIsWorkspace: Bool?,
        balanceIsUnavailable: Bool?) -> Self
    {
        var result = Self(
            used: self.used,
            limit: self.limit,
            currencyCode: self.currencyCode,
            period: self.period,
            resetsAt: self.resetsAt,
            nextRegenAmount: self.nextRegenAmount,
            personalUsed: self.personalUsed,
            balance: balance,
            balanceUpdatedAt: balanceUpdatedAt,
            balanceIsWorkspace: balanceIsWorkspace,
            updatedAt: self.updatedAt)
        result.balanceIsUnavailable = balanceIsUnavailable
        return result
    }
}
