import CodexBarCore
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct KimiUsageSnapshot: Sendable {
    public let summary: KimiUsageSummary

    public init(summary: KimiUsageSummary) {
        self.summary = summary
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        self.summary.toUsageSnapshot()
    }
}

private struct KimiUsageSummary: Sendable {
    let consumed: Double
    let remaining: Double
    let averageTokens: Double?
    let updatedAt: Date

    func toUsageSnapshot() -> UsageSnapshot {
        let total = max(0, self.consumed + self.remaining)
        let usedPercent: Double
        if total > 0 {
            usedPercent = min(100, max(0, (self.consumed / total) * 100))
        } else {
            usedPercent = 0
        }
        let rateWindow = RateWindow(
            usedPercent: usedPercent,
            windowMinutes: nil,
            resetsAt: nil,
            resetDescription: nil)
        return UsageSnapshot(
            primary: rateWindow,
            secondary: nil,
            updatedAt: self.updatedAt)
    }
}

public enum KimiUsageError: LocalizedError, Sendable {
    case missingCredentials
    case networkError(String)
    case apiError(String)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "Missing Kimi API key."
        case let .networkError(message):
            "Kimi network error: \(message)"
        case let .apiError(message):
            "Kimi API error: \(message)"
        case let .parseFailed(message):
            "Failed to parse Kimi response: \(message)"
        }
    }
}

public struct KimiUsageFetcher: Sendable {
    private static let log = CodexBarLog.logger("kimi-usage")
    private static let creditsURL = URL(string: "https://kimi-k2.ai/api/user/credits")!
    private static let jsonSerializer = JSONSerialization.self
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

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
        ["usage", "consumed"]
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
        ["usage", "remaining"]
    ]

    private static let averageTokenPaths: [[String]] = [
        ["average_tokens_per_request"],
        ["averageTokensPerRequest"],
        ["average_tokens"],
        ["averageTokens"],
        ["avg_tokens"],
        ["avgTokens"]
    ]

    private static let timestampPaths: [[String]] = [
        ["updated_at"],
        ["updatedAt"],
        ["timestamp"],
        ["time"],
        ["last_update"],
        ["lastUpdated"]
    ]

    public static func fetchUsage(apiKey: String) async throws -> KimiUsageSnapshot {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KimiUsageError.missingCredentials
        }

        var request = URLRequest(url: self.creditsURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw KimiUsageError.networkError("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            Self.log.error("Kimi API returned \(httpResponse.statusCode): \(body)")
            throw KimiUsageError.apiError(body)
        }

        if let jsonString = String(data: data, encoding: .utf8) {
            Self.log.debug("Kimi API response: \(jsonString)")
        }

        let summary = try Self.parseSummary(data: data, headers: httpResponse.allHeaderFields)
        return KimiUsageSnapshot(summary: summary)
    }

    private static func parseSummary(data: Data, headers: [AnyHashable: Any]) throws -> KimiUsageSummary {
        guard let json = try? Self.jsonSerializer.jsonObject(with: data),
              let dictionary = json as? [String: Any]
        else {
            throw KimiUsageError.parseFailed("Root JSON is not an object.")
        }

        let contexts = Self.contexts(from: dictionary)
        let consumed = Self.doubleValue(for: Self.consumedPaths, in: contexts) ?? 0
        let remaining = Self.doubleValue(for: Self.remainingPaths, in: contexts)
            ?? Self.doubleValueFromHeaders(headers: headers, key: "x-credits-remaining")
            ?? 0
        let averageTokens = Self.doubleValue(for: Self.averageTokenPaths, in: contexts)
        let updatedAt = Self.dateValue(for: Self.timestampPaths, in: contexts) ?? Date()

        return KimiUsageSummary(
            consumed: consumed,
            remaining: max(0, remaining),
            averageTokens: averageTokens,
            updatedAt: updatedAt)
    }

    private static func contexts(from dictionary: [String: Any]) -> [[String: Any]] {
        var contexts: [[String: Any]] = [dictionary]
        if let data = dictionary["data"] as? [String: Any] {
            contexts.append(data)
        }
        if let result = dictionary["result"] as? [String: Any] {
            contexts.append(result)
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
        in contexts: [[String: Any]]
    ) -> Double?
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
        in contexts: [[String: Any]]
    ) -> Date?
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
            var current: Any? = context
            for key in path {
                guard let dict = current as? [String: Any] else {
                    current = nil
                    break
                }
                current = dict[key]
            }
            if let current {
                return current
            }
        }
        return nil
    }

    private static func doubleValueFromHeaders(headers: [AnyHashable: Any], key: String) -> Double? {
        for (headerKey, headerValue) in headers {
            guard let name = headerKey as? String,
                  name.caseInsensitiveCompare(key) == .orderedSame
            else {
                continue
            }
            if let value = self.double(from: headerValue) {
                return value
            }
            if let string = headerValue as? String, let double = Double(string) {
                return double
            }
        }
        return nil
    }

    private static func double(from raw: Any) -> Double? {
        if let number = raw as? NSNumber {
            return number.doubleValue
        }
        if let string = raw as? String {
            return Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let int = raw as? Int {
            return Double(int)
        }
        if let double = raw as? Double {
            return double
        }
        return nil
    }

    private static func date(from raw: Any) -> Date? {
        if let number = self.double(from: raw) {
            let interval: TimeInterval
            if number > 1_000_000_000_000 {
                interval = number / 1000
            } else {
                interval = number
            }
            return Date(timeIntervalSince1970: interval)
        }
        if let string = raw as? String {
            if let numeric = Double(string.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return self.date(from: numeric)
            }
            if let date = self.formatter.date(from: string) {
                return date
            }
        }
        return nil
    }
}
