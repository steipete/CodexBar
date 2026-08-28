import Foundation

extension MiniMaxUsageSnapshot {
    func withPlanNameIfMissing(_ planName: String?) -> MiniMaxUsageSnapshot {
        let existing = self.planName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing, !existing.isEmpty { return self }
        let cleaned = planName?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let cleaned, !cleaned.isEmpty else { return self }
        return MiniMaxUsageSnapshot(
            planName: cleaned,
            availablePrompts: self.availablePrompts,
            currentPrompts: self.currentPrompts,
            remainingPrompts: self.remainingPrompts,
            windowMinutes: self.windowMinutes,
            usedPercent: self.usedPercent,
            resetsAt: self.resetsAt,
            updatedAt: self.updatedAt,
            services: self.services,
            billingSummary: self.billingSummary,
            pointsBalance: self.pointsBalance,
            subscriptionExpiresAt: self.subscriptionExpiresAt,
            subscriptionRenewsAt: self.subscriptionRenewsAt)
    }

    func withSubscriptionMetadata(_ metadata: MiniMaxSubscriptionMetadata) -> MiniMaxUsageSnapshot {
        MiniMaxUsageSnapshot(
            planName: metadata.planName?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? self.planName,
            availablePrompts: self.availablePrompts,
            currentPrompts: self.currentPrompts,
            remainingPrompts: self.remainingPrompts,
            windowMinutes: self.windowMinutes,
            usedPercent: self.usedPercent,
            resetsAt: self.resetsAt,
            updatedAt: self.updatedAt,
            services: self.services,
            billingSummary: self.billingSummary,
            pointsBalance: self.pointsBalance,
            subscriptionExpiresAt: metadata.subscriptionExpiresAt ?? self.subscriptionExpiresAt,
            subscriptionRenewsAt: metadata.subscriptionRenewsAt ?? self.subscriptionRenewsAt)
    }
}

extension String {
    fileprivate var nonEmpty: String? {
        self.isEmpty ? nil : self
    }
}
