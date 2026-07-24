import Foundation

public struct AmpWorkspaceBalance: Codable, Equatable, Sendable {
    public let name: String
    public let remaining: Double

    public init(name: String, remaining: Double) {
        self.name = name
        self.remaining = remaining
    }
}

public struct AmpUsageDetails: Codable, Equatable, Sendable {
    public let individualCredits: Double?
    public let workspaceBalances: [AmpWorkspaceBalance]
    public let subscriptionPlan: String?

    public init(
        individualCredits: Double?,
        workspaceBalances: [AmpWorkspaceBalance],
        subscriptionPlan: String? = nil)
    {
        self.individualCredits = individualCredits
        self.workspaceBalances = workspaceBalances
        self.subscriptionPlan = subscriptionPlan
    }
}

public struct AmpSubscriptionUsage: Equatable, Sendable {
    public let plan: String
    public let otherUsedPercent: Double
    public let orbUsedPercent: Double
    public let resetsAt: Date
    public let resetDescription: String

    public init(
        plan: String,
        otherUsedPercent: Double,
        orbUsedPercent: Double,
        resetsAt: Date,
        resetDescription: String)
    {
        self.plan = plan
        self.otherUsedPercent = otherUsedPercent
        self.orbUsedPercent = orbUsedPercent
        self.resetsAt = resetsAt
        self.resetDescription = resetDescription
    }
}

public struct AmpUsageSnapshot: Sendable {
    public let freeQuota: Double?
    public let freeUsed: Double?
    public let hourlyReplenishment: Double?
    public let windowHours: Double?
    public let individualCredits: Double?
    public let workspaceBalances: [AmpWorkspaceBalance]
    public let accountEmail: String?
    public let accountOrganization: String?
    public let updatedAt: Date
    public let freeResetDescription: String?
    public let subscription: AmpSubscriptionUsage?

    public init(
        freeQuota: Double?,
        freeUsed: Double?,
        hourlyReplenishment: Double?,
        windowHours: Double?,
        individualCredits: Double? = nil,
        workspaceBalances: [AmpWorkspaceBalance] = [],
        accountEmail: String? = nil,
        accountOrganization: String? = nil,
        updatedAt: Date,
        freeResetDescription: String? = nil,
        subscription: AmpSubscriptionUsage? = nil)
    {
        self.freeQuota = freeQuota
        self.freeUsed = freeUsed
        self.hourlyReplenishment = hourlyReplenishment
        self.windowHours = windowHours
        self.individualCredits = individualCredits
        self.workspaceBalances = workspaceBalances
        self.accountEmail = accountEmail
        self.accountOrganization = accountOrganization
        self.updatedAt = updatedAt
        self.freeResetDescription = freeResetDescription
        self.subscription = subscription
    }
}

extension AmpUsageSnapshot {
    public func toUsageSnapshot(now: Date = Date()) -> UsageSnapshot {
        let freeWindow: RateWindow? = if let freeQuota, let freeUsed {
            {
                let quota = max(0, freeQuota)
                let used = max(0, freeUsed)
                let percent = quota > 0 ? min(100, (used / quota) * 100) : 0
                let windowMinutes: Int? = if let hours = self.windowHours, hours > 0 {
                    Int((hours * 60).rounded())
                } else {
                    nil
                }
                let resetsAt: Date? = {
                    guard quota > 0, let hourlyReplenishment, hourlyReplenishment > 0 else { return nil }
                    return now.addingTimeInterval(max(0, used / hourlyReplenishment * 3600))
                }()
                return RateWindow(
                    usedPercent: percent,
                    windowMinutes: windowMinutes,
                    resetsAt: resetsAt,
                    resetDescription: self.freeResetDescription)
            }()
        } else {
            nil
        }

        let subscriptionPrimary = self.subscription.map { usage in
            RateWindow(
                usedPercent: usage.otherUsedPercent,
                windowMinutes: ProviderPaceCapability.monthlyWindowSentinelMinutes,
                resetsAt: usage.resetsAt,
                resetDescription: usage.resetDescription)
        }
        let subscriptionSecondary = self.subscription.map { usage in
            RateWindow(
                usedPercent: usage.orbUsedPercent,
                windowMinutes: ProviderPaceCapability.monthlyWindowSentinelMinutes,
                resetsAt: usage.resetsAt,
                resetDescription: usage.resetDescription)
        }
        let primary = subscriptionPrimary ?? freeWindow

        let identity = ProviderIdentitySnapshot(
            providerID: .amp,
            accountEmail: self.accountEmail,
            accountOrganization: self.accountOrganization,
            loginMethod: self.subscription?.plan ?? (primary == nil ? "Amp" : "Amp Free"))

        let ampUsage: AmpUsageDetails? = if self.individualCredits != nil || !self.workspaceBalances.isEmpty ||
            self.subscription != nil
        {
            AmpUsageDetails(
                individualCredits: self.individualCredits,
                workspaceBalances: self.workspaceBalances,
                subscriptionPlan: self.subscription?.plan)
        } else {
            nil
        }

        return UsageSnapshot(
            primary: primary,
            secondary: subscriptionSecondary,
            tertiary: nil,
            ampUsage: ampUsage,
            providerCost: nil,
            updatedAt: self.updatedAt,
            identity: identity)
    }
}
