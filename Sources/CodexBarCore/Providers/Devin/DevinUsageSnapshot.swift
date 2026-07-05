import CoreFoundation
import Foundation

public enum DevinUsageError: LocalizedError, Sendable {
    case noSession
    case missingOrganization
    case invalidCredentials
    case apiError(String)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noSession:
            "No Devin browser session found. Please log in to app.devin.ai or paste a Bearer token."
        case .missingOrganization:
            "No Devin organization was found. Open an app.devin.ai/org/... page " +
                "or set the organization in Devin settings."
        case .invalidCredentials:
            "Devin session token is invalid or expired."
        case let .apiError(message):
            "Devin API error: \(message)"
        case let .parseFailed(message):
            "Could not parse Devin usage: \(message)"
        }
    }
}

public struct DevinQuotaWindow: Sendable, Equatable {
    public let usedPercent: Double
    public let resetsAt: Date?

    public init(usedPercent: Double, resetsAt: Date? = nil) {
        self.usedPercent = min(100, max(0, usedPercent))
        self.resetsAt = resetsAt
    }
}

public struct DevinUsageSnapshot: Sendable, Equatable {
    public let daily: DevinQuotaWindow?
    public let weekly: DevinQuotaWindow?
    public let planName: String?
    public let organization: String?
    public let updatedAt: Date
    public let overageBalance: Double?

    public init(
        daily: DevinQuotaWindow?,
        weekly: DevinQuotaWindow?,
        planName: String?,
        organization: String?,
        updatedAt: Date,
        overageBalance: Double? = nil)
    {
        self.daily = daily
        self.weekly = weekly
        self.planName = planName
        self.organization = organization
        self.updatedAt = updatedAt
        self.overageBalance = overageBalance
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        let primary = self.daily.map {
            RateWindow(
                usedPercent: $0.usedPercent,
                windowMinutes: 24 * 60,
                resetsAt: $0.resetsAt,
                resetDescription: "Daily")
        }
        let secondary = self.weekly.map {
            RateWindow(
                usedPercent: $0.usedPercent,
                windowMinutes: 7 * 24 * 60,
                resetsAt: $0.resetsAt,
                resetDescription: "Weekly")
        }
        let identity = ProviderIdentitySnapshot(
            providerID: .devin,
            accountEmail: nil,
            accountOrganization: self.organization,
            loginMethod: self.planName)
        let providerCost: ProviderCostSnapshot? = self.overageBalance.map {
            ProviderCostSnapshot(
                used: $0,
                limit: 0,
                currencyCode: "USD",
                period: "Extra usage balance",
                updatedAt: self.updatedAt)
        }
        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            providerCost: providerCost,
            updatedAt: self.updatedAt,
            identity: identity)
    }
}

public enum DevinUsageParser {
    public static func parse(_ data: Data, organization: String?, now: Date = Date()) throws -> DevinUsageSnapshot {
        let object = try JSONSerialization.jsonObject(with: data)
        return try self.parse(object, organization: organization, now: now)
    }

    public static func parse(_ object: Any, organization: String?, now: Date = Date()) throws -> DevinUsageSnapshot {
        let current = (object as? [String: Any]).map(self.currentQuotaWindows)
        let daily = current?.daily ?? self.findWindow(in: object, matching: self.isDailyKey)
        let weekly = current?.weekly ?? self.findWindow(in: object, matching: self.isWeeklyKey)
        guard daily != nil || weekly != nil else {
            throw DevinUsageError.parseFailed("Missing Devin quota windows.")
        }

        return DevinUsageSnapshot(
            daily: daily,
            weekly: weekly,
            planName: self.findPlanName(in: object),
            organization: self.displayOrganization(from: organization),
            updatedAt: now,
            overageBalance: self.findOverageBalance(in: object))
    }

    private static func findOverageBalance(in object: Any) -> Double? {
        guard let dictionary = object as? [String: Any] else { return nil }
        if let value = self.nonnegativeFiniteDouble(dictionary["overage_balance"]) { return value }
        if let cents = self.nonnegativeFiniteDouble(dictionary["overage_balance_cents"]) { return cents / 100.0 }
        return nil
    }

    private static func nonnegativeFiniteDouble(_ value: Any?) -> Double? {
        guard let value = self.double(value), value.isFinite, value >= 0 else { return nil }
        return value
    }

    private static func currentQuotaWindows(_ dictionary: [String: Any])
        -> (daily: DevinQuotaWindow?, weekly: DevinQuotaWindow?)
    {
        let daily = self.currentQuotaWindow(
            percent: dictionary["daily_percentage"],
            resetsAt: dictionary["daily_reset_at"])
        let weekly = self.currentQuotaWindow(
            percent: dictionary["weekly_percentage"],
            resetsAt: dictionary["weekly_reset_at"])
        return (daily, weekly)
    }

    private static func currentQuotaWindow(percent: Any?, resetsAt: Any?) -> DevinQuotaWindow? {
        guard let usedPercent = self.double(percent) else { return nil }
        return DevinQuotaWindow(
            usedPercent: usedPercent <= 1 ? usedPercent * 100 : usedPercent,
            resetsAt: self.date(from: resetsAt))
    }

    private static func findWindow(in object: Any, matching keyMatches: (String) -> Bool) -> DevinQuotaWindow? {
        if let dictionary = object as? [String: Any] {
            for (key, value) in dictionary where keyMatches(key) {
                if let window = self.window(from: value) {
                    return window
                }
            }
            for value in dictionary.values {
                if let found = self.findWindow(in: value, matching: keyMatches) {
                    return found
                }
            }
        }

        if let array = object as? [Any] {
            for value in array {
                if let found = self.findWindow(in: value, matching: keyMatches) {
                    return found
                }
            }
        }

        return nil
    }

    private static func window(from object: Any) -> DevinQuotaWindow? {
        guard let dictionary = object as? [String: Any] else {
            guard let percent = self.percent(from: object) else { return nil }
            return DevinQuotaWindow(usedPercent: percent, resetsAt: nil)
        }

        if let percent = self.percent(from: dictionary) {
            return DevinQuotaWindow(
                usedPercent: percent,
                resetsAt: self.findResetDate(in: dictionary))
        }

        if let nested = dictionary.values.lazy.compactMap({ self.window(from: $0) }).first {
            return nested
        }

        return nil
    }

    private static func percent(from object: Any) -> Double? {
        if let number = self.double(object) {
            return number <= 1 ? number * 100 : number
        }
        guard let dictionary = object as? [String: Any] else { return nil }

        let directKeys = [
            "used_percent",
            "usedPercent",
            "usage_percent",
            "usagePercent",
            "percent_used",
            "percentUsed",
            "percent",
        ]
        for key in directKeys {
            if let value = self.double(dictionary[key]) {
                return value <= 1 ? value * 100 : value
            }
        }

        let remainingKeys = ["remaining_percent", "remainingPercent", "percent_remaining", "percentRemaining"]
        for key in remainingKeys {
            if let value = self.double(dictionary[key]) {
                let percent = value <= 1 ? value * 100 : value
                return 100 - percent
            }
        }

        let used = self.firstDouble(in: dictionary, keys: ["used", "usage", "used_count", "usedCount", "consumed"])
        let limit = self.firstDouble(in: dictionary, keys: ["limit", "quota", "total", "max", "available"])
        if let used, let limit, limit > 0 {
            return used / limit * 100
        }

        let remaining = self.firstDouble(in: dictionary, keys: ["remaining", "left", "available"])
        if let remaining, let limit, limit > 0 {
            return (limit - remaining) / limit * 100
        }

        return nil
    }

    private static func findPlanName(in object: Any) -> String? {
        if let dictionary = object as? [String: Any] {
            for key in ["plan_name", "planName", "plan", "tier", "subscription_tier", "subscriptionTier"] {
                if let value = dictionary[key] as? String,
                   let cleaned = self.cleanDisplay(value)
                {
                    return cleaned
                }
            }
            for value in dictionary.values {
                if let found = self.findPlanName(in: value) {
                    return found
                }
            }
        }

        if let array = object as? [Any] {
            for value in array {
                if let found = self.findPlanName(in: value) {
                    return found
                }
            }
        }

        return nil
    }

    private static func findResetDate(in dictionary: [String: Any]) -> Date? {
        for (key, value) in dictionary where key.localizedCaseInsensitiveContains("reset") {
            if let date = self.date(from: value) {
                return date
            }
        }
        return nil
    }

    private static func date(from value: Any?) -> Date? {
        if let raw = value as? String {
            if let date = ISO8601DateFormatter().date(from: raw) {
                return date
            }
            if let number = Double(raw) {
                return self.date(from: number)
            }
        }
        if let number = self.double(value) {
            return self.date(from: number)
        }
        return nil
    }

    private static func date(from number: Double) -> Date? {
        guard number > 0 else { return nil }
        let seconds = number > 10_000_000_000 ? number / 1000 : number
        return Date(timeIntervalSince1970: seconds)
    }

    private static func firstDouble(in dictionary: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let value = self.double(dictionary[key]) {
                return value
            }
        }
        return nil
    }

    private static func double(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            CFGetTypeID(number) == CFBooleanGetTypeID() ? nil : number.doubleValue
        case let string as String:
            Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            nil
        }
    }

    private static func isDailyKey(_ raw: String) -> Bool {
        let key = raw.lowercased()
        return !key.contains("hide") && (key.contains("daily") || key.contains("day"))
    }

    private static func isWeeklyKey(_ raw: String) -> Bool {
        let key = raw.lowercased()
        return !key.contains("hide") && (key.contains("weekly") || key.contains("week"))
    }

    private static func displayOrganization(from raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if raw.hasPrefix("org/") {
            return String(raw.dropFirst(4))
        }
        if raw.hasPrefix("organizations/") {
            return String(raw.dropFirst("organizations/".count))
        }
        return raw
    }

    private static func cleanDisplay(_ raw: String) -> String? {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return cleaned.split(separator: "_").flatMap { $0.split(separator: "-") }.map { part in
            part.prefix(1).uppercased() + String(part.dropFirst())
        }.joined(separator: " ")
    }
}
