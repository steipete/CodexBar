import Foundation

protocol OneConsoleTokenPlanSnapshot {
    var planName: String? { get }
    var usedQuota: Double? { get }
    var totalQuota: Double? { get }
    var remainingQuota: Double? { get }
    var resetsAt: Date? { get }
    var fiveHourUsedPercent: Double? { get }
    var fiveHourTotalQuota: Double? { get }
    var fiveHourResetsAt: Date? { get }
    var weeklyUsedPercent: Double? { get }
    var weeklyTotalQuota: Double? { get }
    var weeklyResetsAt: Date? { get }
    var updatedAt: Date { get }
}

extension OneConsoleTokenPlanSnapshot {
    func usageSnapshot(for provider: UsageProvider) -> UsageSnapshot {
        let personalPrimary = self.fiveHourUsedPercent.map {
            RateWindow(
                usedPercent: $0,
                windowMinutes: 5 * 60,
                resetsAt: self.fiveHourResetsAt,
                resetDescription: Self.quotaDetail(usedPercent: $0, total: self.fiveHourTotalQuota))
        }
        let teamPrimary: RateWindow? = Self.usedPercent(
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
        let primary = personalPrimary ?? teamPrimary
        let secondary = self.weeklyUsedPercent.map {
            RateWindow(
                usedPercent: $0,
                windowMinutes: 7 * 24 * 60,
                resetsAt: self.weeklyResetsAt,
                resetDescription: Self.quotaDetail(usedPercent: $0, total: self.weeklyTotalQuota))
        }

        let planName = self.planName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let loginMethod = (planName?.isEmpty ?? true) ? nil : planName
        let identity = ProviderIdentitySnapshot(
            providerID: provider.instanceID,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: loginMethod)

        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
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

    private static func quotaDetail(usedPercent: Double, total: Double?) -> String? {
        guard let total, total > 0 else { return nil }
        let used = total * usedPercent / 100
        return "\(Self.format(used)) / \(Self.format(total)) credits used"
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
