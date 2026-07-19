import Foundation

/// One rolling usage window of the personal token plan.
public struct AlibabaTokenPlanRollingWindow: Sendable {
    public let usedPercent: Double
    public let totalCredits: Double?
    public let resetsAt: Date?

    public init(usedPercent: Double, totalCredits: Double?, resetsAt: Date?) {
        self.usedPercent = usedPercent
        self.totalCredits = totalCredits
        self.resetsAt = resetsAt
    }

    public var usedCredits: Double? {
        self.totalCredits.map { $0 * self.usedPercent / 100 }
    }
}

/// The two editions report fundamentally different quota shapes, so they are modelled as
/// separate cases rather than a bag of optionals where only some combinations are valid.
public enum AlibabaTokenPlanQuota: Sendable {
    /// Team edition: a monthly credit pool.
    case creditPool(used: Double?, total: Double?, remaining: Double?, resetsAt: Date?)
    /// Personal edition: rolling 5-hour and weekly windows.
    case rollingWindows(fiveHour: AlibabaTokenPlanRollingWindow, weekly: AlibabaTokenPlanRollingWindow)
}

public struct AlibabaTokenPlanUsageSnapshot: Sendable {
    public let planName: String?
    public let quota: AlibabaTokenPlanQuota
    public let updatedAt: Date

    public init(planName: String?, quota: AlibabaTokenPlanQuota, updatedAt: Date) {
        self.planName = planName
        self.quota = quota
        self.updatedAt = updatedAt
    }
}

extension AlibabaTokenPlanUsageSnapshot {
    private static let fiveHourWindowMinutes = 5 * 60
    private static let weeklyWindowMinutes = 7 * 24 * 60
    private static let monthlyWindowMinutes = 30 * 24 * 60

    public func toUsageSnapshot() -> UsageSnapshot {
        let primary: RateWindow?
        let secondary: RateWindow?

        switch self.quota {
        case let .creditPool(used, total, remaining, resetsAt):
            primary = Self.usedPercent(used: used, total: total, remaining: remaining).map {
                RateWindow(
                    usedPercent: $0,
                    windowMinutes: Self.monthlyWindowMinutes,
                    resetsAt: resetsAt,
                    resetDescription: Self.quotaDetail(used: used, total: total, remaining: remaining))
            }
            secondary = nil
        case let .rollingWindows(fiveHour, weekly):
            primary = Self.rateWindow(from: fiveHour, windowMinutes: Self.fiveHourWindowMinutes)
            secondary = Self.rateWindow(from: weekly, windowMinutes: Self.weeklyWindowMinutes)
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
            secondary: secondary,
            tertiary: nil,
            providerCost: nil,
            updatedAt: self.updatedAt,
            identity: identity)
    }

    private static func rateWindow(
        from window: AlibabaTokenPlanRollingWindow,
        windowMinutes: Int) -> RateWindow
    {
        let detail: String? = if let total = window.totalCredits, total > 0, let used = window.usedCredits {
            "\(self.format(used)) / \(self.format(total)) credits used"
        } else {
            nil
        }
        return RateWindow(
            usedPercent: max(0, min(window.usedPercent, 100)),
            windowMinutes: windowMinutes,
            resetsAt: window.resetsAt,
            resetDescription: detail)
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
