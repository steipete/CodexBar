import Foundation

// MARK: - Abacus Usage Snapshot

public struct AbacusUsageSnapshot: Sendable {
    public let creditsUsed: Double?
    public let creditsTotal: Double?
    public let resetsAt: Date?
    public let planName: String?

    public init(
        creditsUsed: Double? = nil,
        creditsTotal: Double? = nil,
        resetsAt: Date? = nil,
        planName: String? = nil)
    {
        self.creditsUsed = creditsUsed
        self.creditsTotal = creditsTotal
        self.resetsAt = resetsAt
        self.planName = planName
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        let percentUsed: Double = if let used = self.creditsUsed, let total = self.creditsTotal, total > 0 {
            (used / total) * 100.0
        } else {
            0
        }

        let resetDesc: String? = if let used = self.creditsUsed, let total = self.creditsTotal {
            "\(Self.formatCredits(used)) / \(Self.formatCredits(total)) credits"
        } else {
            nil
        }

        // Derive window from actual billing cycle when possible.
        // Assume the cycle started one calendar month before resetsAt.
        let windowMinutes: Int = if let resetDate = self.resetsAt,
                                    let cycleStart = Calendar.current.date(byAdding: .month, value: -1, to: resetDate)
        {
            max(1, Int(resetDate.timeIntervalSince(cycleStart) / 60))
        } else {
            30 * 24 * 60
        }

        let primary = RateWindow(
            usedPercent: percentUsed,
            windowMinutes: windowMinutes,
            resetsAt: self.resetsAt,
            resetDescription: resetDesc)

        let identity = ProviderIdentitySnapshot(
            providerID: .abacus,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: self.planName)

        return UsageSnapshot(
            primary: primary,
            secondary: nil,
            tertiary: nil,
            providerCost: nil,
            updatedAt: Date(),
            identity: identity)
    }

    // MARK: - Formatting

    /// Thread-safe credit formatting — allocates per call to avoid shared mutable state.
    private static func formatCredits(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        formatter.maximumFractionDigits = value >= 1000 ? 0 : 1
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.0f", value)
    }
}
