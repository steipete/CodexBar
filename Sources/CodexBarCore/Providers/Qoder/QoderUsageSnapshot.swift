import Foundation

public struct QoderUsageSnapshot: Sendable {
    public let usedCredits: Double
    public let totalCredits: Double
    public let remainingCredits: Double
    public let usagePercentage: Double
    public let unit: String?
    public let resetsAt: Date?
    public let updatedAt: Date

    public init(
        usedCredits: Double,
        totalCredits: Double,
        remainingCredits: Double,
        usagePercentage: Double,
        unit: String?,
        resetsAt: Date? = nil,
        updatedAt: Date = Date())
    {
        self.usedCredits = usedCredits
        self.totalCredits = totalCredits
        self.remainingCredits = remainingCredits
        self.usagePercentage = usagePercentage
        self.unit = unit
        self.resetsAt = resetsAt
        self.updatedAt = updatedAt
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        let creditSummary = "\(Self.formatCredits(self.usedCredits)) / \(Self.formatCredits(self.totalCredits)) credits"
        let primary = RateWindow(
            usedPercent: min(100, max(0, self.usagePercentage)),
            windowMinutes: nil,
            resetsAt: self.resetsAt,
            resetDescription: creditSummary)

        let identity = ProviderIdentitySnapshot(
            providerID: .qoder,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: nil)

        return UsageSnapshot(
            primary: primary,
            secondary: nil,
            tertiary: nil,
            providerCost: nil,
            updatedAt: self.updatedAt,
            identity: identity)
    }

    private static func formatCredits(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        formatter.maximumFractionDigits = value.rounded() == value ? 0 : 2
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}
