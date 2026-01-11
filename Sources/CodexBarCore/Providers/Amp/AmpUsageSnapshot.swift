import Foundation

public struct AmpUsageSnapshot: Sendable {
    public let freeQuota: Double
    public let freeUsed: Double
    public let hourlyReplenishment: Double
    public let windowHours: Double?
    public let updatedAt: Date

    public init(
        freeQuota: Double,
        freeUsed: Double,
        hourlyReplenishment: Double,
        windowHours: Double?,
        updatedAt: Date)
    {
        self.freeQuota = freeQuota
        self.freeUsed = freeUsed
        self.hourlyReplenishment = hourlyReplenishment
        self.windowHours = windowHours
        self.updatedAt = updatedAt
    }
}

extension AmpUsageSnapshot {
    public func toUsageSnapshot(now: Date = Date()) -> UsageSnapshot {
        let quota = max(0, self.freeQuota)
        let used = max(0, self.freeUsed)
        let percent: Double = if quota > 0 {
            min(100, (used / quota) * 100)
        } else {
            0
        }

        let windowMinutes: Int? = if let hours = self.windowHours, hours > 0 {
            Int((hours * 60).rounded())
        } else {
            nil
        }

        let resetsAt: Date? = {
            guard quota > 0, self.hourlyReplenishment > 0 else { return nil }
            let hoursToFull = used / self.hourlyReplenishment
            let seconds = max(0, hoursToFull * 3600)
            return now.addingTimeInterval(seconds)
        }()

        let primary = RateWindow(
            usedPercent: percent,
            windowMinutes: windowMinutes,
            resetsAt: resetsAt,
            resetDescription: nil)

        let identity = ProviderIdentitySnapshot(
            providerID: .amp,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: "Amp Free")

        return UsageSnapshot(
            primary: primary,
            secondary: nil,
            tertiary: nil,
            providerCost: nil,
            updatedAt: self.updatedAt,
            identity: identity)
    }
}
