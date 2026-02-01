import Foundation

public struct OllamaUsageSnapshot: Sendable {
    public let planName: String?
    public let accountEmail: String?
    public let sessionUsedPercent: Double?
    public let weeklyUsedPercent: Double?
    public let sessionResetsAt: Date?
    public let weeklyResetsAt: Date?
    public let updatedAt: Date

    public init(
        planName: String?,
        accountEmail: String?,
        sessionUsedPercent: Double?,
        weeklyUsedPercent: Double?,
        sessionResetsAt: Date?,
        weeklyResetsAt: Date?,
        updatedAt: Date)
    {
        self.planName = planName
        self.accountEmail = accountEmail
        self.sessionUsedPercent = sessionUsedPercent
        self.weeklyUsedPercent = weeklyUsedPercent
        self.sessionResetsAt = sessionResetsAt
        self.weeklyResetsAt = weeklyResetsAt
        self.updatedAt = updatedAt
    }
}

extension OllamaUsageSnapshot {
    public func toUsageSnapshot() -> UsageSnapshot {
        let sessionWindow = self.makeWindow(
            usedPercent: self.sessionUsedPercent,
            resetsAt: self.sessionResetsAt)
        let weeklyWindow = self.makeWindow(
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
            primary: sessionWindow,
            secondary: weeklyWindow,
            tertiary: nil,
            providerCost: nil,
            updatedAt: self.updatedAt,
            identity: identity)
    }

    private func makeWindow(usedPercent: Double?, resetsAt: Date?) -> RateWindow? {
        guard let usedPercent else { return nil }
        let clamped = min(100, max(0, usedPercent))
        return RateWindow(
            usedPercent: clamped,
            windowMinutes: nil,
            resetsAt: resetsAt,
            resetDescription: nil)
    }
}
