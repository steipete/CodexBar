import Foundation

public struct MiMoUsageSnapshot: Sendable {
    public let balance: Double
    public let currency: String
    public let updatedAt: Date

    public init(balance: Double, currency: String, updatedAt: Date) {
        self.balance = balance
        self.currency = currency
        self.updatedAt = updatedAt
    }
}

extension MiMoUsageSnapshot {
    public func toUsageSnapshot() -> UsageSnapshot {
        let trimmedCurrency = self.currency.trimmingCharacters(in: .whitespacesAndNewlines)
        let balanceText = UsageFormatter.currencyString(self.balance, currencyCode: trimmedCurrency)
        let identity = ProviderIdentitySnapshot(
            providerID: .mimo,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: "Balance: \(balanceText)")

        return UsageSnapshot(
            primary: nil,
            secondary: nil,
            tertiary: nil,
            providerCost: nil,
            updatedAt: self.updatedAt,
            identity: identity)
    }
}
