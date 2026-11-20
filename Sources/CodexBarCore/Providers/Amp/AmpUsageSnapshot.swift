import Foundation

public struct AmpWorkspaceBalance: Codable, Equatable, Sendable {
    public let name: String
    public let remaining: Double

    public init(name: String, remaining: Double) {
        self.name = name
        self.remaining = remaining
    }
}

/// One UTC day from the `amp usage --details` daily recorded cost table.
public struct AmpDailyRecordedCost: Equatable, Sendable {
    /// `yyyy-MM-dd`, as reported by Amp in UTC.
    public let date: String
    public let cost: Double

    public init(date: String, cost: Double) {
        self.date = date
        self.cost = cost
    }
}

/// One row of the `amp usage --details` models table.
public struct AmpModelUsage: Equatable, Sendable {
    public let name: String
    public let inputTokens: Int
    public let cacheReadTokens: Int
    public let cacheWriteTokens: Int
    public let outputTokens: Int
    public let totalTokens: Int
    public let cost: Double

    public init(
        name: String,
        inputTokens: Int,
        cacheReadTokens: Int,
        cacheWriteTokens: Int,
        outputTokens: Int,
        totalTokens: Int,
        cost: Double)
    {
        self.name = name
        self.inputTokens = inputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
        self.cost = cost
    }
}

/// Recorded usage for one local day, from a single-day `amp usage --details` range.
public struct AmpDailyUsage: Equatable, Sendable {
    /// `yyyy-MM-dd` in the calendar the probe bucketed days with.
    public let date: String
    public let cost: Double?
    public let tokens: Int?
    public let models: [AmpModelUsage]

    public init(date: String, cost: Double?, tokens: Int?, models: [AmpModelUsage] = []) {
        self.date = date
        self.cost = cost
        self.tokens = tokens
        self.models = models
    }
}

/// Recorded totals for the range reported by `amp usage --details`.
public struct AmpRecentUsage: Equatable, Sendable {
    public let days: Int?
    public let recordedCost: Double?
    public let tokens: Int?
    /// Amp's own UTC-day cost table for the range; it carries no token counts.
    public let daily: [AmpDailyRecordedCost]
    public let models: [AmpModelUsage]
    /// Per-day tokens, cost, and models. Amp only reports these for one-day ranges, so the CLI probe fills them in.
    public var dailyUsage: [AmpDailyUsage]
    /// Day keys whose range could not be read. Their usage is unknown, not zero.
    public var unreadDays: Set<String>
    /// `true` when some day ranges could not be read; totals from `dailyUsage` are then a lower bound.
    public var dailyUsageIsPartial: Bool {
        !self.unreadDays.isEmpty
    }

    public init(
        days: Int?,
        recordedCost: Double?,
        tokens: Int?,
        daily: [AmpDailyRecordedCost] = [],
        models: [AmpModelUsage] = [],
        dailyUsage: [AmpDailyUsage] = [],
        unreadDays: Set<String> = [])
    {
        self.days = days
        self.recordedCost = recordedCost
        self.tokens = tokens
        self.daily = daily
        self.models = models
        self.dailyUsage = dailyUsage
        self.unreadDays = unreadDays
    }

    func toCostUsageTokenSnapshot(now: Date, calendar: Calendar = .current) -> CostUsageTokenSnapshot? {
        guard !self.dailyUsage.isEmpty else { return nil }
        let entries = self.dailyUsage.sorted { $0.date < $1.date }.map { day in
            let models = day.models
            return CostUsageDailyReport.Entry(
                date: day.date,
                inputTokens: models.isEmpty ? nil : models.map(\.inputTokens).reduce(0, +),
                outputTokens: models.isEmpty ? nil : models.map(\.outputTokens).reduce(0, +),
                cacheReadTokens: models.isEmpty ? nil : models.map(\.cacheReadTokens).reduce(0, +),
                cacheCreationTokens: models.isEmpty ? nil : models.map(\.cacheWriteTokens).reduce(0, +),
                totalTokens: day.tokens,
                costUSD: day.cost.map { max(0, $0) },
                modelsUsed: models.isEmpty ? nil : models.map(\.name),
                modelBreakdowns: models.isEmpty ? nil : models.map { model in
                    CostUsageDailyReport.ModelBreakdown(
                        modelName: model.name,
                        costUSD: max(0, model.cost),
                        totalTokens: model.totalTokens,
                        inputTokens: model.inputTokens,
                        outputTokens: model.outputTokens,
                        cacheReadTokens: model.cacheReadTokens,
                        cacheCreationTokens: model.cacheWriteTokens)
                })
        }
        let todayKey = CostUsageLocalDay.key(
            from: now,
            calendar: CostUsageLocalDay.gregorianCalendar(matching: calendar))
        let today = entries.first { $0.date == todayKey }
        // A day Amp was asked about and reported nothing for is a known zero; an unread day is unknown.
        let todayIsUnread = self.unreadDays.contains(todayKey)
        return CostUsageTokenSnapshot(
            sessionTokens: today?.totalTokens ?? (todayIsUnread ? nil : 0),
            sessionCostUSD: today?.costUSD ?? (todayIsUnread ? nil : 0),
            last30DaysTokens: self.tokens ?? entries.compactMap(\.totalTokens).reduce(0, +),
            last30DaysCostUSD: self.recordedCost ?? entries.compactMap(\.costUSD).reduce(0, +),
            historyDays: self.days ?? 30,
            historyScanIsPartial: self.dailyUsageIsPartial,
            costProvenance: .vendorMetered,
            daily: entries,
            updatedAt: now)
    }
}

public struct AmpSubscriptionUsage: Equatable, Sendable {
    public let plan: String
    public let otherUsedPercent: Double
    public let orbUsedPercent: Double?
    public let resetsAt: Date
    public let resetDescription: String
    public let agentRemaining: Double?
    public let agentLimit: Double?
    public let periodStart: Date?
    public let orbHoursRemaining: Double?
    public let orbHoursLimit: Double?

    public init(
        plan: String,
        otherUsedPercent: Double,
        orbUsedPercent: Double?,
        resetsAt: Date,
        resetDescription: String,
        agentRemaining: Double? = nil,
        agentLimit: Double? = nil,
        periodStart: Date? = nil,
        orbHoursRemaining: Double? = nil,
        orbHoursLimit: Double? = nil)
    {
        self.plan = plan
        self.otherUsedPercent = otherUsedPercent
        self.orbUsedPercent = orbUsedPercent
        self.resetsAt = resetsAt
        self.resetDescription = resetDescription
        self.agentRemaining = agentRemaining
        self.agentLimit = agentLimit
        self.periodStart = periodStart
        self.orbHoursRemaining = orbHoursRemaining
        self.orbHoursLimit = orbHoursLimit
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
    /// Workspaces whose usage is paid by an enterprise; Amp reports no balance for them.
    public let enterpriseWorkspaces: [String]
    public var recentUsage: AmpRecentUsage?

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
        subscription: AmpSubscriptionUsage? = nil,
        enterpriseWorkspaces: [String] = [],
        recentUsage: AmpRecentUsage? = nil)
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
        self.enterpriseWorkspaces = enterpriseWorkspaces
        self.recentUsage = recentUsage
    }
}

extension AmpUsageSnapshot {
    public func toUsageSnapshot(now: Date = Date(), calendar: Calendar = .current) -> UsageSnapshot {
        let freeWindow: RateWindow? = if let freeQuota, let freeUsed {
            {
                let quota = max(0, freeQuota)
                let used = max(0, freeUsed)
                let percent = quota > 0 ? min(100, (used / quota) * 100) : 0
                let windowMinutes: Int? = if let hours = self.windowHours, hours > 0 {
                    Int(exactly: (hours * 60).rounded())
                } else {
                    nil
                }
                let resetsAt: Date? = {
                    if self.freeResetDescription == "resets daily" {
                        return Self.nextFreeTierReset(after: now)
                    }
                    guard quota > 0, let hourlyReplenishment, hourlyReplenishment > 0 else { return nil }
                    let seconds = max(0, used / hourlyReplenishment * 3600)
                    guard Int(exactly: seconds.rounded(.towardZero)) != nil else { return nil }
                    return now.addingTimeInterval(seconds)
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

        let subscriptionWindowMinutes = self.subscription.flatMap { usage -> Int? in
            if let start = usage.periodStart {
                return Int(exactly: (usage.resetsAt.timeIntervalSince(start) / 60).rounded(.towardZero))
            }
            // Preserve legacy calendar-month pacing, but do not invent a Tier period when dates are missing.
            guard usage.agentRemaining == nil else { return nil }
            return ProviderPaceCapability.calendarMonthResetWindow.resolvedResetWindowForPace(RateWindow(
                usedPercent: usage.otherUsedPercent,
                windowMinutes: ProviderPaceCapability.monthlyWindowSentinelMinutes,
                resetsAt: usage.resetsAt,
                resetDescription: usage.resetDescription)).windowMinutes
        }
        let subscriptionPrimary = self.subscription.map { usage in
            RateWindow(
                usedPercent: usage.otherUsedPercent,
                windowMinutes: subscriptionWindowMinutes,
                resetsAt: usage.resetsAt,
                resetDescription: usage.resetDescription)
        }
        let subscriptionSecondary = self.subscription.flatMap { usage -> RateWindow? in
            guard let orbUsedPercent = usage.orbUsedPercent else { return nil }
            return RateWindow(
                usedPercent: orbUsedPercent,
                windowMinutes: subscriptionWindowMinutes,
                resetsAt: usage.resetsAt,
                resetDescription: usage.resetDescription)
        }
        let primary = subscriptionPrimary ?? freeWindow
        let extraRateWindows: [NamedRateWindow]? = if self.subscription != nil, let freeWindow {
            [NamedRateWindow(id: "amp-free", title: "Amp Free", window: freeWindow)]
        } else {
            nil
        }

        let identity = ProviderIdentitySnapshot(
            providerID: .amp,
            accountEmail: self.accountEmail,
            accountOrganization: self.accountOrganization,
            loginMethod: self.subscription?.plan ?? self.fallbackLoginMethod(hasPrimary: primary != nil))

        var allowanceRows: [ProviderDetailSection.Row] = []
        if let remaining = self.subscription?.agentRemaining {
            allowanceRows.append(.makeRow(label: "Agent", value: UsageFormatter.usdString(remaining)))
        }
        if let remaining = self.subscription?.orbHoursRemaining {
            let hours = remaining > 0 && remaining < 1
                ? "< 1h"
                : "\(remaining.rounded(.down).formatted(.number.precision(.fractionLength(0))))h"
            allowanceRows.append(.makeRow(
                label: "Orb",
                value: hours,
                secondaryValue: "a1.small-equivalent hours"))
        }
        var details: [ProviderDetailSection] = allowanceRows.isEmpty ? [] : [.makeSection(
            title: "Monthly allowances",
            rows: allowanceRows)]

        var detailRows: [ProviderDetailSection.Row] = []
        if let individualCredits = self.individualCredits {
            detailRows.append(.makeRow(
                label: "Individual",
                value: UsageFormatter.usdString(individualCredits),
                secondaryValue: "For agent and orb usage"))
        }
        detailRows.append(contentsOf: self.workspaceBalances.map {
            .makeRow(label: "Workspace \($0.name)", value: UsageFormatter.usdString($0.remaining))
        })
        detailRows.append(contentsOf: self.enterpriseWorkspaces.map {
            .makeRow(label: "Workspace \($0)", value: "Enterprise", secondaryValue: "Usage paid by your enterprise")
        })
        if !detailRows.isEmpty {
            details.append(.makeSection(title: "Credits", rows: detailRows))
        }

        // The shared cost chart already carries these totals when Amp reports daily history.
        let costUsage = self.recentUsage?.toCostUsageTokenSnapshot(now: self.updatedAt, calendar: calendar)
        var recentRows: [ProviderDetailSection.Row] = []
        if costUsage == nil, let cost = self.recentUsage?.recordedCost {
            recentRows.append(.makeRow(label: "Recorded cost", value: UsageFormatter.usdString(cost)))
        }
        if costUsage == nil, let tokens = self.recentUsage?.tokens {
            recentRows.append(.makeRow(label: "Tokens", value: UsageFormatter.tokenCountString(tokens)))
        }
        if !recentRows.isEmpty {
            let title = self.recentUsage?.days.map { $0 == 1 ? "Last day" : "Last \($0) days" } ?? "Recent usage"
            details.append(.makeSection(title: title, rows: recentRows))
        }

        return UsageSnapshot(
            primary: primary,
            secondary: subscriptionSecondary,
            tertiary: nil,
            extraRateWindows: extraRateWindows,
            providerCost: nil,
            costUsage: costUsage,
            details: details,
            updatedAt: self.updatedAt,
            identity: identity)
    }

    private func fallbackLoginMethod(hasPrimary: Bool) -> String {
        if !self.enterpriseWorkspaces.isEmpty {
            return "Enterprise"
        }
        return hasPrimary ? "Amp Free" : "Amp"
    }

    private static func nextFreeTierReset(after date: Date) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        guard let timeZone = TimeZone(identifier: "America/New_York") else { return nil }
        calendar.timeZone = timeZone
        return calendar.nextDate(
            after: date,
            matching: DateComponents(hour: 20),
            matchingPolicy: .nextTime)
    }
}
