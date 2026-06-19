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

    public init(individualCredits: Double?, workspaceBalances: [AmpWorkspaceBalance]) {
        self.individualCredits = individualCredits
        self.workspaceBalances = workspaceBalances
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

    public init(
        freeQuota: Double?,
        freeUsed: Double?,
        hourlyReplenishment: Double?,
        windowHours: Double?,
        individualCredits: Double? = nil,
        workspaceBalances: [AmpWorkspaceBalance] = [],
        accountEmail: String? = nil,
        accountOrganization: String? = nil,
        updatedAt: Date)
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
    }
}

extension AmpUsageSnapshot {
    public func toUsageSnapshot(now: Date = Date()) -> UsageSnapshot {
        let primary: RateWindow? = if let freeQuota, let freeUsed {
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
                    resetDescription: nil)
            }()
        } else {
            nil
        }

        let identity = ProviderIdentitySnapshot(
            providerID: .amp,
            accountEmail: self.accountEmail,
            accountOrganization: self.accountOrganization,
            loginMethod: primary == nil ? "Amp" : "Amp Free")

        let ampUsage: AmpUsageDetails? = if self.individualCredits != nil || !self.workspaceBalances.isEmpty {
            AmpUsageDetails(
                individualCredits: self.individualCredits,
                workspaceBalances: self.workspaceBalances)
        } else {
            nil
        }

        return UsageSnapshot(
            primary: primary,
            secondary: nil,
            tertiary: nil,
            ampUsage: ampUsage,
            providerCost: nil,
            updatedAt: self.updatedAt,
            identity: identity)
    }
}
