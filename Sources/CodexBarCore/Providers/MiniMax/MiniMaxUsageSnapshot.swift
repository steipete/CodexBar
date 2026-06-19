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
    public let services: [MiniMaxServiceUsage]?
    public let billingSummary: MiniMaxBillingSummary?
    public let pointsBalance: Double?
    public let subscriptionExpiresAt: Date?
    public let subscriptionRenewsAt: Date?

    public var primaryService: MiniMaxServiceUsage? {
        self.orderedQuotaServices.first
    }

    public var secondaryService: MiniMaxServiceUsage? {
        let services = self.orderedQuotaServices
        guard services.count >= 2 else { return nil }
        return services[1]
    }

    public var tertiaryService: MiniMaxServiceUsage? {
        let services = self.orderedQuotaServices
        guard services.count >= 3 else { return nil }
        return services[2]
    }

    public var orderedQuotaServices: [MiniMaxServiceUsage] {
        guard let services, !services.isEmpty else { return [] }
        return services.enumerated().sorted { lhs, rhs in
            let lhsRank = self.quotaServiceRank(lhs.element, originalIndex: lhs.offset)
            let rhsRank = self.quotaServiceRank(rhs.element, originalIndex: rhs.offset)
            if lhsRank.primary != rhsRank.primary {
                return lhsRank.primary < rhsRank.primary
            }
            if lhsRank.window != rhsRank.window {
                return lhsRank.window < rhsRank.window
            }
            return lhsRank.originalIndex < rhsRank.originalIndex
        }.map(\.element)
    }

    private func quotaServiceRank(
        _ service: MiniMaxServiceUsage,
        originalIndex: Int) -> (primary: Int, window: Int, originalIndex: Int)
    {
        (
            primary: service.isPrimaryTextQuotaLane ? 0 : 1,
            window: self.quotaWindowRank(service),
            originalIndex: originalIndex)
    }

    private func quotaWindowRank(_ service: MiniMaxServiceUsage) -> Int {
        let window = service.windowType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if window == "weekly" {
            return 1
        }
        return 0
    }

    public init(
        planName: String?,
        availablePrompts: Int?,
        currentPrompts: Int?,
        remainingPrompts: Int?,
        windowMinutes: Int?,
        usedPercent: Double?,
        resetsAt: Date?,
        updatedAt: Date,
        services: [MiniMaxServiceUsage]? = nil,
        billingSummary: MiniMaxBillingSummary? = nil,
        pointsBalance: Double? = nil,
        subscriptionExpiresAt: Date? = nil,
        subscriptionRenewsAt: Date? = nil)
    {
        self.planName = planName
        self.availablePrompts = availablePrompts
        self.currentPrompts = currentPrompts
        self.remainingPrompts = remainingPrompts
        self.windowMinutes = windowMinutes
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.updatedAt = updatedAt
        self.services = services
        self.billingSummary = billingSummary
        self.pointsBalance = pointsBalance
        self.subscriptionExpiresAt = subscriptionExpiresAt
        self.subscriptionRenewsAt = subscriptionRenewsAt
    }

    public func withBillingSummary(_ billingSummary: MiniMaxBillingSummary?) -> MiniMaxUsageSnapshot {
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
            billingSummary: billingSummary,
            pointsBalance: self.pointsBalance,
            subscriptionExpiresAt: self.subscriptionExpiresAt,
            subscriptionRenewsAt: self.subscriptionRenewsAt)
    }
}

extension MiniMaxUsageSnapshot {
    public func toUsageSnapshot() -> UsageSnapshot {
        // If we have services array, use that for multi-service support
        if let services = self.services, !services.isEmpty {
            let primaryWindow = self.rateWindow(for: self.primaryService)
            let secondaryWindow = self.rateWindow(for: self.secondaryService)
            let tertiaryWindow = self.rateWindow(for: self.tertiaryService)

            let planName = self.planName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let loginMethod = (planName?.isEmpty ?? true) ? nil : planName
            let identity = ProviderIdentitySnapshot(
                providerID: .minimax,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: loginMethod)

            return UsageSnapshot(
                primary: primaryWindow,
                secondary: secondaryWindow,
                tertiary: tertiaryWindow,
                providerCost: self.pointsBalanceSnapshot(),
                minimaxUsage: self,
                subscriptionExpiresAt: self.subscriptionExpiresAt,
                subscriptionRenewsAt: self.subscriptionRenewsAt,
                updatedAt: self.updatedAt,
                identity: identity)
        }

        // Fallback to single-service mode for backward compatibility
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
            providerCost: self.pointsBalanceSnapshot(),
            minimaxUsage: self,
            subscriptionExpiresAt: self.subscriptionExpiresAt,
            subscriptionRenewsAt: self.subscriptionRenewsAt,
            updatedAt: self.updatedAt,
            identity: identity)
    }

    private func rateWindow(for service: MiniMaxServiceUsage?) -> RateWindow? {
        guard let service else { return nil }
        let windowMinutes = self.windowMinutes(for: service)
        return RateWindow(
            usedPercent: max(0, min(100, service.percent)),
            windowMinutes: windowMinutes,
            resetsAt: service.resetsAt,
            resetDescription: service.resetDescription)
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

    private func windowMinutes(for service: MiniMaxServiceUsage) -> Int? {
        let windowType = service.windowType.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // Handle "Today" case - 24 hours = 1440 minutes
        if windowType == "today" {
            return 24 * 60
        }
        if windowType == "weekly" {
            return 7 * 24 * 60
        }

        // Handle time duration formats like "5 hours", "30 minutes", etc.
        let components = windowType.split(separator: " ")
        guard components.count >= 2 else { return nil }

        guard let value = Int(components[0]) else { return nil }
        let unit = components[1].lowercased()

        switch unit {
        case "hour", "hours", "h", "hr", "hrs":
            return value * 60
        case "minute", "minutes", "min", "mins", "m":
            return value
        case "day", "days", "d":
            return value * 24 * 60
        default:
            return nil
        }
    }

    private func pointsBalanceSnapshot() -> ProviderCostSnapshot? {
        guard let pointsBalance, pointsBalance >= 0 else { return nil }
        return ProviderCostSnapshot(
            used: pointsBalance,
            limit: 0,
            currencyCode: "Points",
            period: "MiniMax points balance",
            updatedAt: self.updatedAt)
    }
}
