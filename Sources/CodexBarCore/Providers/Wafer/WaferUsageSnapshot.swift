import Foundation

public struct WaferUsageSnapshot: Sendable {
    public let isAvailable: Bool
    public let updatedAt: Date

    public init(
        isAvailable: Bool,
        updatedAt: Date)
    {
        self.isAvailable = isAvailable
        self.updatedAt = updatedAt
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        let usedPercent: Double = self.isAvailable ? 0 : 100
        let statusText = self.isAvailable ? "Subscription Active" : "Inactive / Limit Exceeded"

        let identity = ProviderIdentitySnapshot(
            providerID: .wafer,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: "Wafer Pass")

        let primaryWindow = RateWindow(
            usedPercent: usedPercent,
            windowMinutes: 300, // 5 hours
            resetsAt: nil,
            resetDescription: statusText)

        return UsageSnapshot(
            primary: primaryWindow,
            secondary: nil,
            tertiary: nil,
            providerCost: nil,
            updatedAt: self.updatedAt,
            identity: identity)
    }
}
