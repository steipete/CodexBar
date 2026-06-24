import Foundation

/// Parsed, Sendable view of the LongCat console quota model:
/// 总额度 (total token quota) plus 加油包额度 (fuel packs, which expire).
public struct LongCatUsageSnapshot: Sendable {
    public var totalQuota: Double?
    public var usedQuota: Double?
    public var remainingQuota: Double?
    public var fuelPackTotal: Double?
    public var fuelPackRemaining: Double?
    public var nearestFuelExpiry: Date?
    public var accountName: String?
    public var updatedAt: Date

    public init(
        totalQuota: Double? = nil,
        usedQuota: Double? = nil,
        remainingQuota: Double? = nil,
        fuelPackTotal: Double? = nil,
        fuelPackRemaining: Double? = nil,
        nearestFuelExpiry: Date? = nil,
        accountName: String? = nil,
        updatedAt: Date = Date())
    {
        self.totalQuota = totalQuota
        self.usedQuota = usedQuota
        self.remainingQuota = remainingQuota
        self.fuelPackTotal = fuelPackTotal
        self.fuelPackRemaining = fuelPackRemaining
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
        // Primary: overall token quota consumption (总额度).
        var primary: RateWindow?
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

        let identity = ProviderIdentitySnapshot(
            providerID: .longcat,
            accountEmail: nil,
            accountOrganization: self.accountName,
            loginMethod: nil)

        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            tertiary: nil,
            providerCost: nil,
            updatedAt: self.updatedAt,
            identity: identity)
    }
}
