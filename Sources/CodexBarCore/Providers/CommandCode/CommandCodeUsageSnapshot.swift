import Foundation

/// Parsed view of Command Code billing credits, rolling limits, and subscription state.
public struct CommandCodeUsageSnapshot: Sendable {
    /// USD remaining in the current monthly grant (`credits.monthlyCredits`).
    public let monthlyCreditsRemaining: Double
    /// USD top-up balance carried over (`credits.purchasedCredits`).
    public let purchasedCredits: Double
    /// USD remaining in the premium monthly grant (`credits.premiumMonthlyCredits`).
    public let premiumMonthlyCredits: Double
    /// USD remaining in the open-source monthly grant (`credits.opensourceMonthlyCredits`).
    public let opensourceMonthlyCredits: Double
    /// Rolling five-hour usage limit reported by the credits response.
    public let fiveHourWindow: RateWindow?
    /// Rolling weekly usage limit reported by the credits response.
    public let weeklyWindow: RateWindow?
    /// Subscription plan, or nil when the user is on the free tier.
    public let plan: CommandCodePlanCatalog.Plan?
    /// `currentPeriodEnd` from the active subscription.
    public let billingPeriodEnd: Date?
    /// Subscription status (e.g. `active`, `canceled`).
    public let subscriptionStatus: String?
    /// The optional subscription request timed out or failed for this refresh.
    public let subscriptionEnrichmentUnavailable: Bool
    public let updatedAt: Date

    public init(
        monthlyCreditsRemaining: Double,
        purchasedCredits: Double,
        premiumMonthlyCredits: Double,
        opensourceMonthlyCredits: Double,
        fiveHourWindow: RateWindow? = nil,
        weeklyWindow: RateWindow? = nil,
        plan: CommandCodePlanCatalog.Plan?,
        billingPeriodEnd: Date?,
        subscriptionStatus: String?,
        subscriptionEnrichmentUnavailable: Bool = false,
        updatedAt: Date = Date())
    {
        self.monthlyCreditsRemaining = monthlyCreditsRemaining
        self.purchasedCredits = purchasedCredits
        self.premiumMonthlyCredits = premiumMonthlyCredits
        self.opensourceMonthlyCredits = opensourceMonthlyCredits
        self.fiveHourWindow = fiveHourWindow
        self.weeklyWindow = weeklyWindow
        self.plan = plan
        self.billingPeriodEnd = billingPeriodEnd
        self.subscriptionStatus = subscriptionStatus
        self.subscriptionEnrichmentUnavailable = subscriptionEnrichmentUnavailable
        self.updatedAt = updatedAt
    }

    /// USD allocation for the active monthly grant (from the catalog).
    public var monthlyCreditsTotal: Double? {
        self.plan?.monthlyCreditsUSD
    }

    /// USD spent in the current monthly grant (total – remaining), clamped to [0, total].
    public var monthlyCreditsUsed: Double? {
        guard let total = self.monthlyCreditsTotal else { return nil }
        return max(0, min(total, total - self.monthlyCreditsRemaining))
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        let monthly = self.makeMonthlyWindow()

        let identity = ProviderIdentitySnapshot(
            providerID: .commandcode,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: self.makeLoginMethod())

        return UsageSnapshot(
            primary: self.fiveHourWindow,
            secondary: self.weeklyWindow,
            tertiary: monthly,
            providerCost: nil,
            commandCodeSubscriptionEnrichmentUnavailable: self.subscriptionEnrichmentUnavailable,
            commandCodeHasSubscriptionPlan: self.plan != nil,
            commandCodeMonthlyGrantDepleted: self.monthlyCreditsRemaining <= 0,
            updatedAt: self.updatedAt,
            identity: identity)
    }

    private func makeMonthlyWindow() -> RateWindow? {
        guard let total = self.monthlyCreditsTotal, total > 0 else {
            // Free / unknown plan with no allowance — surface 100% so the bar renders empty.
            if self.monthlyCreditsRemaining > 0 || self.purchasedCredits > 0 {
                return RateWindow(
                    usedPercent: 0,
                    windowMinutes: ProviderPaceCapability.monthlyWindowSentinelMinutes,
                    resetsAt: self.billingPeriodEnd,
                    resetDescription: nil)
            }
            return nil
        }
        let used = self.monthlyCreditsUsed ?? 0
        let percent = UsagePercent(used: used, limit: total).displayClamped
        return RateWindow(
            usedPercent: percent,
            windowMinutes: ProviderPaceCapability.monthlyWindowSentinelMinutes,
            resetsAt: self.billingPeriodEnd,
            resetDescription: nil)
    }

    private func makeLoginMethod() -> String? {
        var parts: [String] = []
        if let name = self.plan?.displayName, !name.isEmpty {
            parts.append(name)
        }
        if let total = self.monthlyCreditsTotal {
            let used = self.monthlyCreditsUsed ?? 0
            parts.append("\(Self.formatUSD(used)) of \(Self.formatUSD(total))")
        } else if self.monthlyCreditsRemaining > 0 {
            parts.append("\(Self.formatUSD(self.monthlyCreditsRemaining)) remaining")
        }
        if self.purchasedCredits > 0 {
            parts.append("+ \(Self.formatUSD(self.purchasedCredits)) credits")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func formatUSD(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.locale = Locale(identifier: "en_US")
        formatter.maximumFractionDigits = value < 100 ? 2 : 0
        formatter.minimumFractionDigits = value < 100 ? 2 : 0
        return formatter.string(from: NSNumber(value: value)) ?? "$\(value)"
    }
}
