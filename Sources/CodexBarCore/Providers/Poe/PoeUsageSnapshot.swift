import Foundation

public struct PoeUsageSnapshot: Sendable {
    public let currentPointBalance: Double?
    public let updatedAt: Date

    public init(
        currentPointBalance: Double? = nil,
        updatedAt: Date = Date())
    {
        self.currentPointBalance = currentPointBalance
        self.updatedAt = updatedAt
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        let identity = ProviderIdentitySnapshot(
            providerID: .poe,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: self.balanceLabel)

        return UsageSnapshot(
            primary: nil,
            secondary: nil,
            tertiary: nil,
            providerCost: nil,
            updatedAt: self.updatedAt,
            identity: identity)
    }

    private var balanceLabel: String? {
        guard let balance = self.currentPointBalance, balance.isFinite else { return nil }
        return "Balance: \(Self.compactNumber(balance)) points"
    }

    static func compactNumber(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        formatter.maximumFractionDigits = value >= 1000 ? 0 : 1
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.0f", value)
    }
}
