import Foundation

public struct KimiUsageSnapshot: Sendable {
    public let weekly: KimiUsageDetail
    public let rateLimit: KimiUsageDetail?
    public let updatedAt: Date

    public init(weekly: KimiUsageDetail, rateLimit: KimiUsageDetail?, updatedAt: Date) {
        self.weekly = weekly
        self.rateLimit = rateLimit
        self.updatedAt = updatedAt
    }

    private static func parseDate(_ dateString: String) -> Date? {
        // Handle ISO 8601 format like: 2026-01-09T15:23:13.716839300Z
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

        let weeklyPercent = weeklyLimit > 0 ? Double(weeklyUsed) / Double(weeklyLimit) * 100 : 0

        let weeklyWindow = RateWindow(
            usedPercent: weeklyPercent,
            windowMinutes: nil, // Weekly doesn't have a fixed window like rate limit
            resetsAt: Self.parseDate(self.weekly.resetTime),
            resetDescription: "\(weeklyUsed)/\(weeklyLimit) requests")

        // Parse rate limit if available
        var rateLimitWindow: RateWindow?
        if let rateLimit = self.rateLimit {
            let rateLimitValue = Int(rateLimit.limit) ?? 0
            let rateRemaining = Int(rateLimit.remaining ?? "")
            let rateUsed = Int(rateLimit.used ?? "") ?? {
                guard let remaining = rateRemaining else { return 0 }
                return max(0, rateLimitValue - remaining)
            }()
            let ratePercent = rateLimitValue > 0 ? Double(rateUsed) / Double(rateLimitValue) * 100 : 0

            rateLimitWindow = RateWindow(
                usedPercent: ratePercent,
                windowMinutes: 300, // 300 minutes = 5 hours
                resetsAt: Self.parseDate(rateLimit.resetTime),
                resetDescription: "Rate: \(rateUsed)/\(rateLimitValue) per 5 hours")
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
            providerCost: nil,
            updatedAt: self.updatedAt,
            identity: identity)
    }
}
