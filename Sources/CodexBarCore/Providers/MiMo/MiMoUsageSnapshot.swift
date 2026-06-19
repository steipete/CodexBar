import Foundation

public struct MiMoUsageSnapshot: Codable, Sendable {
    public let balance: Double
    public let currency: String
    public let cashBalance: Double?
    public let giftBalance: Double?
    public let planCode: String?
    public let planPeriodEnd: Date?
    public let planExpired: Bool
    public let tokenUsed: Int
    public let tokenLimit: Int
    public let tokenPercent: Double
    public let updatedAt: Date

    public init(
        balance: Double,
        currency: String,
        cashBalance: Double? = nil,
        giftBalance: Double? = nil,
        planCode: String? = nil,
        planPeriodEnd: Date? = nil,
        planExpired: Bool = false,
        tokenUsed: Int = 0,
        tokenLimit: Int = 0,
        tokenPercent: Double = 0,
        updatedAt: Date)
    {
        self.balance = balance
        self.currency = currency
        self.cashBalance = cashBalance
        self.giftBalance = giftBalance
        self.planCode = planCode
        self.planPeriodEnd = planPeriodEnd
        self.planExpired = planExpired
        self.tokenUsed = tokenUsed
        self.tokenLimit = tokenLimit
        self.tokenPercent = tokenPercent
        self.updatedAt = updatedAt
    }
}

extension MiMoUsageSnapshot {
    public var balanceDetail: String {
        let trimmedCurrency = self.currency.trimmingCharacters(in: .whitespacesAndNewlines)
        let balanceText = UsageFormatter.currencyString(self.balance, currencyCode: trimmedCurrency)
        guard let cashBalance = self.cashBalance, let giftBalance = self.giftBalance else {
            return balanceText
        }
        let paid = UsageFormatter.currencyString(cashBalance, currencyCode: trimmedCurrency)
        let granted = UsageFormatter.currencyString(giftBalance, currencyCode: trimmedCurrency)
        return "\(balanceText) (Paid: \(paid) / Granted: \(granted))"
    }

    public func toUsageSnapshot(includeBalance: Bool = true) -> UsageSnapshot {
        let tokenWindow: RateWindow? = {
            guard self.tokenLimit > 0 else { return nil }
            let usedPercent = max(0, min(100, self.tokenPercent * 100))
            let usedText = Self.fullCountString(self.tokenUsed)
            let limitText = Self.fullCountString(self.tokenLimit)
            let resetDesc = "\(usedText) / \(limitText) Credits"
            return RateWindow(
                usedPercent: usedPercent,
                windowMinutes: nil,
                resetsAt: self.planPeriodEnd,
                resetDescription: resetDesc)
        }()

        let planLabel: String? = {
            guard let planCode = self.planCode else { return nil }
            return planCode.capitalized
        }()

        let identity = ProviderIdentitySnapshot(
            providerID: .mimo,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: planLabel)

        return UsageSnapshot(
            primary: tokenWindow,
            secondary: nil,
            tertiary: nil,
            mimoUsage: includeBalance ? self : nil,
            updatedAt: self.updatedAt,
            identity: identity)
    }

    private static func fullCountString(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}
