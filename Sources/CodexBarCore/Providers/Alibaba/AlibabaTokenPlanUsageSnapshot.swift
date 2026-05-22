import Foundation

public struct AlibabaTokenPlanUsageSnapshot: Sendable {
    public let planName: String?
    public let usedQuota: Double?
    public let totalQuota: Double?
    public let remainingQuota: Double?
    public let resetsAt: Date?
    public let updatedAt: Date

    public init(
        planName: String?,
        usedQuota: Double?,
        totalQuota: Double?,
        remainingQuota: Double?,
        resetsAt: Date?,
        updatedAt: Date)
    {
        self.planName = planName
        self.usedQuota = usedQuota
        self.totalQuota = totalQuota
        self.remainingQuota = remainingQuota
        self.resetsAt = resetsAt
        self.updatedAt = updatedAt
    }
}

extension AlibabaTokenPlanUsageSnapshot {
    public func toUsageSnapshot() -> UsageSnapshot {
        let primary: RateWindow? = Self.usedPercent(
            used: self.usedQuota,
            total: self.totalQuota,
            remaining: self.remainingQuota).map {
            RateWindow(
                usedPercent: $0,
                windowMinutes: 30 * 24 * 60,
                resetsAt: self.resetsAt,
                resetDescription: Self.quotaDetail(
                    used: self.usedQuota,
                    total: self.totalQuota,
                    remaining: self.remainingQuota))
        }

        let planName = self.planName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let loginMethod = (planName?.isEmpty ?? true) ? nil : planName
        let identity = ProviderIdentitySnapshot(
            providerID: .alibabatokenplan,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: loginMethod)

        return UsageSnapshot(
            primary: primary,
            secondary: nil,
            tertiary: nil,
            providerCost: nil,
            updatedAt: self.updatedAt,
            identity: identity)
    }

    private static func usedPercent(used: Double?, total: Double?, remaining: Double?) -> Double? {
        guard let total, total > 0 else { return nil }
        let usedValue: Double? = if let used {
            used
        } else if let remaining {
            total - remaining
        } else {
            nil
        }
        guard let usedValue else { return nil }
        let normalizedUsed = max(0, min(usedValue, total))
        return normalizedUsed / total * 100
    }

    private static func quotaDetail(used: Double?, total: Double?, remaining: Double?) -> String? {
        if let used, let total, total > 0 {
            return "\(self.format(used)) / \(self.format(total)) credits used"
        }
        if let remaining, let total, total > 0 {
            return "\(Self.format(remaining)) / \(Self.format(total)) credits left"
        }
        if let remaining {
            return "\(Self.format(remaining)) credits left"
        }
        return nil
    }

    private static func format(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.maximumFractionDigits = value.rounded() == value ? 0 : 2
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }
}
