import Foundation

public struct KimiUsageSnapshot: Sendable {
    public let weekly: KimiUsageDetail
    public let rateLimit: KimiUsageDetail?
    public let updatedAt: Date
    let subscriptionBalance: KimiSubscriptionBalance?

    public init(weekly: KimiUsageDetail, rateLimit: KimiUsageDetail?, updatedAt: Date) {
        self.weekly = weekly
        self.rateLimit = rateLimit
        self.updatedAt = updatedAt
        self.subscriptionBalance = nil
    }

    init(
        weekly: KimiUsageDetail,
        rateLimit: KimiUsageDetail?,
        subscriptionBalance: KimiSubscriptionBalance?,
        updatedAt: Date)
    {
        self.weekly = weekly
        self.rateLimit = rateLimit
        self.subscriptionBalance = subscriptionBalance
        self.updatedAt = updatedAt
    }

    private static func parseDate(_ dateString: String?) -> Date? {
        guard let dateString else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: dateString) {
            return date
        }
        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        return fallback.date(from: dateString)
    }

    private static func minutesFromNow(_ date: Date?) -> Int? {
        guard let date else { return nil }
        let minutes = Int(date.timeIntervalSince(Date()) / 60)
        return minutes > 0 ? minutes : nil
    }

    private static func clampedPercent(_ value: Double) -> Double {
        min(100, max(0, value))
    }
}

extension KimiUsageSnapshot {
    public func toUsageSnapshot() -> UsageSnapshot {
        // Parse weekly quota
        let weeklyLimit = Int(weekly.limit) ?? 0
        let weeklyRemaining = Int(weekly.remaining ?? "")
        let weeklyUsed = Int(weekly.used ?? "") ?? {
            guard let remaining = weeklyRemaining else { return 0 }
            return max(0, weeklyLimit - remaining)
        }()

        let weeklyPercent = weeklyLimit > 0 ? Self.clampedPercent(Double(weeklyUsed) / Double(weeklyLimit) * 100) : 0

        let weeklyWindow = RateWindow(
            usedPercent: weeklyPercent,
            windowMinutes: nil, // Weekly doesn't have a fixed window like rate limit
            resetsAt: Self.parseDate(self.weekly.resetTime),
            resetDescription: "\(weeklyUsed)/\(weeklyLimit) requests")

        // Parse rate limit if available
        var rateLimitWindow: RateWindow?
        if let rateLimit = self.rateLimit {
            let rateLimitValue = Int(rateLimit.limit) ?? 0
            if rateLimitValue > 0 {
                let rateRemaining = Int(rateLimit.remaining ?? "")
                let rateUsed = Int(rateLimit.used ?? "") ?? {
                    guard let remaining = rateRemaining else { return 0 }
                    return max(0, rateLimitValue - remaining)
                }()
                let ratePercent = Self.clampedPercent(Double(rateUsed) / Double(rateLimitValue) * 100)

                rateLimitWindow = RateWindow(
                    usedPercent: ratePercent,
                    windowMinutes: 300, // 300 minutes = 5 hours
                    resetsAt: Self.parseDate(rateLimit.resetTime),
                    resetDescription: "Rate: \(rateUsed)/\(rateLimitValue) per 5 hours")
            }
        }

        let monthlyWindow = self.subscriptionBalance.flatMap { balance -> NamedRateWindow? in
            // Monthly = shared subscription pool (`amountUsedRatio`), not the Code-only `kimiCodeUsedRatio`:
            // the pool is shared across features, so amountUsedRatio is the real "subscription remaining".
            guard balance.feature == nil || balance.feature == "FEATURE_OMNI" else { return nil }
            guard balance.type == nil || balance.type == "SUBSCRIPTION" else { return nil }
            guard let ratio = balance.amountUsedRatio else { return nil }
            let window = RateWindow(
                usedPercent: Self.clampedPercent(ratio * 100),
                windowMinutes: nil,
                resetsAt: Self.parseDate(balance.expireTime),
                resetDescription: nil)
            return NamedRateWindow(id: "kimi-monthly", title: "Monthly", window: window)
        }

        let identity = ProviderIdentitySnapshot(
            providerID: .kimi,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: nil)

        return UsageSnapshot(
            primary: weeklyWindow,
            secondary: rateLimitWindow,
            tertiary: nil,
            extraRateWindows: monthlyWindow.map { [$0] },
            providerCost: nil,
            updatedAt: self.updatedAt,
            identity: identity)
    }
}
