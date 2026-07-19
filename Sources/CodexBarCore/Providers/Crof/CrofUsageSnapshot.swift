import Foundation

public struct CrofUsageSnapshot: Sendable {
    private static let requestWindowMinutes = 24 * 60
    private static let resetTimeZone = TimeZone(identifier: "America/Chicago") ?? TimeZone(secondsFromGMT: -5)!

    public let credits: Double
    public let requestsPlan: Double
    public let usableRequests: Double
    public let updatedAt: Date

    public init(
        credits: Double,
        requestsPlan: Double,
        usableRequests: Double,
        updatedAt: Date = Date())
    {
        self.credits = credits
        self.requestsPlan = requestsPlan
        self.usableRequests = usableRequests
        self.updatedAt = updatedAt
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        let usedPercent: Double
        if self.requestsPlan > 0 {
            let usableRequests = max(0, min(self.requestsPlan, self.usableRequests))
            let remainingPercent = floor(usableRequests / self.requestsPlan * 100).clamped(to: 0...100)
            usedPercent = 100 - remainingPercent
        } else {
            usedPercent = 100
        }

        let primary = RateWindow(
            usedPercent: usedPercent,
            windowMinutes: Self.requestWindowMinutes,
            resetsAt: Self.nextRequestReset(after: self.updatedAt),
            resetDescription: Self.formatRequestsLeft(self.usableRequests))

        let creditsDetail = Self.formatCredits(self.credits)
        let secondary = RateWindow(
            // Crof returns a balance but no credit cap, so the bar only indicates present vs. exhausted credits.
            usedPercent: self.credits > 0 ? 0 : 100,
            windowMinutes: nil,
            resetsAt: nil,
            resetDescription: creditsDetail)

        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            providerCost: nil,
            updatedAt: self.updatedAt,
            identity: ProviderIdentitySnapshot(
                providerID: .crof,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: "API key"))
    }

    private static func formatCredits(_ value: Double) -> String {
        let clamped = max(0, value)
        let cents = floor(clamped * 100) / 100
        return String(format: "$%.2f", cents)
    }

    private static func formatRequestsLeft(_ value: Double) -> String {
        let clamped = max(0, value)
        let formatted = clamped.rounded() == clamped
            ? String(format: "%.0f", clamped)
            : String(format: "%.2f", clamped)
        return "\(formatted) requests left"
    }

    private static func nextRequestReset(after date: Date) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.resetTimeZone

        let startOfDay = calendar.startOfDay(for: date)
        return startOfDay <= date
            ? calendar.date(byAdding: .day, value: 1, to: startOfDay)
            : startOfDay
    }
}
