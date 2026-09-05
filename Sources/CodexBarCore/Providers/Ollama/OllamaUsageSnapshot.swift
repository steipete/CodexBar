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
        self.updatedAt = updatedAt
    }
}

extension OllamaUsageSnapshot {
    public func toUsageSnapshot() -> UsageSnapshot {
        // The 2026-08 page makes the monthly window primary; the legacy 5-hour session
        // and weekly windows remain as fallback for pages still rendering them.
        let monthlyWindow = self.makeMonthlyWindow()
        let sessionWindow = self.makeSessionWindow(
            usedPercent: self.sessionUsedPercent,
            resetsAt: self.sessionResetsAt)
        let weeklyWindow = self.makeWeeklyWindow(
            usedPercent: self.weeklyUsedPercent,
            resetsAt: self.weeklyResetsAt)

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
            tertiary: nil,
            providerCost: nil,
            updatedAt: self.updatedAt,
            identity: identity)
    }

    private func makeMonthlyWindow() -> RateWindow? {
        guard let usedPercent = self.monthlyUsedPercent else { return nil }
        let clamped = min(100, max(0, usedPercent))
        return RateWindow(
            usedPercent: clamped,
            windowMinutes: ProviderPaceCapability.monthlyWindowSentinelMinutes,
            resetsAt: self.monthlyResetsAt,
            resetDescription: nil)
    }

    private func makeSessionWindow(usedPercent: Double?, resetsAt: Date?) -> RateWindow? {
        guard let usedPercent else { return nil }
        let clamped = min(100, max(0, usedPercent))
        return RateWindow(
            usedPercent: clamped,
            windowMinutes: self.sessionWindowMinutes,
            resetsAt: resetsAt,
            resetDescription: nil)
    }

    private func makeWeeklyWindow(usedPercent: Double?, resetsAt: Date?) -> RateWindow? {
        guard let usedPercent else { return nil }
        let clamped = min(100, max(0, usedPercent))
        return RateWindow(
            usedPercent: clamped,
            windowMinutes: 7 * 24 * 60,
            resetsAt: resetsAt,
            resetDescription: nil)
    }
}
