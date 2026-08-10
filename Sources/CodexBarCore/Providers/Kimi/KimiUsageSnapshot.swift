import Foundation

public struct KimiUsageSnapshot: Sendable {
    public let weekly: KimiUsageDetail
    public let rateLimit: KimiUsageDetail?
    public let updatedAt: Date
    let rateLimitWindow: KimiWindow?
    let subscriptionBalance: KimiSubscriptionBalance?
    let subscriptionCodeWeeklyLimit: KimiSubscriptionRateLimit?

    public init(weekly: KimiUsageDetail, rateLimit: KimiUsageDetail?, updatedAt: Date) {
        self.weekly = weekly
        self.rateLimit = rateLimit
        self.updatedAt = updatedAt
        self.rateLimitWindow = nil
        self.subscriptionBalance = nil
        self.subscriptionCodeWeeklyLimit = nil
    }

    init(
        weekly: KimiUsageDetail,
        rateLimit: KimiUsageDetail?,
        rateLimitWindow: KimiWindow? = nil,
        subscriptionBalance: KimiSubscriptionBalance?,
        subscriptionCodeWeeklyLimit: KimiSubscriptionRateLimit? = nil,
        updatedAt: Date)
    {
        self.weekly = weekly
        self.rateLimit = rateLimit
        self.rateLimitWindow = rateLimitWindow
        self.subscriptionBalance = subscriptionBalance
        self.subscriptionCodeWeeklyLimit = subscriptionCodeWeeklyLimit
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

    private static func usageCounts(_ detail: KimiUsageDetail) -> (used: Int, limit: Int, isReliable: Bool)? {
        guard let limit = Int(detail.limit), limit > 0 else { return nil }

        // Used is authoritative and may exceed the limit during overage; remaining must describe a valid balance.
        if let rawUsed = detail.used,
           let used = Int(rawUsed),
           used >= 0
        {
            return (used, limit, true)
        }

        if let rawRemaining = detail.remaining,
           let remaining = Int(rawRemaining),
           (0...limit).contains(remaining)
        {
            return (limit - remaining, limit, true)
        }

        // Preserve the legacy 0% gauge for a valid limit, but withhold duration so invalid counters cannot create pace.
        return (0, limit, false)
    }

    private static func rateLimitDescription(used: Int, limit: Int, windowMinutes: Int?) -> String {
        guard let windowMinutes else { return "Rate: \(used)/\(limit)" }
        if windowMinutes.isMultiple(of: 60) {
            let hours = windowMinutes / 60
            return "Rate: \(used)/\(limit) per \(hours) \(hours == 1 ? "hour" : "hours")"
        }
        return "Rate: \(used)/\(limit) per \(windowMinutes) \(windowMinutes == 1 ? "minute" : "minutes")"
    }
}

extension KimiUsageSnapshot {
    public func toUsageSnapshot() -> UsageSnapshot {
        // Parse weekly quota
        // Both Kimi usage endpoints expose FEATURE_CODING usage.detail as the weekly quota.
        let weeklyWindow = Self.usageCounts(self.weekly).map { counts in
            RateWindow(
                usedPercent: Self.clampedPercent(Double(counts.used) / Double(counts.limit) * 100),
                windowMinutes: counts.isReliable ? KimiProviderDescriptor.weeklyWindowMinutes : nil,
                resetsAt: Self.parseDate(self.weekly.resetTime),
                resetDescription: "\(counts.used)/\(counts.limit) requests")
        }

        // Parse rate limit if available
        let rateLimitWindow = self.rateLimit.flatMap { rateLimit -> RateWindow? in
            guard let counts = Self.usageCounts(rateLimit) else { return nil }
            let apiWindowMinutes: Int? = if let apiWindow = self.rateLimitWindow {
                apiWindow.durationMinutes
            } else {
                KimiProviderDescriptor.sessionWindowMinutes
            }
            let windowMinutes = counts.isReliable ? apiWindowMinutes : nil
            return RateWindow(
                usedPercent: Self.clampedPercent(Double(counts.used) / Double(counts.limit) * 100),
                windowMinutes: windowMinutes,
                resetsAt: Self.parseDate(rateLimit.resetTime),
                resetDescription: Self.rateLimitDescription(
                    used: counts.used,
                    limit: counts.limit,
                    windowMinutes: windowMinutes))
        }

        let monthlyWindow = self.subscriptionBalance.flatMap { balance -> NamedRateWindow? in
            // Total usage = shared subscription pool (`amountUsedRatio`), not the Code-only
            // `kimiCodeUsedRatio`: the pool is shared across features, so amountUsedRatio is the
            // real "subscription remaining". Matches the official "Total usage" lane.
            guard balance.feature == nil || balance.feature == "FEATURE_OMNI" else { return nil }
            guard balance.type == nil || balance.type == "SUBSCRIPTION" else { return nil }
            guard let ratio = balance.amountUsedRatio, ratio.isFinite else { return nil }
            let window = RateWindow(
                usedPercent: Self.clampedPercent(ratio * 100),
                windowMinutes: ProviderPaceCapability.monthlyWindowSentinelMinutes,
                resetsAt: Self.parseDate(balance.expireTime),
                resetDescription: nil)
            return NamedRateWindow(id: "kimi-monthly", title: "Total usage", window: window)
        }

        let subscriptionCodeWeeklyWindow = self.subscriptionCodeWeeklyLimit.flatMap { limit -> NamedRateWindow? in
            guard limit.enabled != false else { return nil }
            guard let ratio = limit.ratio, ratio.isFinite else { return nil }
            let window = RateWindow(
                usedPercent: Self.clampedPercent(ratio * 100),
                windowMinutes: KimiProviderDescriptor.weeklyWindowMinutes,
                resetsAt: Self.parseDate(limit.resetTime),
                resetDescription: nil)
            return NamedRateWindow(id: "kimi-code-7d", title: "Code 7-day", window: window)
        }

        // The membership 7-day Code ratio and the FEATURE_CODING weekly detail report the same
        // underlying quota through two endpoints. When they agree, the extra row only duplicates
        // the primary lane, so keep it just for the cases where it genuinely diverges.
        let showsDistinctCodeWeeklyWindow = subscriptionCodeWeeklyWindow.map { codeWeekly in
            !Self.isEquivalentToWeeklyWindow(codeWeekly.window, weeklyWindow: weeklyWindow)
        } ?? false

        let extraRateWindows = [
            monthlyWindow,
            showsDistinctCodeWeeklyWindow ? subscriptionCodeWeeklyWindow : nil,
        ].compactMap(\.self)

        let identity = ProviderIdentitySnapshot(
            providerID: .kimi,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: nil)

        return UsageSnapshot(
            primary: weeklyWindow,
            secondary: rateLimitWindow,
            tertiary: nil,
            extraRateWindows: extraRateWindows.isEmpty ? nil : extraRateWindows,
            providerCost: nil,
            updatedAt: self.updatedAt,
            identity: identity)
    }

    private static func isEquivalentToWeeklyWindow(_ window: RateWindow, weeklyWindow: RateWindow?) -> Bool {
        // Suppress only on positive evidence: unreliable weekly counters deliberately withhold
        // windowMinutes, and two lanes without reset timestamps cannot be proven to be the same quota.
        guard let weeklyWindow, weeklyWindow.windowMinutes != nil else { return false }
        guard abs(window.usedPercent - weeklyWindow.usedPercent) <= 1 else { return false }
        guard let codeReset = window.resetsAt, let weeklyReset = weeklyWindow.resetsAt else { return false }
        return abs(codeReset.timeIntervalSince(weeklyReset)) <= 5 * 60
    }
}
