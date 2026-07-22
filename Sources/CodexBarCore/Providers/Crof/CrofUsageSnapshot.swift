import Foundation

public struct CrofUsageSnapshot: Sendable {
    public let credits: Double
    public let updatedAt: Date

    public init(
        credits: Double,
        updatedAt: Date = Date())
    {
        self.credits = credits
        self.updatedAt = updatedAt
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        let creditsDetail = Self.formatCredits(self.credits)
        // Crof is PAYG-only: the API returns a balance with no credit cap, so the bar
        // only indicates present vs. exhausted credits.
        let primary = RateWindow(
            usedPercent: self.credits > 0 ? 0 : 100,
            windowMinutes: nil,
            resetsAt: nil,
            resetDescription: creditsDetail)

        return UsageSnapshot(
            primary: primary,
            secondary: nil,
            providerCost: nil,
            updatedAt: self.updatedAt,
            identity: ProviderIdentitySnapshot(
                providerID: .crof,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: "API key"))
    }

    private static func formatCredits(_ value: Double) -> String {
        let clamped = max(0, value)
        let cents = floor(clamped * 100) / 100
        return String(format: "$%.2f", cents)
    }
}
