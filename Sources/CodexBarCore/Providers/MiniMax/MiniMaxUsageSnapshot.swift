import Foundation

public struct MiniMaxUsageSnapshot: Sendable {
    public let planName: String?
    public let availablePrompts: Int?
    public let currentPrompts: Int?
    public let remainingPrompts: Int?
    public let windowMinutes: Int?
    public let usedPercent: Double?
    public let resetsAt: Date?
    public let updatedAt: Date

    public init(
        planName: String?,
        availablePrompts: Int?,
        currentPrompts: Int?,
        remainingPrompts: Int?,
        windowMinutes: Int?,
        usedPercent: Double?,
        resetsAt: Date?,
        updatedAt: Date)
    {
        self.planName = planName
        self.availablePrompts = availablePrompts
        self.currentPrompts = currentPrompts
        self.remainingPrompts = remainingPrompts
        self.windowMinutes = windowMinutes
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.updatedAt = updatedAt
    }
}

extension MiniMaxUsageSnapshot {
    public func toUsageSnapshot() -> UsageSnapshot {
        let used = max(0, min(100, self.usedPercent ?? 0))
        let resetDescription = self.limitDescription()
        let primary = RateWindow(
            usedPercent: used,
            windowMinutes: self.windowMinutes,
            resetsAt: self.resetsAt,
            resetDescription: resetDescription)

        let planName = self.planName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let loginMethod = (planName?.isEmpty ?? true) ? nil : planName
        let identity = ProviderIdentitySnapshot(
            providerID: .minimax,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: loginMethod)

        return UsageSnapshot(
            primary: primary,
            secondary: nil,
            tertiary: nil,
            providerCost: nil,
            minimaxUsage: self,
            updatedAt: self.updatedAt,
            identity: identity)
    }

    private func limitDescription() -> String? {
        guard let availablePrompts, availablePrompts > 0 else {
            return self.windowDescription()
        }

        if let windowDescription = self.windowDescription() {
            return "\(availablePrompts) prompts / \(windowDescription)"
        }
        return "\(availablePrompts) prompts"
    }

    private func windowDescription() -> String? {
        guard let windowMinutes, windowMinutes > 0 else { return nil }
        if windowMinutes % (24 * 60) == 0 {
            let days = windowMinutes / (24 * 60)
            return "\(days) \(days == 1 ? "day" : "days")"
        }
        if windowMinutes % 60 == 0 {
            let hours = windowMinutes / 60
            return "\(hours) \(hours == 1 ? "hour" : "hours")"
        }
        return "\(windowMinutes) \(windowMinutes == 1 ? "minute" : "minutes")"
    }
}
