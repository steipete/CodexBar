import Foundation

public struct PoeBalanceResponse: Decodable, Sendable {
    public let currentPointBalance: Int

    private enum CodingKeys: String, CodingKey {
        case currentPointBalance = "current_point_balance"
    }
}

public struct PoeUsageSnapshot: Sendable {
    public let pointBalance: Int
    public let updatedAt: Date

    public init(pointBalance: Int, updatedAt: Date) {
        self.pointBalance = pointBalance
        self.updatedAt = updatedAt
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        let formatted = Self.formatPoints(self.pointBalance)

        let rateWindow = RateWindow(
            usedPercent: 0,
            windowMinutes: nil,
            resetsAt: nil,
            resetDescription: formatted)

        let identity = ProviderIdentitySnapshot(
            providerID: .poe,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: nil)

        return UsageSnapshot(
            primary: rateWindow,
            secondary: nil,
            tertiary: nil,
            providerCost: nil,
            updatedAt: self.updatedAt,
            identity: identity)
    }

    static func formatPoints(_ points: Int) -> String {
        switch points {
        case 1_000_000_000...:
            return String(format: "%.1fB pts", Double(points) / 1_000_000_000)
        case 1_000_000...:
            return String(format: "%.1fM pts", Double(points) / 1_000_000)
        case 1_000...:
            return String(format: "%.1fK pts", Double(points) / 1_000)
        default:
            return "\(points) pts"
        }
    }
}
