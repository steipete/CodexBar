import Foundation

/// Parsed, Sendable view of the LongCat console quota model:
/// 总额度 (total) = 初始额度 (free, refreshed daily) + 加油包额度 (fuel packs, expiring),
/// plus today's token usage from `tokenUsage`.
public struct LongCatUsageSnapshot: Sendable {
    public var totalQuota: Double?
    public var freeQuota: Double?
    public var fuelPackTotal: Double?
    public var fuelPackRemaining: Double?
    public var usedQuota: Double?
    public var remainingQuota: Double?
    public var todayTokens: Double?
    public var nearestFuelExpiry: Date?
    public var accountName: String?
    public var updatedAt: Date

    public init(
        totalQuota: Double? = nil,
        freeQuota: Double? = nil,
        fuelPackTotal: Double? = nil,
        fuelPackRemaining: Double? = nil,
        usedQuota: Double? = nil,
        remainingQuota: Double? = nil,
        todayTokens: Double? = nil,
        nearestFuelExpiry: Date? = nil,
        accountName: String? = nil,
        updatedAt: Date = Date())
    {
        self.totalQuota = totalQuota
        self.freeQuota = freeQuota
        self.fuelPackTotal = fuelPackTotal
        self.fuelPackRemaining = fuelPackRemaining
        self.usedQuota = usedQuota
        self.remainingQuota = remainingQuota
        self.todayTokens = todayTokens
        self.nearestFuelExpiry = nearestFuelExpiry
        self.accountName = accountName
        self.updatedAt = updatedAt
    }
}

extension LongCatUsageSnapshot {
    private func resolvedUsed(total: Double) -> Double {
        if let used = usedQuota { return max(0, used) }
        if let remaining = remainingQuota { return max(0, total - remaining) }
        return 0
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        // Primary: overall quota consumption (总额度).
        var primary = RateWindow(
            usedPercent: 0,
            windowMinutes: nil,
            resetsAt: nil,
            resetDescription: "No LongCat quota data")
        if let total = totalQuota, total > 0 {
            let used = self.resolvedUsed(total: total)
            primary = RateWindow(
                usedPercent: min(100, used / total * 100),
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: "\(Int(used))/\(Int(total))")
        }

        // Secondary: fuel-pack balance (加油包额度), with nearest expiry as reset.
        var secondary: RateWindow?
        if let total = fuelPackTotal, total > 0 {
            let remaining = self.fuelPackRemaining ?? total
            let used = max(0, total - remaining)
            secondary = RateWindow(
                usedPercent: min(100, used / total * 100),
                windowMinutes: nil,
                resetsAt: self.nearestFuelExpiry,
                resetDescription: "Fuel pack: \(Int(remaining))/\(Int(total))")
        }

        // Tertiary: informational today-token count.
        var tertiary: RateWindow?
        if let today = todayTokens {
            tertiary = RateWindow(
                usedPercent: 0,
                windowMinutes: 1440,
                resetsAt: nil,
                resetDescription: "Today: \(Int(today)) tokens")
        }

        let identity = ProviderIdentitySnapshot(
            providerID: .longcat,
            accountEmail: nil,
            accountOrganization: self.accountName,
            loginMethod: nil)

        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            tertiary: tertiary,
            providerCost: nil,
            updatedAt: self.updatedAt,
            identity: identity)
    }
}
