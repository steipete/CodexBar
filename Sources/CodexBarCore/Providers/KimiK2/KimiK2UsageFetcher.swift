import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct KimiK2UsageSnapshot: Sendable {
    public let summary: KimiK2UsageSummary

    public init(summary: KimiK2UsageSummary) {
        self.summary = summary
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        self.summary.toUsageSnapshot()
    }
}

public struct KimiK2UsageSummary: Sendable {
    public let consumed: Double
    public let remaining: Double
    public let averageTokens: Double?
    public let updatedAt: Date

    public init(consumed: Double, remaining: Double, averageTokens: Double?, updatedAt: Date) {
        self.consumed = consumed
        self.remaining = remaining
        self.averageTokens = averageTokens
        self.updatedAt = updatedAt
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        let total = max(0, self.consumed + self.remaining)
        let usedPercent: Double = if total > 0 {
            min(100, max(0, (self.consumed / total) * 100))
        } else {
            0
        }
        let usedText = String(format: "%.0f", self.consumed)
        let totalText = String(format: "%.0f", total)
        let rateWindow = RateWindow(
            usedPercent: usedPercent,
            windowMinutes: nil,
            resetsAt: nil,
            resetDescription: total > 0 ? "Credits: \(usedText)/\(totalText)" : nil)
        let identity = ProviderIdentitySnapshot(
            providerID: .kimik2,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: nil)
        return UsageSnapshot(
            primary: rateWindow,
            secondary: nil,
            tertiary: nil,
            providerCost: nil,
            updatedAt: self.updatedAt,
            identity: identity)
    }
}

public enum KimiK2UsageError: LocalizedError, Sendable {
    case missingCredentials
    case networkError(String)
    case apiError(String)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "Missing Kimi K2 API key."
        case let .networkError(message):
            "Kimi K2 network error: \(message)"
        case let .apiError(message):
            "Kimi K2 API error: \(message)"
        case let .parseFailed(message):
            "Failed to parse Kimi K2 response: \(message)"
        }
    }
}

public struct KimiK2UsageFetcher: Sendable {
    private static let log = CodexBarLog.logger(LogCategories.kimiK2Usage)
    private static let creditsURL = URL(string: "https://kimi-k2.ai/api/user/credits")!
    private static let jsonSerializer = JSONSerialization.self
    private static let consumedPaths: [[String]] = [
        ["total_credits_consumed"],
        ["totalCreditsConsumed"],
        ["total_credits_used"],
        ["totalCreditsUsed"],
        ["credits_consumed"],
        ["creditsConsumed"],
        ["consumedCredits"],
        ["usedCredits"],
        ["total"],
        ["usage", "total"],
        ["usage", "consumed"],
    ]

    private static let remainingPaths: [[String]] = [
        ["credits_remaining"],
        ["creditsRemaining"],
        ["remaining_credits"],
        ["remainingCredits"],
        ["available_credits"],
        ["availableCredits"],
        ["credits_left"],
        ["creditsLeft"],
        ["usage", "credits_remaining"],
        ["usage", "remaining"],
    ]

    private static let averageTokenPaths: [[String]] = [
        ["average_tokens_per_request"],
        ["averageTokensPerRequest"],
        ["average_tokens"],
        ["averageTokens"],
        ["avg_tokens"],
        ["avgTokens"],
    ]

    private static let timestampPaths: [[String]] = [
        ["updated_at"],
        ["updatedAt"],
        ["timestamp"],
        ["time"],
        ["last_update"],
        ["lastUpdated"],
    ]

    public static func fetchUsage(apiKey: String) async throws -> KimiK2UsageSnapshot {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KimiK2UsageError.missingCredentials
        }

        var request = URLRequest(url: self.creditsURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw KimiK2UsageError.networkError("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            Self.log.error("Kimi K2 API returned \(httpResponse.statusCode): \(body)")
            throw KimiK2UsageError.apiError(body)
        }

        if let jsonString = String(data: data, encoding: .utf8) {
            Self.log.debug("Kimi K2 API response: \(jsonString)")
        }

        let summary = try Self.parseSummary(data: data, headers: httpResponse.allHeaderFields)
        return KimiK2UsageSnapshot(summary: summary)
    }

    static func _parseSummaryForTesting(_ data: Data, headers: [AnyHashable: Any] = [:]) throws -> KimiK2UsageSummary {
        try self.parseSummary(data: data, headers: headers)
    }

    private static func parseSummary(data: Data, headers: [AnyHashable: Any]) throws -> KimiK2UsageSummary {
        guard let json = try? jsonSerializer.jsonObject(with: data),
              let dictionary = json as? [String: Any]
        else {
            throw KimiK2UsageError.parseFailed("Root JSON is not an object.")
        }

        let contexts = Self.contexts(from: dictionary)
        let consumed = Self.doubleValue(for: Self.consumedPaths, in: contexts) ?? 0
        let remaining = Self.doubleValue(for: Self.remainingPaths, in: contexts)
            ?? Self.doubleValueFromHeaders(headers: headers, key: "x-credits-remaining")
            ?? 0
        let averageTokens = Self.doubleValue(for: Self.averageTokenPaths, in: contexts)
        let updatedAt = Self.dateValue(for: Self.timestampPaths, in: contexts) ?? Date()

        return KimiK2UsageSummary(
            consumed: consumed,
            remaining: max(0, remaining),
            averageTokens: averageTokens,
            updatedAt: updatedAt)
    }

    private static func contexts(from dictionary: [String: Any]) -> [[String: Any]] {
        var contexts: [[String: Any]] = [dictionary]
        if let data = dictionary["data"] as? [String: Any] {
            contexts.append(data)
            if let dataUsage = data["usage"] as? [String: Any] {
                contexts.append(dataUsage)
            }
            if let dataCredits = data["credits"] as? [String: Any] {
                contexts.append(dataCredits)
            }
        }
        if let result = dictionary["result"] as? [String: Any] {
            contexts.append(result)
            if let resultUsage = result["usage"] as? [String: Any] {
                contexts.append(resultUsage)
            }
            if let resultCredits = result["credits"] as? [String: Any] {
                contexts.append(resultCredits)
            }
        }
        if let usage = dictionary["usage"] as? [String: Any] {
            contexts.append(usage)
        }
        if let credits = dictionary["credits"] as? [String: Any] {
            contexts.append(credits)
        }
        return contexts
    }

    private static func doubleValue(
        for paths: [[String]],
        in contexts: [[String: Any]]) -> Double?
    {
        for path in paths {
            if let raw = self.value(for: path, in: contexts),
               let value = self.double(from: raw)
            {
                return value
            }
        }
        return nil
    }

    private static func dateValue(
        for paths: [[String]],
        in contexts: [[String: Any]]) -> Date?
    {
        for path in paths {
            if let raw = self.value(for: path, in: contexts) {
                if let date = self.date(from: raw) {
                    return date
                }
            }
        }
        return nil
    }

    private static func value(for path: [String], in contexts: [[String: Any]]) -> Any? {
        for context in contexts {
            var cursor: Any? = context
            for key in path {
                if let dict = cursor as? [String: Any] {
                    cursor = dict[key]
                } else {
                    cursor = nil
                }
            }
            if cursor != nil {
                return cursor
            }
        }
        return nil
    }

    private static func double(from raw: Any) -> Double? {
        if let value = raw as? Double {
            return value
        }
        if let value = raw as? Int {
            return Double(value)
        }
        if let value = raw as? String {
            return Double(value)
        }
        return nil
    }

    private static func date(from raw: Any) -> Date? {
        if let value = raw as? Date {
            return value
        }
        if let value = raw as? Double {
            return self.dateFromNumeric(value)
        }
        if let value = raw as? Int {
            return self.dateFromNumeric(Double(value))
        }
        if let value = raw as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if let numeric = Double(trimmed) {
                return self.dateFromNumeric(numeric)
            }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) {
                return date
            }
            let fallback = ISO8601DateFormatter()
            fallback.formatOptions = [.withInternetDateTime]
            return fallback.date(from: value)
        }
        return nil
    }

    private static func dateFromNumeric(_ value: Double) -> Date? {
        guard value > 0 else { return nil }
        if value > 1_000_000_000_000 {
            return Date(timeIntervalSince1970: value / 1000)
        }
        return Date(timeIntervalSince1970: value)
    }

    private static func doubleValueFromHeaders(headers: [AnyHashable: Any], key: String) -> Double? {
        for (headerKey, value) in headers {
            guard let headerKey = headerKey as? String else { continue }
            if headerKey.lowercased() == key.lowercased() {
                return self.double(from: value)
            }
        }
        return nil
    }
}
