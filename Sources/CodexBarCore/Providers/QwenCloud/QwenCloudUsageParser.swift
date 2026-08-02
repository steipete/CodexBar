import Foundation

/// Parses Qwen Cloud token-plan responses (current shape) and falls back to
/// the legacy Alibaba subscription-summary envelope when the current shape
/// does not contain usable usage data.
enum QwenCloudUsageParser {
    static func parse(
        from usageData: Data,
        subscriptionData: Data?,
        quotaConfigData: Data?,
        now: Date) throws -> QwenCloudUsageSnapshot
    {
        if let snapshot = try self.parseCurrentTokenPlanUsage(
            from: usageData,
            subscriptionData: subscriptionData,
            quotaConfigData: quotaConfigData,
            now: now)
        {
            return snapshot
        }
        do {
            let alibaba = try AlibabaTokenPlanUsageFetcher.parseUsageSnapshot(from: usageData, now: now)
            return QwenCloudUsageSnapshot(alibabaSnapshot: alibaba)
        } catch let error as AlibabaTokenPlanUsageError {
            throw Self.map(error)
        }
    }

    static func parseUsageSnapshot(from data: Data, now: Date = Date()) throws -> QwenCloudUsageSnapshot {
        try self.parse(from: data, subscriptionData: nil, quotaConfigData: nil, now: now)
    }

    private static func parseCurrentTokenPlanUsage(
        from data: Data,
        subscriptionData: Data?,
        quotaConfigData: Data?,
        now: Date) throws -> QwenCloudUsageSnapshot?
    {
        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: data)
        } catch {
            return nil
        }
        let expanded = OneConsoleJSON.expandEmbeddedJSON(raw)
        guard let usage = OneConsoleJSON.findObject(
            containingAnyOf: ["per5HourPercentage", "per1WeekPercentage"],
            in: expanded)
        else {
            return nil
        }

        let fiveHourPercent = OneConsoleJSON.percentagePoints(
            fromRatio: OneConsoleJSON.number(usage["per5HourPercentage"]))
        let weeklyPercent = OneConsoleJSON.percentagePoints(
            fromRatio: OneConsoleJSON.number(usage["per1WeekPercentage"]))
        guard fiveHourPercent != nil || weeklyPercent != nil else { return nil }
        let planCode = subscriptionData.flatMap(self.planCode)
        let planName = planCode.map(self.displayPlanName)
        let quota = quotaConfigData.flatMap {
            self.quotaTotals(from: $0, planCode: planCode)
        }

        return QwenCloudUsageSnapshot(
            planName: planName,
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
            if let value = plan[key] as? String {
                let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if !normalized.isEmpty {
                    return normalized
                }
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

    private static func map(_ error: AlibabaTokenPlanUsageError) -> QwenCloudUsageError {
        switch error {
        case .loginRequired: .loginRequired
        case .invalidCredentials: .invalidCredentials
        case let .apiError(message): .apiError(message)
        case let .networkError(message): .networkError(message)
        case let .parseFailed(message): .parseFailed(message)
        }
    }
}
