import Foundation

public struct TraeCNUsageSnapshot: Codable, Sendable {
    public let creditsUsed: Double
    public let creditsLimit: Double
    public let creditsRemaining: Double?
    public let planCode: String?
    public let planPeriodEnd: Date?
    public let updatedAt: Date

    public init(
        creditsUsed: Double,
        creditsLimit: Double,
        creditsRemaining: Double? = nil,
        planCode: String? = nil,
        planPeriodEnd: Date? = nil,
        updatedAt: Date)
    {
        self.creditsUsed = creditsUsed
        self.creditsLimit = creditsLimit
        self.creditsRemaining = creditsRemaining
        self.planCode = planCode
        self.planPeriodEnd = planPeriodEnd
        self.updatedAt = updatedAt
    }
}

extension TraeCNUsageSnapshot {
    public func toUsageSnapshot() -> UsageSnapshot {
        let creditsWindow: RateWindow? = {
            guard self.creditsLimit > 0 else { return nil }
            let usedPercent = max(0, min(100, self.creditsUsed / self.creditsLimit * 100))
            let usedText = Self.countString(self.creditsUsed)
            let limitText = Self.countString(self.creditsLimit)
            let resetDesc = "\(usedText) / \(limitText) Credits"
            // Populate windowMinutes so the plan-utilization history + pace forecast engine
            // treats the monthly plan quota like the Codex/Claude windows. Only when there's
            // a real period end to reset against.
            let windowMinutes = self.planPeriodEnd == nil
                ? nil
                : ProviderPaceCapability.monthlyWindowSentinelMinutes
            return RateWindow(
                usedPercent: usedPercent,
                windowMinutes: windowMinutes,
                resetsAt: self.planPeriodEnd,
                resetDescription: resetDesc)
        }()

        let identity = ProviderIdentitySnapshot(
            providerID: .traecn,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: self.planCode)

        let details: [ProviderDetailSection] = if let remaining = self.creditsRemaining {
            [.makeSection(title: "Credits", rows: [
                .makeRow(label: "Remaining", value: Self.countString(remaining)),
            ])]
        } else {
            []
        }

        return UsageSnapshot(
            primary: creditsWindow,
            secondary: nil,
            tertiary: nil,
            details: details,
            updatedAt: self.updatedAt,
            identity: identity)
    }

    private static func countString(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.maximumFractionDigits = value.truncatingRemainder(dividingBy: 1) == 0 ? 0 : 2
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}
