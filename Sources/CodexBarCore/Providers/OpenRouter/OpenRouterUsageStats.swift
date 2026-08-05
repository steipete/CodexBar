// Linux compatibility only. JavaScriptCore platforms use the bundled OpenRouter plugin.
#if !canImport(JavaScriptCore)
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// OpenRouter credits API response
public struct OpenRouterCreditsResponse: Decodable, Sendable {
    public let data: OpenRouterCreditsData
}

/// OpenRouter credits data
public struct OpenRouterCreditsData: Decodable, Sendable {
    /// Total credits ever added to the account (in USD)
    public let totalCredits: Double
    /// Total credits used (in USD)
    public let totalUsage: Double

    private enum CodingKeys: String, CodingKey {
        case totalCredits = "total_credits"
        case totalUsage = "total_usage"
    }

    /// Remaining credits (total - usage)
    public var balance: Double {
        max(0, self.totalCredits - self.totalUsage)
    }

    /// Usage percentage (0-100)
    public var usedPercent: Double {
        guard self.totalCredits > 0 else { return 0 }
        return min(100, (self.totalUsage / self.totalCredits) * 100)
    }
}

/// OpenRouter key info API response
public struct OpenRouterKeyResponse: Decodable, Sendable {
    public let data: OpenRouterKeyData
}

/// OpenRouter key data with quota and rate limit info
public struct OpenRouterKeyData: Decodable, Sendable {
    /// Rate limit per interval
    public let rateLimit: OpenRouterRateLimit?
    /// Usage limits
    public let limit: Double?
    /// Remaining usage for the current limit window, as reported by the server.
    public let limitRemaining: Double?
    /// Limit reset window (e.g., "monthly") reported by the server.
    public let limitReset: String?
    /// Current usage
    public let usage: Double?
    /// API key usage for the current UTC day.
    public let usageDaily: Double?
    /// API key usage for the current UTC week.
    public let usageWeekly: Double?
    /// API key usage for the current UTC month.
    public let usageMonthly: Double?

    private enum CodingKeys: String, CodingKey {
        case rateLimit = "rate_limit"
        case limit
        case limitRemaining = "limit_remaining"
        case limitReset = "limit_reset"
        case usage
        case usageDaily = "usage_daily"
        case usageWeekly = "usage_weekly"
        case usageMonthly = "usage_monthly"
    }
}

/// OpenRouter rate limit info
public struct OpenRouterRateLimit: Codable, Sendable {
    /// Number of requests allowed
    public let requests: Int
    /// Interval for the rate limit (e.g., "10s", "1m")
    public let interval: String

    public init(requests: Int, interval: String) {
        self.requests = requests
        self.interval = interval
    }
}

public enum OpenRouterKeyQuotaStatus: String, Codable, Sendable {
    case available
    case noLimitConfigured
    case unavailable
}

/// Complete OpenRouter usage snapshot
public struct OpenRouterUsageSnapshot: Codable, Sendable {
    public let totalCredits: Double
    public let totalUsage: Double
    public let balance: Double
    public let usedPercent: Double
    public let keyDataFetched: Bool
    public let keyLimit: Double?
    public let keyLimitRemaining: Double?
    public let keyLimitReset: String?
    public let keyUsage: Double?
    public let keyUsageDaily: Double?
    public let keyUsageWeekly: Double?
    public let keyUsageMonthly: Double?
    public let rateLimit: OpenRouterRateLimit?
    public let updatedAt: Date

    public init(
        totalCredits: Double,
        totalUsage: Double,
        balance: Double,
        usedPercent: Double,
        keyDataFetched: Bool = false,
        keyLimit: Double? = nil,
        keyLimitRemaining: Double? = nil,
        keyLimitReset: String? = nil,
        keyUsage: Double? = nil,
        keyUsageDaily: Double? = nil,
        keyUsageWeekly: Double? = nil,
        keyUsageMonthly: Double? = nil,
        rateLimit: OpenRouterRateLimit?,
        updatedAt: Date)
    {
        self.totalCredits = totalCredits
        self.totalUsage = totalUsage
        self.balance = balance
        self.usedPercent = usedPercent
        self.keyDataFetched = keyDataFetched || keyLimit != nil || keyLimitRemaining != nil || keyUsage != nil ||
            keyUsageDaily != nil || keyUsageWeekly != nil || keyUsageMonthly != nil
        self.keyLimit = keyLimit
        self.keyLimitRemaining = keyLimitRemaining
        self.keyLimitReset = keyLimitReset
        self.keyUsage = keyUsage
        self.keyUsageDaily = keyUsageDaily
        self.keyUsageWeekly = keyUsageWeekly
        self.keyUsageMonthly = keyUsageMonthly
        self.rateLimit = rateLimit
        self.updatedAt = updatedAt
    }

    /// Returns true if this snapshot contains valid data
    public var isValid: Bool {
        self.totalCredits >= 0
    }

    public var hasValidKeyQuota: Bool {
        guard self.keyDataFetched, let keyLimit else {
            return false
        }
        guard keyLimit > 0 else { return false }
        if let keyLimitRemaining {
            // A finite negative value means the key is overspent: treat it as valid quota
            // and clamp the rendered remaining amount to zero.
            return keyLimitRemaining.isFinite
        }
        // Validate the selected fallback value (reset-window usage when declared,
        // otherwise cumulative usage) so the meter renders whenever a quota source exists.
        guard let fallbackUsage = self.quotaFallbackUsage else { return false }
        return fallbackUsage >= 0
    }

    public var keyQuotaStatus: OpenRouterKeyQuotaStatus {
        if self.hasValidKeyQuota {
            return .available
        }
        guard self.keyDataFetched else {
            return .unavailable
        }
        if let keyLimit, keyLimit > 0 {
            return .unavailable
        }
        return .noLimitConfigured
    }

    public var keyRemaining: Double? {
        guard self.hasValidKeyQuota, let keyLimit else {
            return nil
        }
        if let keyLimitRemaining {
            return min(keyLimit, max(0, keyLimitRemaining))
        }
        guard let used = self.quotaFallbackUsage else { return nil }
        return max(0, keyLimit - used)
    }

    public var keyUsedPercent: Double? {
        guard self.hasValidKeyQuota, let keyLimit else {
            return nil
        }
        let used: Double
        if let keyLimitRemaining {
            used = keyLimit - min(keyLimit, max(0, keyLimitRemaining))
        } else if let fallbackUsage = self.quotaFallbackUsage {
            used = fallbackUsage
        } else {
            return nil
        }
        return min(100, max(0, (used / keyLimit) * 100))
    }

    /// Usage value for quota math when the server does not report remaining: the field matching
    /// the declared reset window when known, otherwise cumulative usage.
    private var quotaFallbackUsage: Double? {
        self.resetWindowUsage ?? self.keyUsage
    }

    /// Usage value matching the server-declared reset window, when one is identified.
    private var resetWindowUsage: Double? {
        switch self.keyLimitReset?.lowercased() {
        case "daily":
            self.keyUsageDaily
        case "weekly":
            self.keyUsageWeekly
        case "monthly":
            self.keyUsageMonthly
        default:
            nil
        }
    }
}

extension OpenRouterUsageSnapshot {
    public func toUsageSnapshot() -> UsageSnapshot {
        let primary: RateWindow? = if let keyUsedPercent {
            RateWindow(
                usedPercent: keyUsedPercent,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: nil)
        } else {
            nil
        }

        // Format balance for identity display
        let balanceStr = String(format: "$%.2f", balance)
        let identity = ProviderIdentitySnapshot(
            providerID: .openrouter,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: "Balance: \(balanceStr)")

        var details: [ProviderDetailSection] = [.makeSection(title: "Credits", rows: [
            .makeRow(label: "Remaining", value: UsageFormatter.usdString(self.balance)),
            .makeRow(label: "Used", value: UsageFormatter.usdString(self.totalUsage)),
            .makeRow(label: "Total added", value: UsageFormatter.usdString(self.totalCredits)),
        ])]
        if self.keyDataFetched {
            var rows: [ProviderDetailSection.Row] = []
            if let keyLimit = self.keyLimit, keyLimit > 0 {
                rows.append(.makeRow(label: "API key budget", value: UsageFormatter.usdString(keyLimit)))
                if let keyRemaining = self.keyRemaining {
                    rows.append(.makeRow(
                        label: "API key remaining",
                        value: UsageFormatter.usdString(keyRemaining)))
                }
                if let keyUsage = self.keyUsage {
                    rows.append(.makeRow(label: "API key used", value: UsageFormatter.usdString(keyUsage)))
                }
            } else {
                rows.append(.makeRow(label: "API key budget", value: "No limit configured"))
            }
            if let keyLimitReset = self.keyLimitReset?.trimmingCharacters(in: .whitespacesAndNewlines),
               !keyLimitReset.isEmpty
            {
                rows.append(.makeRow(label: "Reset window", value: keyLimitReset))
            }
            let periods = [
                ("Today", self.keyUsageDaily),
                ("This week", self.keyUsageWeekly),
                ("This month", self.keyUsageMonthly),
            ]
            for (label, value) in periods {
                if let value {
                    rows.append(.makeRow(label: label, value: UsageFormatter.usdString(value)))
                }
            }
            if let rateLimit = self.rateLimit {
                rows.append(.makeRow(
                    label: "Rate limit",
                    value: "\(rateLimit.requests) requests / \(rateLimit.interval)"))
            }
            let points = periods.compactMap { label, value in value.map { (label, $0) } }
            details.append(.makeSection(
                title: "API key",
                rows: rows,
                chart: points.isEmpty ? nil : .makeChart(title: "Key spend", unit: "USD", points: points)))
        } else {
            details.append(.makeSection(title: "API key", rows: [
                .makeRow(label: "API key budget", value: "Unavailable right now"),
            ]))
        }

        return UsageSnapshot(
            primary: primary,
            secondary: nil,
            tertiary: nil,
            providerCost: nil,
            details: details,
            updatedAt: self.updatedAt,
            identity: identity)
    }
}

/// Fetches usage stats from the OpenRouter API
public struct OpenRouterUsageFetcher: Sendable {
    private static let log = CodexBarLog.logger(LogCategories.provider(.openrouter, scope: "usage"))
    private static let rateLimitTimeoutSeconds: TimeInterval = 1.0
    private static let creditsRequestTimeoutSeconds: TimeInterval = 15
    private static let maxErrorBodyLength = 240
    private static let maxDebugErrorBodyLength = 2000
    private static let debugFullErrorBodiesEnvKey = "CODEXBAR_DEBUG_OPENROUTER_ERROR_BODIES"

    /// Fetches credits usage from OpenRouter using the provided API key
    public static func fetchUsage(
        apiKey: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared) async throws -> OpenRouterUsageSnapshot
    {
        guard !apiKey.isEmpty else {
            throw OpenRouterUsageError.invalidCredentials
        }
        try OpenRouterSettingsReader.validateEndpointOverrides(environment: environment)

        let baseURL = OpenRouterSettingsReader.apiURL(environment: environment)
        let creditsURL = baseURL.appendingPathComponent("credits")

        var request = URLRequest(url: creditsURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = Self.creditsRequestTimeoutSeconds
        if let referer = OpenRouterSettingsReader.httpReferer(environment: environment) {
            request.setValue(referer, forHTTPHeaderField: "HTTP-Referer")
        }
        request.setValue(OpenRouterSettingsReader.clientTitle(environment: environment), forHTTPHeaderField: "X-Title")

        let response = try await transport.response(for: request)
        let data = response.data
        guard response.statusCode == 200 else {
            let errorSummary = LogRedactor.redact(Self.sanitizedResponseBodySummary(data))
            if Self.debugFullErrorBodiesEnabled(environment: environment),
               let debugBody = Self.redactedDebugResponseBody(data)
            {
                Self.log.debug("OpenRouter non-200 body (redacted): \(LogRedactor.redact(debugBody))")
            }
            Self.log.error("OpenRouter API returned \(response.statusCode): \(errorSummary)")
            throw OpenRouterUsageError.apiError("HTTP \(response.statusCode)")
        }

        do {
            let decoder = JSONDecoder()
            let creditsResponse = try decoder.decode(OpenRouterCreditsResponse.self, from: data)

            // Optionally fetch key quota/rate-limit info from /key endpoint, but keep this bounded so
            // credits updates are not blocked by a slow or unavailable secondary endpoint.
            let keyFetch = try await fetchKeyData(
                apiKey: apiKey,
                baseURL: baseURL,
                timeoutSeconds: Self.rateLimitTimeoutSeconds,
                transport: transport)

            return OpenRouterUsageSnapshot(
                totalCredits: creditsResponse.data.totalCredits,
                totalUsage: creditsResponse.data.totalUsage,
                balance: creditsResponse.data.balance,
                usedPercent: creditsResponse.data.usedPercent,
                keyDataFetched: keyFetch.fetched,
                keyLimit: keyFetch.data?.limit,
                keyLimitRemaining: keyFetch.data?.limitRemaining,
                keyLimitReset: keyFetch.data?.limitReset,
                keyUsage: keyFetch.data?.usage,
                keyUsageDaily: keyFetch.data?.usageDaily,
                keyUsageWeekly: keyFetch.data?.usageWeekly,
                keyUsageMonthly: keyFetch.data?.usageMonthly,
                rateLimit: keyFetch.data?.rateLimit,
                updatedAt: Date())
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as DecodingError {
            Self.log.error("OpenRouter JSON decoding error: \(error.localizedDescription)")
            throw OpenRouterUsageError.parseFailed(error.localizedDescription)
        } catch let error as OpenRouterUsageError {
            throw error
        } catch {
            Self.log.error("OpenRouter parsing error: \(error.localizedDescription)")
            throw OpenRouterUsageError.parseFailed(error.localizedDescription)
        }
    }

    /// Fetches key quota/rate-limit info from /key endpoint
    private struct OpenRouterKeyFetchResult {
        let data: OpenRouterKeyData?
        let fetched: Bool
    }

    private static func fetchKeyData(
        apiKey: String,
        baseURL: URL,
        timeoutSeconds: TimeInterval,
        transport: any ProviderHTTPTransport) async throws -> OpenRouterKeyFetchResult
    {
        let timeout = max(0.1, timeoutSeconds)
        return try await self.boundedKeyFetch(timeout: .seconds(timeout)) {
            await Self.fetchKeyDataRequest(
                apiKey: apiKey,
                baseURL: baseURL,
                timeoutSeconds: timeout,
                transport: transport)
        }
    }

    static func _boundedKeyFetchForTesting(
        timeout: Duration,
        operation: @escaping @Sendable () async -> Void) async throws -> Bool
    {
        let result = try await self.boundedKeyFetch(timeout: timeout) {
            await operation()
            return OpenRouterKeyFetchResult(data: nil, fetched: true)
        }
        return result.fetched
    }

    private static func boundedKeyFetch(
        timeout: Duration,
        operation: @escaping @Sendable () async -> OpenRouterKeyFetchResult) async throws -> OpenRouterKeyFetchResult
    {
        let sourceTask = Task<OpenRouterKeyFetchResult, Error> {
            await operation()
        }
        let race = BoundedTaskJoin(sourceTask: sourceTask)
        switch await race.value(joinGrace: timeout) {
        case let .value(result):
            try Task.checkCancellation()
            return result
        case .timedOut:
            try Task.checkCancellation()
            Self.log.debug("OpenRouter /key enrichment timed out")
            return OpenRouterKeyFetchResult(data: nil, fetched: false)
        case .failure:
            sourceTask.cancel()
            try Task.checkCancellation()
            return OpenRouterKeyFetchResult(data: nil, fetched: false)
        }
    }

    private static func fetchKeyDataRequest(
        apiKey: String,
        baseURL: URL,
        timeoutSeconds: TimeInterval,
        transport: any ProviderHTTPTransport) async -> OpenRouterKeyFetchResult
    {
        let keyURL = baseURL.appendingPathComponent("key")

        var request = URLRequest(url: keyURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = timeoutSeconds

        do {
            let response = try await transport.response(for: request)
            guard response.statusCode == 200 else {
                return OpenRouterKeyFetchResult(data: nil, fetched: false)
            }

            let decoder = JSONDecoder()
            let keyResponse = try decoder.decode(OpenRouterKeyResponse.self, from: response.data)
            return OpenRouterKeyFetchResult(data: keyResponse.data, fetched: true)
        } catch {
            Self.log.debug("Failed to fetch OpenRouter /key enrichment: \(error.localizedDescription)")
            return OpenRouterKeyFetchResult(data: nil, fetched: false)
        }
    }

    private static func debugFullErrorBodiesEnabled(environment: [String: String]) -> Bool {
        environment[self.debugFullErrorBodiesEnvKey] == "1"
    }

    private static func sanitizedResponseBodySummary(_ data: Data) -> String {
        guard !data.isEmpty else { return "empty body" }

        guard let rawBody = String(bytes: data, encoding: .utf8) else {
            return "non-text body (\(data.count) bytes)"
        }

        let body = Self.redactSensitiveBodyContent(rawBody)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !body.isEmpty else { return "non-text body (\(data.count) bytes)" }
        guard body.count > Self.maxErrorBodyLength else { return body }

        let index = body.index(body.startIndex, offsetBy: Self.maxErrorBodyLength)
        return "\(body[..<index])… [truncated]"
    }

    private static func redactedDebugResponseBody(_ data: Data) -> String? {
        guard let rawBody = String(bytes: data, encoding: .utf8) else { return nil }

        let body = Self.redactSensitiveBodyContent(rawBody)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        guard body.count > Self.maxDebugErrorBodyLength else { return body }

        let index = body.index(body.startIndex, offsetBy: Self.maxDebugErrorBodyLength)
        return "\(body[..<index])… [truncated]"
    }

    private static func redactSensitiveBodyContent(_ text: String) -> String {
        let replacements: [(String, String)] = [
            (#"(?i)(bearer\s+)[A-Za-z0-9._\-]+"#, "$1[REDACTED]"),
            (#"(?i)(sk-or-v1-)[A-Za-z0-9._\-]+"#, "$1[REDACTED]"),
            (
                #"(?i)(\"(?:api_?key|authorization|token|access_token|refresh_token)\"\s*:\s*\")([^\"]+)(\")"#,
                "$1[REDACTED]$3"),
            (
                #"(?i)((?:api_?key|authorization|token|access_token|refresh_token)\s*[=:]\s*)([^,\s]+)"#,
                "$1[REDACTED]"),
        ]

        return replacements.reduce(text) { partial, replacement in
            partial.replacingOccurrences(
                of: replacement.0,
                with: replacement.1,
                options: .regularExpression)
        }
    }

    #if DEBUG
    static func _sanitizedResponseBodySummaryForTesting(_ body: String) -> String {
        self.sanitizedResponseBodySummary(Data(body.utf8))
    }

    static func _redactedDebugResponseBodyForTesting(_ body: String) -> String? {
        self.redactedDebugResponseBody(Data(body.utf8))
    }
    #endif
}

/// Errors that can occur during OpenRouter usage fetching
public enum OpenRouterUsageError: LocalizedError, Sendable {
    case invalidCredentials
    case networkError(String)
    case apiError(String)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            "Invalid OpenRouter API credentials"
        case let .networkError(message):
            "OpenRouter network error: \(message)"
        case let .apiError(message):
            "OpenRouter API error: \(message)"
        case let .parseFailed(message):
            "Failed to parse OpenRouter response: \(message)"
        }
    }
}
#endif
