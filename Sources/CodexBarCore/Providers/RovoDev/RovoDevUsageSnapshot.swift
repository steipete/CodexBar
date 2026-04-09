import Foundation

public struct RovoDevUsageSnapshot: Sendable {
    /// Credits consumed in the current billing cycle.
    public let currentUsage: Int
    /// Credit cap for the billing cycle (e.g. 6000).
    public let creditCap: Int
    /// Timestamp when the allowance resets.
    public let nextRefresh: Date?
    /// Active entitlement name (e.g. "ROVO_DEV_STANDARD_TRIAL").
    public let effectiveEntitlement: String?
    /// Atlassian account email, if resolved.
    public let accountEmail: String?
    public let updatedAt: Date

    public init(
        currentUsage: Int,
        creditCap: Int,
        nextRefresh: Date?,
        effectiveEntitlement: String?,
        accountEmail: String?,
        updatedAt: Date)
    {
        self.currentUsage = currentUsage
        self.creditCap = creditCap
        self.nextRefresh = nextRefresh
        self.effectiveEntitlement = effectiveEntitlement
        self.accountEmail = accountEmail
        self.updatedAt = updatedAt
    }
}

extension RovoDevUsageSnapshot {
    public func toUsageSnapshot() -> UsageSnapshot {
        let usedPercent: Double
        if self.creditCap > 0 {
            usedPercent = min(100, max(0, Double(self.currentUsage) / Double(self.creditCap) * 100))
        } else {
            usedPercent = 0
        }

        let window = RateWindow(
            usedPercent: usedPercent,
            windowMinutes: nil,
            resetsAt: self.nextRefresh,
            resetDescription: nil)

        let plan = self.effectiveEntitlement.flatMap { raw -> String? in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        let email = self.accountEmail.flatMap { raw -> String? in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        let identity = ProviderIdentitySnapshot(
            providerID: .rovodev,
            accountEmail: email,
            accountOrganization: nil,
            loginMethod: plan)

        return UsageSnapshot(
            primary: window,
            secondary: nil,
            tertiary: nil,
            providerCost: nil,
            updatedAt: self.updatedAt,
            identity: identity)
    }
}
