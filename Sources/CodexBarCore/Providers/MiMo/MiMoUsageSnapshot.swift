import Foundation

public struct MiMoUsageSnapshot: Sendable {
    public let balance: Double
    public let currency: String
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
    public func toUsageSnapshot() -> UsageSnapshot {
        let trimmedCurrency = self.currency.trimmingCharacters(in: .whitespacesAndNewlines)
        let balanceText = UsageFormatter.currencyString(self.balance, currencyCode: trimmedCurrency)

        let primary: RateWindow? = {
            guard self.tokenLimit > 0 else { return nil }
            let usedPercent = max(0, min(100, self.tokenPercent * 100))
            let usedText = Self.fullCountString(self.tokenUsed)
            let limitText = Self.fullCountString(self.tokenLimit)
            let resetDesc = "\(usedText) / \(limitText) Credits"
            let windowMinutes: Int? = {
                guard let periodEnd = self.planPeriodEnd else { return nil }
                let timeUntilReset = periodEnd.timeIntervalSince(self.updatedAt)
                guard timeUntilReset > 0 else { return nil }
                // The reset date marks the end of the billing cycle, so the cycle
                // started one month before.  This correctly handles mid-month
                // subscriptions (e.g. reset June 15 → started May 15 → 31 days)
                // and February resets (28/29 days).
                let calendar = Calendar.current
                guard let cycleStart = calendar.date(byAdding: .month, value: -1, to: periodEnd) else { return nil }
                let windowLength = periodEnd.timeIntervalSince(cycleStart)
                guard windowLength > 0 else { return nil }
                return Int(windowLength / 60)
            }()
            return RateWindow(
                usedPercent: usedPercent,
                windowMinutes: windowMinutes,
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
            loginMethod: planLabel ?? "Balance: \(balanceText)")

        return UsageSnapshot(
            primary: primary,
            secondary: nil,
            tertiary: nil,
            providerCost: nil,
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
