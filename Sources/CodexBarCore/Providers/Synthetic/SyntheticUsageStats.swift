import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct SyntheticQuotaEntry: Sendable {
    public let label: String?
    public let usedPercent: Double
    public let windowMinutes: Int?
    public let resetsAt: Date?
    public let resetDescription: String?

    public init(
        label: String?,
        usedPercent: Double,
        windowMinutes: Int?,
        resetsAt: Date?,
        resetDescription: String?)
    {
        self.label = label
        self.usedPercent = usedPercent
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
        self.resetDescription = resetDescription
    }
}

public struct SyntheticUsageSnapshot: Sendable {
    public let quotas: [SyntheticQuotaEntry]
    public let planName: String?
    public let updatedAt: Date

    public init(quotas: [SyntheticQuotaEntry], planName: String?, updatedAt: Date) {
        self.quotas = quotas
        self.planName = planName
        self.updatedAt = updatedAt
    }
}

extension SyntheticUsageSnapshot {
    public func toUsageSnapshot() -> UsageSnapshot {
        let primaryEntry = self.quotas.first
        let secondaryEntry = self.quotas.dropFirst().first

        let primary = primaryEntry.map(Self.rateWindow(for:))
        let secondary = secondaryEntry.map(Self.rateWindow(for:))

        let planName = self.planName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let loginMethod = (planName?.isEmpty ?? true) ? nil : planName
        let identity = ProviderIdentitySnapshot(
            providerID: .synthetic,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: loginMethod)

        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            tertiary: nil,
            providerCost: nil,
            updatedAt: self.updatedAt,
            identity: identity)
    }

    private static func rateWindow(for quota: SyntheticQuotaEntry) -> RateWindow {
        RateWindow(
            usedPercent: quota.usedPercent,
            windowMinutes: quota.windowMinutes,
            resetsAt: quota.resetsAt,
            resetDescription: quota.resetDescription)
    }
}

public struct SyntheticUsageFetcher: Sendable {
    private static let log = CodexBarLog.logger(LogCategories.syntheticUsage)
    private static let quotaAPIURL = "https://api.synthetic.new/v2/quotas"

    public static func fetchUsage(apiKey: String, now: Date = Date()) async throws -> SyntheticUsageSnapshot {
        guard !apiKey.isEmpty else {
            throw SyntheticUsageError.invalidCredentials
        }

        var request = URLRequest(url: URL(string: Self.quotaAPIURL)!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SyntheticUsageError.networkError("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            Self.log.error("Synthetic API returned \(httpResponse.statusCode): \(errorMessage)")
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw SyntheticUsageError.invalidCredentials
            }
            throw SyntheticUsageError.apiError("HTTP \(httpResponse.statusCode): \(errorMessage)")
        }

        do {
            return try SyntheticUsageParser.parse(data: data, now: now)
        } catch let error as SyntheticUsageError {
            throw error
        } catch {
            Self.log.error("Synthetic parsing error: \(error.localizedDescription)")
            throw SyntheticUsageError.parseFailed(error.localizedDescription)
        }
    }
}

private final class SyntheticISO8601FormatterBox: @unchecked Sendable {
    let lock = NSLock()
    let withFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

private enum SyntheticTimestampParser {
    static let box = SyntheticISO8601FormatterBox()

    static func parse(_ text: String) -> Date? {
        self.box.lock.lock()
        defer { self.box.lock.unlock() }
        return self.box.withFractional.date(from: text) ?? self.box.plain.date(from: text)
    }
}

enum SyntheticUsageParser {
    static func parse(data: Data, now: Date = Date()) throws -> SyntheticUsageSnapshot {
        let object = try JSONSerialization.jsonObject(with: data, options: [])

        let root: [String: Any] = {
            if let dict = object as? [String: Any] { return dict }
            if let array = object as? [Any] { return ["quotas": array] }
            return [:]
        }()

        let planName = self.planName(from: root)
        let quotaObjects = self.quotaObjects(from: root)
        let quotas = quotaObjects.compactMap { self.parseQuota($0) }

        guard !quotas.isEmpty else {
            throw SyntheticUsageError.parseFailed("Missing quota data.")
        }

        return SyntheticUsageSnapshot(
            quotas: quotas,
            planName: planName,
            updatedAt: now)
    }

    private static func quotaObjects(from root: [String: Any]) -> [[String: Any]] {
        let dataDict = root["data"] as? [String: Any]
        let candidates: [Any?] = [
            root["quotas"],
            root["quota"],
            root["limits"],
            root["usage"],
            root["entries"],
            root["subscription"],
            root["data"],
            dataDict?["quotas"],
            dataDict?["quota"],
            dataDict?["limits"],
            dataDict?["usage"],
            dataDict?["entries"],
            dataDict?["subscription"],
        ]

        for candidate in candidates {
            if let array = candidate as? [[String: Any]] { return array }
            if let array = candidate as? [Any] {
                let dicts = array.compactMap { $0 as? [String: Any] }
                if !dicts.isEmpty { return dicts }
            }
            if let dict = candidate as? [String: Any], self.isQuotaPayload(dict) {
                return [dict]
            }
        }
        return []
    }

    private static func planName(from root: [String: Any]) -> String? {
        if let direct = self.firstString(in: root, keys: planKeys) { return direct }
        if let dataDict = root["data"] as? [String: Any],
           let plan = self.firstString(in: dataDict, keys: planKeys)
        {
            return plan
        }
        return nil
    }

    private static func parseQuota(_ payload: [String: Any]) -> SyntheticQuotaEntry? {
        let label = self.firstString(in: payload, keys: Self.labelKeys)

        let percentUsed = self.normalizedPercent(
            self.firstDouble(in: payload, keys: Self.percentUsedKeys))
        let percentRemaining = self.normalizedPercent(
            self.firstDouble(in: payload, keys: Self.percentRemainingKeys))

        var usedPercent = percentUsed
        if usedPercent == nil, let remaining = percentRemaining {
            usedPercent = 100 - remaining
        }

        if usedPercent == nil {
            var limit = self.firstDouble(in: payload, keys: Self.limitKeys)
            var used = self.firstDouble(in: payload, keys: Self.usedKeys)
            var remaining = self.firstDouble(in: payload, keys: Self.remainingKeys)

            if limit == nil, let used, let remaining {
                limit = used + remaining
            }
            if used == nil, let limit, let remaining {
                used = limit - remaining
            }
            if remaining == nil, let limit, let used {
                remaining = max(0, limit - used)
            }

            if let limit, let used, limit > 0 {
                usedPercent = (used / limit) * 100
            }
        }

        guard let usedPercent else { return nil }
        let clamped = max(0, min(usedPercent, 100))

        let windowMinutes = windowMinutes(from: payload)
        let resetsAt = self.firstDate(in: payload, keys: self.resetKeys)
        let resetDescription = resetsAt == nil ? self.windowDescription(minutes: windowMinutes) : nil

        return SyntheticQuotaEntry(
            label: label,
            usedPercent: clamped,
            windowMinutes: windowMinutes,
            resetsAt: resetsAt,
            resetDescription: resetDescription)
    }

    private static func isQuotaPayload(_ payload: [String: Any]) -> Bool {
        let checks = [
            Self.limitKeys,
            Self.usedKeys,
            Self.remainingKeys,
            Self.percentUsedKeys,
            Self.percentRemainingKeys,
        ]
        return checks.contains { self.firstDouble(in: payload, keys: $0) != nil }
    }

    private static func windowMinutes(from payload: [String: Any]) -> Int? {
        if let minutes = self.firstInt(in: payload, keys: windowMinutesKeys) { return minutes }
        if let hours = self.firstDouble(in: payload, keys: windowHoursKeys) {
            return Int((hours * 60).rounded())
        }
        if let days = self.firstDouble(in: payload, keys: windowDaysKeys) {
            return Int((days * 24 * 60).rounded())
        }
        if let seconds = self.firstDouble(in: payload, keys: windowSecondsKeys) {
            return Int((seconds / 60).rounded())
        }
        return nil
    }

    private static func windowDescription(minutes: Int?) -> String? {
        guard let minutes, minutes > 0 else { return nil }
        let dayMinutes = 24 * 60
        if minutes % dayMinutes == 0 {
            let days = minutes / dayMinutes
            return "\(days) day\(days == 1 ? "" : "s") window"
        }
        if minutes % 60 == 0 {
            let hours = minutes / 60
            return "\(hours) hour\(hours == 1 ? "" : "s") window"
        }
        return "\(minutes) minute\(minutes == 1 ? "" : "s") window"
    }

    private static func normalizedPercent(_ value: Double?) -> Double? {
        guard let value else { return nil }
        if value <= 1 { return value * 100 }
        return value
    }

    private static func firstString(in payload: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = self.stringValue(payload[key]) { return value }
        }
        return nil
    }

    private static func firstDouble(in payload: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let value = self.doubleValue(payload[key]) { return value }
        }
        return nil
    }

    private static func firstInt(in payload: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            if let value = self.intValue(payload[key]) { return value }
        }
        return nil
    }

    private static func firstDate(in payload: [String: Any], keys: [String]) -> Date? {
        for key in keys {
            if let value = payload[key],
               let date = self.dateValue(value)
            {
                return date
            }
        }
        return nil
    }

    private static func stringValue(_ raw: Any?) -> String? {
        guard let raw else { return nil }
        if let string = raw as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    private static func doubleValue(_ raw: Any?) -> Double? {
        switch raw {
        case let number as Double:
            return number
        case let number as NSNumber:
            return number.doubleValue
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return Double(trimmed)
        default:
            return nil
        }
    }

    private static func intValue(_ raw: Any?) -> Int? {
        switch raw {
        case let number as Int:
            return number
        case let number as NSNumber:
            return number.intValue
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return Int(trimmed)
        default:
            return nil
        }
    }

    private static func dateValue(_ raw: Any) -> Date? {
        if let number = self.doubleValue(raw) {
            if number > 1_000_000_000_000 {
                return Date(timeIntervalSince1970: number / 1000)
            }
            if number > 1_000_000_000 {
                return Date(timeIntervalSince1970: number)
            }
        }
        if let string = raw as? String {
            if let number = Double(string.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return self.dateValue(number)
            }
            if let date = SyntheticTimestampParser.parse(string) {
                return date
            }
        }
        return nil
    }

    private static let planKeys = [
        "plan",
        "planName",
        "plan_name",
        "subscription",
        "subscriptionPlan",
        "tier",
        "package",
        "packageName",
    ]

    private static let labelKeys = [
        "name",
        "label",
        "type",
        "period",
        "scope",
        "title",
        "id",
    ]

    private static let percentUsedKeys = [
        "percentUsed",
        "usedPercent",
        "usagePercent",
        "usage_percent",
        "used_percent",
        "percent_used",
        "percent",
    ]

    private static let percentRemainingKeys = [
        "percentRemaining",
        "remainingPercent",
        "remaining_percent",
        "percent_remaining",
    ]

    private static let limitKeys = [
        "limit",
        "quota",
        "max",
        "total",
        "capacity",
        "allowance",
    ]

    private static let usedKeys = [
        "used",
        "usage",
        "requests",
        "requestCount",
        "request_count",
        "consumed",
        "spent",
    ]

    private static let remainingKeys = [
        "remaining",
        "left",
        "available",
        "balance",
    ]

    private static let resetKeys = [
        "resetAt",
        "reset_at",
        "resetsAt",
        "resets_at",
        "renewAt",
        "renew_at",
        "renewsAt",
        "renews_at",
        "periodEnd",
        "period_end",
        "expiresAt",
        "expires_at",
        "endAt",
        "end_at",
    ]

    private static let windowMinutesKeys = [
        "windowMinutes",
        "window_minutes",
        "periodMinutes",
        "period_minutes",
    ]

    private static let windowHoursKeys = [
        "windowHours",
        "window_hours",
        "periodHours",
        "period_hours",
    ]

    private static let windowDaysKeys = [
        "windowDays",
        "window_days",
        "periodDays",
        "period_days",
    ]

    private static let windowSecondsKeys = [
        "windowSeconds",
        "window_seconds",
        "periodSeconds",
        "period_seconds",
    ]
}

public enum SyntheticUsageError: LocalizedError, Sendable {
    case invalidCredentials
    case networkError(String)
    case apiError(String)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            "Invalid Synthetic API credentials"
        case let .networkError(message):
            "Synthetic network error: \(message)"
        case let .apiError(message):
            "Synthetic API error: \(message)"
        case let .parseFailed(message):
            "Failed to parse Synthetic response: \(message)"
        }
    }
}
