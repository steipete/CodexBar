import Foundation

public struct OllamaUsageSnapshot: Sendable {
    public let planName: String?
    public let accountEmail: String?
    public let monthlyUsedPercent: Double?
    public let monthlyResetsAt: Date?
    public let sessionUsedPercent: Double?
    public let weeklyUsedPercent: Double?
    public let sessionResetsAt: Date?
    public let weeklyResetsAt: Date?
    public let sessionWindowMinutes: Int?
    public let details: [ProviderDetailSection]
    public let updatedAt: Date

    public init(
        planName: String?,
        accountEmail: String?,
        monthlyUsedPercent: Double? = nil,
        monthlyResetsAt: Date? = nil,
        sessionUsedPercent: Double?,
        weeklyUsedPercent: Double?,
        sessionResetsAt: Date?,
        weeklyResetsAt: Date?,
        sessionWindowMinutes: Int? = nil,
        details: [ProviderDetailSection] = [],
        updatedAt: Date)
    {
        self.planName = planName
        self.accountEmail = accountEmail
        self.monthlyUsedPercent = monthlyUsedPercent
        self.monthlyResetsAt = monthlyResetsAt
        self.sessionUsedPercent = sessionUsedPercent
        self.weeklyUsedPercent = weeklyUsedPercent
        self.sessionResetsAt = sessionResetsAt
        self.weeklyResetsAt = weeklyResetsAt
        self.sessionWindowMinutes = sessionWindowMinutes
        self.details = details
        self.updatedAt = updatedAt
    }
}

extension OllamaUsageSnapshot {
    public func toUsageSnapshot() -> UsageSnapshot {
        // The 2026-08 page makes the monthly window primary; the legacy 5-hour session
        // and weekly windows remain as fallback for pages still rendering them.
        let monthlyWindow = self.makeWindow(
            usedPercent: self.monthlyUsedPercent,
            resetsAt: self.monthlyResetsAt,
            minutes: ProviderPaceCapability.monthlyWindowSentinelMinutes)
        let sessionWindow = self.makeWindow(
            usedPercent: self.sessionUsedPercent,
            resetsAt: self.sessionResetsAt,
            minutes: self.sessionWindowMinutes)
        let weeklyWindow = self.makeWindow(
            usedPercent: self.weeklyUsedPercent,
            resetsAt: self.weeklyResetsAt,
            minutes: 7 * 24 * 60)

        let plan = self.planName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = self.accountEmail?.trimmingCharacters(in: .whitespacesAndNewlines)
        let identity = ProviderIdentitySnapshot(
            providerID: .ollama,
            accountEmail: email?.isEmpty == false ? email : nil,
            accountOrganization: nil,
            loginMethod: plan?.isEmpty == false ? plan : nil)

        return UsageSnapshot(
            primary: monthlyWindow ?? sessionWindow,
            secondary: weeklyWindow,
            details: self.details,
            updatedAt: self.updatedAt,
            identity: identity)
    }

    private func makeWindow(usedPercent: Double?, resetsAt: Date?, minutes: Int?) -> RateWindow? {
        usedPercent.map {
            RateWindow(
                usedPercent: min(100, max(0, $0)),
                windowMinutes: minutes,
                resetsAt: resetsAt,
                resetDescription: nil)
        }
    }
}
