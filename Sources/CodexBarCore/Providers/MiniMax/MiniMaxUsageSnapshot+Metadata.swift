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
            usageSummary: self.usageSummary,
            pointsBalance: self.pointsBalance,
            pointsBalanceExpiresAt: self.pointsBalanceExpiresAt,
            subscriptionExpiresAt: self.subscriptionExpiresAt,
            subscriptionRenewsAt: self.subscriptionRenewsAt,
            webSessionState: self.webSessionState)
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
            usageSummary: self.usageSummary,
            pointsBalance: self.pointsBalance,
            pointsBalanceExpiresAt: self.pointsBalanceExpiresAt,
            subscriptionExpiresAt: metadata.subscriptionExpiresAt ?? self.subscriptionExpiresAt,
            subscriptionRenewsAt: metadata.subscriptionRenewsAt ?? self.subscriptionRenewsAt,
            webSessionState: self.webSessionState)
    }

    func withUsageSummary(_ usageSummary: MiniMaxUsageSummary?) -> MiniMaxUsageSnapshot {
        MiniMaxUsageSnapshot(
            planName: self.planName,
            availablePrompts: self.availablePrompts,
            currentPrompts: self.currentPrompts,
            remainingPrompts: self.remainingPrompts,
            windowMinutes: self.windowMinutes,
            usedPercent: self.usedPercent,
            resetsAt: self.resetsAt,
            updatedAt: self.updatedAt,
            services: self.services,
            billingSummary: self.billingSummary,
            usageSummary: usageSummary,
            pointsBalance: self.pointsBalance,
            pointsBalanceExpiresAt: self.pointsBalanceExpiresAt,
            subscriptionExpiresAt: self.subscriptionExpiresAt,
            subscriptionRenewsAt: self.subscriptionRenewsAt,
            webSessionState: self.webSessionState)
    }

    func withPointsBalanceIfMissing(_ pointsBalance: Double?, expiresAt: Date?) -> MiniMaxUsageSnapshot {
        guard let pointsBalance, pointsBalance >= 0, self.pointsBalance == nil else {
            return self
        }
        return self.withPointsBalanceFromDedicatedEndpoint(pointsBalance, expiresAt: expiresAt)
    }

    func withPointsBalanceFromDedicatedEndpoint(_ pointsBalance: Double?, expiresAt: Date?) -> MiniMaxUsageSnapshot {
        guard let pointsBalance, pointsBalance >= 0,
              pointsBalance != self.pointsBalance || expiresAt != self.pointsBalanceExpiresAt
        else {
            return self
        }
        return MiniMaxUsageSnapshot(
            planName: self.planName,
            availablePrompts: self.availablePrompts,
            currentPrompts: self.currentPrompts,
            remainingPrompts: self.remainingPrompts,
            windowMinutes: self.windowMinutes,
            usedPercent: self.usedPercent,
            resetsAt: self.resetsAt,
            updatedAt: self.updatedAt,
            services: self.services,
            billingSummary: self.billingSummary,
            usageSummary: self.usageSummary,
            pointsBalance: pointsBalance,
            pointsBalanceExpiresAt: expiresAt ?? self.pointsBalanceExpiresAt,
            subscriptionExpiresAt: self.subscriptionExpiresAt,
            subscriptionRenewsAt: self.subscriptionRenewsAt,
            webSessionState: self.webSessionState)
    }
}

extension String {
    fileprivate var nonEmpty: String? {
        self.isEmpty ? nil : self
    }
}
