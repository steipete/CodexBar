import Foundation

public struct ReplicateUsageSummary: Sendable {
    public let currentMonthSpend: Double
    public let currencyCode: String
    public let creditBalance: Double?
    public let spendLimit: Double?
    public let username: String?
    public let updatedAt: Date

    public init(
        currentMonthSpend: Double,
        currencyCode: String,
        creditBalance: Double?,
        spendLimit: Double?,
        username: String?,
        updatedAt: Date)
    {
        self.currentMonthSpend = currentMonthSpend
        self.currencyCode = currencyCode
        self.creditBalance = creditBalance
        self.spendLimit = spendLimit
        self.username = username
        self.updatedAt = updatedAt
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        let spendText = Self.money(self.currentMonthSpend, code: self.currencyCode) + " spent this month"
        var parts = [spendText]
        if let balance = self.creditBalance {
            parts.append(Self.money(balance, code: self.currencyCode) + " credit")
        }
        if let limit = self.spendLimit {
            parts.append(Self.money(limit, code: self.currencyCode) + " limit")
        }
        let detail = parts.joined(separator: " · ")

        return UsageSnapshot(
            primary: RateWindow(
                usedPercent: 0,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: detail),
            secondary: nil,
            providerCost: ProviderCostSnapshot(
                used: self.currentMonthSpend,
                limit: 0,
                currencyCode: self.currencyCode,
                period: "This month",
                balance: self.creditBalance,
                updatedAt: self.updatedAt),
            updatedAt: self.updatedAt,
            identity: ProviderIdentitySnapshot(
                providerID: UsageProvider.replicate.instanceID,
                accountEmail: nil,
                accountOrganization: self.username,
                loginMethod: nil),
            dataConfidence: .exact)
    }

    private static func money(_ value: Double, code: String) -> String {
        if code.uppercased() == "USD" {
            return String(format: "$%.2f", value)
        }
        return String(format: "%.2f %@", value, code)
    }
}
