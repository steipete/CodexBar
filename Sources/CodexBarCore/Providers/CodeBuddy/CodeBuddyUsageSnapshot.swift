import Foundation

public struct CodeBuddyUsageSnapshot: Sendable {
    public let creditUsed: Double
    public let creditLimit: Double
    public let cycleStartTime: String
    public let cycleEndTime: String
    public let cycleResetTime: String
    public let updatedAt: Date

    public init(
        creditUsed: Double,
        creditLimit: Double,
        cycleStartTime: String,
        cycleEndTime: String,
        cycleResetTime: String,
        updatedAt: Date)
    {
        self.creditUsed = creditUsed
        self.creditLimit = creditLimit
        self.cycleStartTime = cycleStartTime
        self.cycleEndTime = cycleEndTime
        self.cycleResetTime = cycleResetTime
        self.updatedAt = updatedAt
    }

    private static func parseDate(_ dateString: String) -> Date? {
        // Handle format like: "2026-02-28 23:59:59"
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return formatter.date(from: dateString)
    }
}

extension CodeBuddyUsageSnapshot {
    public func toUsageSnapshot() -> UsageSnapshot {
        let usagePercent = self.creditLimit > 0 ? (self.creditUsed / self.creditLimit) * 100 : 0

        // Format credit values for display (e.g., "1,121 / 25,000")
        let usedInt = Int(self.creditUsed.rounded())
        let limitInt = Int(self.creditLimit.rounded())

        let creditWindow = RateWindow(
            usedPercent: usagePercent,
            windowMinutes: nil,
            resetsAt: Self.parseDate(self.cycleResetTime),
            resetDescription: "\(usedInt.formatted()) / \(limitInt.formatted()) credits")

        let identity = ProviderIdentitySnapshot(
            providerID: .codebuddy,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: nil)

        return UsageSnapshot(
            primary: creditWindow,
            secondary: nil,
            tertiary: nil,
            providerCost: nil,
            updatedAt: self.updatedAt,
            identity: identity)
    }
}
