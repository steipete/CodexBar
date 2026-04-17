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
    public let cost: ProviderCostSnapshot?

    public init(
        label: String?,
        usedPercent: Double,
        windowMinutes: Int?,
        resetsAt: Date?,
        resetDescription: String?,
        cost: ProviderCostSnapshot? = nil)
    {
        self.label = label
        self.usedPercent = usedPercent
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
        self.resetDescription = resetDescription
        self.cost = cost
    }
}

public struct SyntheticUsageSnapshot: Sendable {
    public let quotas: [SyntheticQuotaEntry]
    /// Slot-identified lanes for the known Synthetic response shape: [rolling-5h, weekly, search-hourly].
    /// When set, `toUsageSnapshot` maps slot 0 → primary, slot 1 → secondary, slot 2 → tertiary,
    /// so a missing lane stays nil instead of promoting the next lane into the wrong UI label.
    public let slottedQuotas: [SyntheticQuotaEntry?]?
    public let planName: String?
    public let updatedAt: Date

    public init(
        quotas: [SyntheticQuotaEntry],
        slottedQuotas: [SyntheticQuotaEntry?]? = nil,
        planName: String?,
        updatedAt: Date)
    {
        self.quotas = quotas
        self.slottedQuotas = slottedQuotas
        self.planName = planName
        self.updatedAt = updatedAt
    }
}

extension SyntheticUsageSnapshot {
    public func toUsageSnapshot() -> UsageSnapshot {
        let slots = self.slottedQuotas
            ?? [self.quotas.first, self.quotas.dropFirst().first, self.quotas.dropFirst(2).first]
        let entries: [SyntheticQuotaEntry?] = (0..<3).map { slots.indices.contains($0) ? slots[$0] : nil }

        let primary = entries[0].map(Self.rateWindow(for:))
        let secondary = entries[1].map(Self.rateWindow(for:))
        let tertiary = entries[2].map(Self.rateWindow(for:))

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
            tertiary: tertiary,
            providerCost: self.quotas.first(where: { $0.cost != nil })?.cost,
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

        if let slots = self.prioritizedQuotaSlots(from: root) {
            let slotted: [SyntheticQuotaEntry?] = slots.map { $0.flatMap(self.parseQuota) }
            let flat = slotted.compactMap(\.self)
            guard !flat.isEmpty else {
                throw SyntheticUsageError.parseFailed("Missing quota data.")
            }
            return SyntheticUsageSnapshot(
                quotas: flat,
                slottedQuotas: slotted,
                planName: planName,
                updatedAt: now)
        }

        let quotas = self.fallbackQuotaObjects(from: root).compactMap(self.parseQuota)
        guard !quotas.isEmpty else {
            throw SyntheticUsageError.parseFailed("Missing quota data.")
        }
        return SyntheticUsageSnapshot(
            quotas: quotas,
            planName: planName,
            updatedAt: now)
    }

    /// Returns slot-positional quota payloads `[rolling-5h, weekly, search-hourly]` when the known Synthetic
    /// response shape is detected. Missing lanes stay nil in their slot so downstream code doesn't shift
    /// labels. Returns nil if none of the known keys appear, so the fallback path runs.
    private static func prioritizedQuotaSlots(from root: [String: Any]) -> [[String: Any]?]? {
        let dataDict = root["data"] as? [String: Any]
        let rolling = self.namedQuota(root["rollingFiveHourLimit"], label: "Rolling five-hour limit")
            ?? self.namedQuota(dataDict?["rollingFiveHourLimit"], label: "Rolling five-hour limit")
        let weekly = self.namedQuota(root["weeklyTokenLimit"], label: "Weekly token limit")
            ?? self.namedQuota(dataDict?["weeklyTokenLimit"], label: "Weekly token limit")
        let searchHourly = self.namedQuota((root["search"] as? [String: Any])?["hourly"], label: "Search hourly")
            ?? self.namedQuota((dataDict?["search"] as? [String: Any])?["hourly"], label: "Search hourly")
        let slots: [[String: Any]?] = [rolling, weekly, searchHourly]
        return slots.contains(where: { $0 != nil }) ? slots : nil
    }

    private static func fallbackQuotaObjects(from root: [String: Any]) -> [[String: Any]] {
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
            let quotas = self.extractQuotaObjects(from: candidate)
            if !quotas.isEmpty { return quotas }
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
        // Leave resetDescription nil when resetsAt is set so the UI rebuilds the countdown each render
        // against the current clock instead of freezing a stale "in Xm" string at parse time.
        let resetDescription = resetsAt == nil ? self.windowDescription(minutes: windowMinutes) : nil

        let cost = self.providerCost(from: payload, usedPercent: clamped, resetsAt: resetsAt)

        return SyntheticQuotaEntry(
            label: label,
            usedPercent: clamped,
            windowMinutes: windowMinutes,
            resetsAt: resetsAt,
            resetDescription: resetDescription,
            cost: cost)
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
        if let text = self.firstString(in: payload, keys: windowStringKeys) {
            return self.windowMinutes(from: text)
        }
        return nil
    }

    private static func namedQuota(_ candidate: Any?, label: String) -> [String: Any]? {
        guard var payload = candidate as? [String: Any], self.isQuotaPayload(payload) else { return nil }
        if payload["label"] == nil, payload["name"] == nil {
            payload["label"] = label
        }
        return payload
    }

    private static func extractQuotaObjects(from candidate: Any?) -> [[String: Any]] {
        switch candidate {
        case let array as [[String: Any]]:
            var nestedQuotas: [[String: Any]] = []
            for entry in array {
                if self.isQuotaPayload(entry) {
                    nestedQuotas.append(entry)
                } else {
                    nestedQuotas.append(contentsOf: self.extractQuotaObjects(from: entry))
                }
            }
            return nestedQuotas
        case let array as [Any]:
            return array.flatMap { self.extractQuotaObjects(from: $0) }
        case let dict as [String: Any]:
            if self.isQuotaPayload(dict) {
                return [dict]
            }
            var nestedQuotas: [[String: Any]] = []
            for key in dict.keys.sorted() {
                nestedQuotas.append(contentsOf: self.extractQuotaObjects(from: dict[key]))
            }
            return nestedQuotas
        default:
            return []
        }
    }

    private static func windowMinutes(from text: String) -> Int? {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
        guard !normalized.isEmpty else { return nil }

        let unitMappings: [(suffixes: [String], multiplier: Double)] = [
            (["minutes", "minute", "mins", "min", "m"], 1),
            (["hours", "hour", "hrs", "hr", "h"], 60),
            (["days", "day", "d"], 24 * 60),
        ]

        for mapping in unitMappings {
            for suffix in mapping.suffixes {
                guard normalized.hasSuffix(suffix) else { continue }
                let valueText = String(normalized.dropLast(suffix.count))
                guard let value = Double(valueText), value > 0 else { return nil }
                return Int((value * mapping.multiplier).rounded())
            }
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

    private static func providerCost(
        from payload: [String: Any],
        usedPercent: Double,
        resetsAt: Date?) -> ProviderCostSnapshot?
    {
        guard let limit = self.firstCurrency(in: payload, keys: self.costLimitKeys) else { return nil }

        let remaining = self.firstCurrency(in: payload, keys: self.costRemainingKeys)
        let usedFromPayload = self.firstCurrency(in: payload, keys: self.costUsedKeys)
        let nextRegenAmount = self.firstCurrency(in: payload, keys: self.regenAmountKeys)
        let used = if let usedFromPayload {
            usedFromPayload
        } else if let remaining {
            max(0, limit - remaining)
        } else {
            (usedPercent.clamped(to: 0...100) / 100) * limit
        }

        return ProviderCostSnapshot(
            used: used,
            limit: limit,
            currencyCode: "USD",
            period: "Weekly",
            resetsAt: resetsAt,
            nextRegenAmount: nextRegenAmount,
            updatedAt: Date())
    }

    private static func firstCurrency(in payload: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            guard let value = payload[key] else { continue }
            if let text = value as? String,
               let parsed = self.parseCurrency(text)
            {
                return parsed
            }
            if let number = self.doubleValue(value) {
                return number
            }
        }
        return nil
    }

    private static func parseCurrency(_ text: String) -> Double? {
        let cleaned = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
        return Double(cleaned)
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
        "messageLimit",
        "message_limit",
        "messages",
        "maxRequests",
        "max_requests",
        "requestLimit",
        "request_limit",
        "quota",
        "max",
        "total",
        "capacity",
        "allowance",
    ]

    private static let usedKeys = [
        "used",
        "usage",
        "usedMessages",
        "used_messages",
        "messagesUsed",
        "messages_used",
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
        "nextTickAt",
        "next_tick_at",
        "nextRegenAt",
        "next_regen_at",
        "periodEnd",
        "period_end",
        "expiresAt",
        "expires_at",
        "endAt",
        "end_at",
    ]

    private static let regenAmountKeys = [
        "nextRegenCredits",
        "next_regen_credits",
    ]

    private static let costLimitKeys = [
        "maxCredits",
        "max_credits",
    ]

    private static let costRemainingKeys = [
        "remainingCredits",
        "remaining_credits",
    ]

    private static let costUsedKeys = [
        "usedCredits",
        "used_credits",
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

    private static let windowStringKeys = [
        "window",
        "windowLabel",
        "window_label",
        "period",
        "periodLabel",
        "period_label",
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
