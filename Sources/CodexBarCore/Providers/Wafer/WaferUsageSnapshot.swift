import Foundation

public struct WaferUsageSnapshot: Sendable {
    public let limit: Int
    public let count: Int
    public let remaining: Int
    public let secondsToReset: Int
    public let usedPercent: Double
    public let windowMinutes: Int
    public let updatedAt: Date

    public init(
        limit: Int,
        count: Int,
        remaining: Int,
        secondsToReset: Int,
        usedPercent: Double,
        windowMinutes: Int,
        updatedAt: Date)
    {
        self.limit = limit
        self.count = count
        self.remaining = remaining
        self.secondsToReset = secondsToReset
        self.usedPercent = usedPercent
        self.windowMinutes = windowMinutes
        self.updatedAt = updatedAt
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        let resetsAt = self.updatedAt.addingTimeInterval(TimeInterval(self.secondsToReset))
        let resetDescription = "\(self.count)/\(self.limit) requests"

        let identity = ProviderIdentitySnapshot(
            providerID: .wafer,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: "Wafer Pass")

        let primaryWindow = RateWindow(
            usedPercent: self.usedPercent,
            windowMinutes: self.windowMinutes,
            resetsAt: resetsAt,
            resetDescription: resetDescription)

        return UsageSnapshot(
            primary: primaryWindow,
            secondary: nil,
            tertiary: nil,
            providerCost: nil,
            updatedAt: self.updatedAt,
            identity: identity)
    }
}
