import Foundation

/// Shared parser for Alibaba Token Plan Personal/Solo rolling-window responses.
/// Both mainland and international variants expose the same payload contract.
enum AlibabaTokenPlanPersonalUsageParser {
    static func parse(
        from usageData: Data,
        subscriptionData: Data?,
        quotaConfigData: Data?,
        now: Date) throws -> AlibabaTokenPlanUsageSnapshot
    {
        guard !usageData.isEmpty else {
            throw AlibabaTokenPlanUsageError.parseFailed("Empty response body")
        }

        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: usageData)
        } catch {
            if let text = String(data: usageData, encoding: .utf8)?.lowercased(),
               text.contains("<html"),
               text.contains("login") || text.contains("sign in") || text.contains("signin")
            {
                throw AlibabaTokenPlanUsageError.loginRequired
            }
            throw AlibabaTokenPlanUsageError.parseFailed("Invalid JSON response")
        }

        let expanded = OneConsoleJSON.expandEmbeddedJSON(raw)
        guard let dictionary = expanded as? [String: Any] else {
            throw AlibabaTokenPlanUsageError.parseFailed("Unexpected payload")
        }
        try AlibabaTokenPlanUsageFetcher.throwIfErrorPayload(dictionary)
        guard let usage = OneConsoleJSON.findObject(
            containingAnyOf: ["per5HourPercentage", "per1WeekPercentage"],
            in: expanded)
        else {
            throw AlibabaTokenPlanUsageError.usageWindowsUnavailable
        }

        let fiveHourPercent = OneConsoleJSON.percentagePoints(
            fromRatio: OneConsoleJSON.number(usage["per5HourPercentage"]))
        let weeklyPercent = OneConsoleJSON.percentagePoints(
            fromRatio: OneConsoleJSON.number(usage["per1WeekPercentage"]))
        guard fiveHourPercent != nil || weeklyPercent != nil else {
            throw AlibabaTokenPlanUsageError.usageWindowsUnavailable
        }

        let planCode = subscriptionData.flatMap(self.planCode)
        let quota = quotaConfigData.flatMap {
            self.quotaTotals(from: $0, planCode: planCode)
        }
        return AlibabaTokenPlanUsageSnapshot(
            planName: planCode.map(self.displayPlanName) ?? "Personal",
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
        planCode: String?) -> (fiveHour: Double?, weekly: Double?)?
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
        guard fiveHour != nil || weekly != nil else { return nil }
        return (fiveHour, weekly)
    }
}
