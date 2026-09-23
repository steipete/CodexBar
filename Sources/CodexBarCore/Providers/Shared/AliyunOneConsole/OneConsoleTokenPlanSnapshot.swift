import Foundation

protocol OneConsoleTokenPlanSnapshot {
    var planName: String? { get }
    var usedQuota: Double? { get }
    var totalQuota: Double? { get }
    var remainingQuota: Double? { get }
    var resetsAt: Date? { get }
    var fiveHourUsedPercent: Double? { get }
    var fiveHourTotalQuota: Double? { get }
    var fiveHourResetsAt: Date? { get }
    var weeklyUsedPercent: Double? { get }
    var weeklyTotalQuota: Double? { get }
    var weeklyResetsAt: Date? { get }
    var monthlyUsedPercent: Double? { get }
    var monthlyTotalQuota: Double? { get }
    var monthlyResetsAt: Date? { get }
    var updatedAt: Date { get }

    init(
        planName: String?,
        usedQuota: Double?,
        totalQuota: Double?,
        remainingQuota: Double?,
        resetsAt: Date?,
        fiveHourUsedPercent: Double?,
        fiveHourTotalQuota: Double?,
        fiveHourResetsAt: Date?,
        weeklyUsedPercent: Double?,
        weeklyTotalQuota: Double?,
        weeklyResetsAt: Date?,
        monthlyUsedPercent: Double?,
        monthlyTotalQuota: Double?,
        monthlyResetsAt: Date?,
        updatedAt: Date)
}

extension OneConsoleTokenPlanSnapshot {
    func usageSnapshot(for provider: UsageProvider) -> UsageSnapshot {
        let personalPrimary = self.fiveHourUsedPercent.map {
            RateWindow(
                usedPercent: $0,
                windowMinutes: 5 * 60,
                resetsAt: self.fiveHourResetsAt,
                resetDescription: Self.quotaDetail(usedPercent: $0, total: self.fiveHourTotalQuota))
        }
        let teamPrimary: RateWindow? = Self.usedPercent(
            used: self.usedQuota,
            total: self.totalQuota,
            remaining: self.remainingQuota).map {
            RateWindow(
                usedPercent: $0,
                windowMinutes: 30 * 24 * 60,
                resetsAt: self.resetsAt,
                resetDescription: Self.quotaDetail(
                    used: self.usedQuota,
                    total: self.totalQuota,
                    remaining: self.remainingQuota))
        }
        let secondary = self.weeklyUsedPercent.map {
            RateWindow(
                usedPercent: $0,
                windowMinutes: 7 * 24 * 60,
                resetsAt: self.weeklyResetsAt,
                resetDescription: Self.quotaDetail(usedPercent: $0, total: self.weeklyTotalQuota))
        }
        let personalMonthly = self.monthlyUsedPercent.map {
            RateWindow(
                usedPercent: $0,
                windowMinutes: 30 * 24 * 60,
                resetsAt: self.monthlyResetsAt,
                resetDescription: Self.quotaDetail(usedPercent: $0, total: self.monthlyTotalQuota))
        }
        // Personal plans that only report a monthly window use it as the primary lane, matching
        // the Team plan's 30-day primary; alongside rolling windows it moves to the tertiary lane.
        let rollingPrimary = personalPrimary ?? teamPrimary
        let monthlyIsPrimary = rollingPrimary == nil && secondary == nil
        let primary = rollingPrimary ?? (monthlyIsPrimary ? personalMonthly : nil)
        let tertiary = monthlyIsPrimary ? nil : personalMonthly

        let planName = self.planName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let loginMethod = (planName?.isEmpty ?? true) ? nil : planName
        let identity = ProviderIdentitySnapshot(
            providerID: provider.instanceID,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: loginMethod)

        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            tertiary: tertiary,
            providerCost: nil,
            updatedAt: self.updatedAt,
            identity: identity)
    }

    private static func usedPercent(used: Double?, total: Double?, remaining: Double?) -> Double? {
        guard let total, total > 0 else { return nil }
        let usedValue: Double? = if let used {
            used
        } else if let remaining {
            total - remaining
        } else {
            nil
        }
        guard let usedValue else { return nil }
        let normalizedUsed = max(0, min(usedValue, total))
        return normalizedUsed / total * 100
    }

    private static func quotaDetail(used: Double?, total: Double?, remaining: Double?) -> String? {
        if let used, let total, total > 0 {
            return "\(self.format(used)) / \(self.format(total)) credits used"
        }
        if let remaining, let total, total > 0 {
            return "\(Self.format(remaining)) / \(Self.format(total)) credits left"
        }
        if let remaining {
            return "\(Self.format(remaining)) credits left"
        }
        return nil
    }

    private static func quotaDetail(usedPercent: Double, total: Double?) -> String? {
        guard let total, total > 0 else { return nil }
        let used = total * usedPercent / 100
        return "\(Self.format(used)) / \(Self.format(total)) credits used"
    }

    private static func format(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.maximumFractionDigits = value.rounded() == value ? 0 : 2
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }
}

extension OneConsoleTokenPlanSnapshot {
    static func personalUsage(
        in expanded: Any,
        subscriptionData: Data?,
        quotaConfigData: Data?,
        defaultPlanName: String? = nil,
        now: Date) -> Self?
    {
        guard let usage = OneConsoleJSON.findObject(
            containingAnyOf: ["per5HourPercentage", "per1WeekPercentage", "per1MonthPercentage"],
            in: expanded)
        else {
            return nil
        }

        let fiveHourPercent = OneConsoleJSON.percentagePoints(
            fromRatio: OneConsoleJSON.number(usage["per5HourPercentage"]))
        let weeklyPercent = OneConsoleJSON.percentagePoints(
            fromRatio: OneConsoleJSON.number(usage["per1WeekPercentage"]))
        let monthlyPercent = OneConsoleJSON.percentagePoints(
            fromRatio: OneConsoleJSON.number(usage["per1MonthPercentage"]))
        guard fiveHourPercent != nil || weeklyPercent != nil || monthlyPercent != nil else {
            return nil
        }

        let planCode = subscriptionData.flatMap(self.planCode)
        let quota = quotaConfigData.flatMap {
            self.quotaTotals(from: $0, planCode: planCode)
        }
        return Self(
            planName: planCode.map(self.displayPlanName) ?? defaultPlanName,
            usedQuota: nil,
            totalQuota: nil,
            remainingQuota: nil,
            resetsAt: nil,
            fiveHourUsedPercent: fiveHourPercent,
            fiveHourTotalQuota: quota?.fiveHour,
            fiveHourResetsAt: OneConsoleJSON.date(usage["per5HourResetTime"]),
            weeklyUsedPercent: weeklyPercent,
            weeklyTotalQuota: quota?.weekly,
            weeklyResetsAt: OneConsoleJSON.date(usage["per1WeekResetTime"]),
            monthlyUsedPercent: monthlyPercent,
            monthlyTotalQuota: quota?.monthly,
            monthlyResetsAt: OneConsoleJSON.date(usage["per1MonthResetTime"]),
            updatedAt: now)
    }

    private static func planCode(from data: Data) -> String? {
        guard let raw = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let expanded = OneConsoleJSON.expandEmbeddedJSON(raw)
        guard let plan = OneConsoleJSON.findObject(
            containingAnyOf: ["specCode", "spec_code", "planName", "plan_name"],
            in: expanded)
        else {
            return nil
        }
        for key in ["specCode", "spec_code", "planName", "plan_name"] {
            if let value = OneConsoleJSON.string(plan[key])?.lowercased(), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func displayPlanName(_ planCode: String) -> String {
        switch planCode {
        case "lite": "Lite"
        case "standard": "Standard"
        case "pro": "Pro"
        case "max": "Max"
        default: planCode
        }
    }

    private static func quotaTotals(
        from data: Data,
        planCode: String?) -> (fiveHour: Double?, weekly: Double?, monthly: Double?)?
    {
        guard let planCode,
              let raw = try? JSONSerialization.jsonObject(with: data)
        else {
            return nil
        }
        let expanded = OneConsoleJSON.expandEmbeddedJSON(raw)
        guard let value = OneConsoleJSON.findFirstValue(forKeys: [planCode], in: expanded),
              let quota = value as? [String: Any]
        else {
            return nil
        }
        let fiveHour = OneConsoleJSON.number(quota["five_hour"] ?? quota["fiveHour"])
        let weekly = OneConsoleJSON.number(quota["weekly"])
        let monthly = OneConsoleJSON.number(quota["monthly"])
        guard fiveHour != nil || weekly != nil || monthly != nil else { return nil }
        return (fiveHour, weekly, monthly)
    }
}
