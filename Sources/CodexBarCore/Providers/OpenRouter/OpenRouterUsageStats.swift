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
    /// Current usage
    public let usage: Double?

    private enum CodingKeys: String, CodingKey {
        case rateLimit = "rate_limit"
        case limit
        case usage
    }
}

/// OpenRouter rate limit info
public struct OpenRouterRateLimit: Codable, Sendable {
    /// Number of requests allowed
    public let requests: Int
    /// Interval for the rate limit (e.g., "10s", "1m")
    public let interval: String
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
    public let keyUsage: Double?
    public let rateLimit: OpenRouterRateLimit?
    public let updatedAt: Date

    public init(
        totalCredits: Double,
        totalUsage: Double,
        balance: Double,
        usedPercent: Double,
        keyDataFetched: Bool = false,
        keyLimit: Double? = nil,
        keyUsage: Double? = nil,
        rateLimit: OpenRouterRateLimit?,
        updatedAt: Date)
    {
        self.totalCredits = totalCredits
        self.totalUsage = totalUsage
        self.balance = balance
        self.usedPercent = usedPercent
        self.keyDataFetched = keyDataFetched || keyLimit != nil || keyUsage != nil
        self.keyLimit = keyLimit
        self.keyUsage = keyUsage
        self.rateLimit = rateLimit
        self.updatedAt = updatedAt
    }

    /// Returns true if this snapshot contains valid data
    public var isValid: Bool {
        self.totalCredits >= 0
    }

    public var hasValidKeyQuota: Bool {
        guard self.keyDataFetched,
              let keyLimit,
              let keyUsage
        else {
            return false
        }
        return keyLimit > 0 && keyUsage >= 0
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
        guard self.hasValidKeyQuota,
              let keyLimit,
              let keyUsage
        else {
            return nil
        }
        return max(0, keyLimit - keyUsage)
    }

    public var keyUsedPercent: Double? {
        guard self.hasValidKeyQuota,
              let keyLimit,
              let keyUsage
        else {
            return nil
        }
        return min(100, max(0, (keyUsage / keyLimit) * 100))
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

        return UsageSnapshot(
            primary: primary,
            secondary: nil,
            tertiary: nil,
            providerCost: nil,
            openRouterUsage: self,
            updatedAt: self.updatedAt,
            identity: identity)
    }
}

/// Fetches usage stats from the OpenRouter API
public struct OpenRouterUsageFetcher: Sendable {
    private static let log = CodexBarLog.logger(LogCategories.openRouterUsage)
    private static let rateLimitTimeoutSeconds: TimeInterval = 1.0
    private static let creditsRequestTimeoutSeconds: TimeInterval = 15
    private static let maxErrorBodyLength = 240
    private static let maxDebugErrorBodyLength = 2000
    private static let debugFullErrorBodiesEnvKey = "CODEXBAR_DEBUG_OPENROUTER_ERROR_BODIES"
    private static let httpRefererEnvKey = "OPENROUTER_HTTP_REFERER"
    private static let clientTitleEnvKey = "OPENROUTER_X_TITLE"
    private static let defaultClientTitle = "CodexBar"

    /// Fetches credits usage from OpenRouter using the provided API key
    public static func fetchUsage(
        apiKey: String,
        environment: [String: String] = ProcessInfo.processInfo.environment) async throws -> OpenRouterUsageSnapshot
    {
        guard !apiKey.isEmpty else {
            throw OpenRouterUsageError.invalidCredentials
        }

        let baseURL = OpenRouterSettingsReader.apiURL(environment: environment)
        let creditsURL = baseURL.appendingPathComponent("credits")

        var request = URLRequest(url: creditsURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = Self.creditsRequestTimeoutSeconds
        if let referer = Self.sanitizedHeaderValue(environment[self.httpRefererEnvKey]) {
            request.setValue(referer, forHTTPHeaderField: "HTTP-Referer")
        }
        let title = Self.sanitizedHeaderValue(environment[self.clientTitleEnvKey]) ?? Self.defaultClientTitle
        request.setValue(title, forHTTPHeaderField: "X-Title")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenRouterUsageError.networkError("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            let errorSummary = LogRedactor.redact(Self.sanitizedResponseBodySummary(data))
            if Self.debugFullErrorBodiesEnabled(environment: environment),
               let debugBody = Self.redactedDebugResponseBody(data)
            {
                Self.log.debug("OpenRouter non-200 body (redacted): \(LogRedactor.redact(debugBody))")
            }
            Self.log.error("OpenRouter API returned \(httpResponse.statusCode): \(errorSummary)")
            throw OpenRouterUsageError.apiError("HTTP \(httpResponse.statusCode)")
        }

        do {
            let decoder = JSONDecoder()
            let creditsResponse = try decoder.decode(OpenRouterCreditsResponse.self, from: data)

            // Optionally fetch key quota/rate-limit info from /key endpoint, but keep this bounded so
            // credits updates are not blocked by a slow or unavailable secondary endpoint.
            let keyFetch = await fetchKeyData(
                apiKey: apiKey,
                baseURL: baseURL,
                timeoutSeconds: Self.rateLimitTimeoutSeconds)

            return OpenRouterUsageSnapshot(
                totalCredits: creditsResponse.data.totalCredits,
                totalUsage: creditsResponse.data.totalUsage,
                balance: creditsResponse.data.balance,
                usedPercent: creditsResponse.data.usedPercent,
                keyDataFetched: keyFetch.fetched,
                keyLimit: keyFetch.data?.limit,
                keyUsage: keyFetch.data?.usage,
                rateLimit: keyFetch.data?.rateLimit,
                updatedAt: Date())
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
    private struct OpenRouterKeyFetchResult: Sendable {
        let data: OpenRouterKeyData?
        let fetched: Bool
    }

    private static func fetchKeyData(
        apiKey: String,
        baseURL: URL,
        timeoutSeconds: TimeInterval) async -> OpenRouterKeyFetchResult
    {
        let timeout = max(0.1, timeoutSeconds)
        let timeoutNanoseconds = UInt64(timeout * 1_000_000_000)

        return await withTaskGroup(of: OpenRouterKeyFetchResult.self) { group in
            group.addTask {
                await Self.fetchKeyDataRequest(
                    apiKey: apiKey,
                    baseURL: baseURL,
                    timeoutSeconds: timeout)
            }
            group.addTask {
                do {
                    try await Task.sleep(nanoseconds: timeoutNanoseconds)
                } catch {
                    // Cancelled because the /key request finished first.
                    return OpenRouterKeyFetchResult(data: nil, fetched: false)
                }
                guard !Task.isCancelled else {
                    return OpenRouterKeyFetchResult(data: nil, fetched: false)
                }
                Self.log.debug("OpenRouter /key enrichment timed out after \(timeout)s")
                return OpenRouterKeyFetchResult(data: nil, fetched: false)
            }

            let result = await group.next()
            group.cancelAll()
            if let result {
                return result
            }
            return OpenRouterKeyFetchResult(data: nil, fetched: false)
        }
    }

    private static func fetchKeyDataRequest(
        apiKey: String,
        baseURL: URL,
        timeoutSeconds: TimeInterval) async -> OpenRouterKeyFetchResult
    {
        let keyURL = baseURL.appendingPathComponent("key")

        var request = URLRequest(url: keyURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = timeoutSeconds

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200
            else {
                return OpenRouterKeyFetchResult(data: nil, fetched: false)
            }

            let decoder = JSONDecoder()
            let keyResponse = try decoder.decode(OpenRouterKeyResponse.self, from: data)
            return OpenRouterKeyFetchResult(data: keyResponse.data, fetched: true)
        } catch {
            Self.log.debug("Failed to fetch OpenRouter /key enrichment: \(error.localizedDescription)")
            return OpenRouterKeyFetchResult(data: nil, fetched: false)
        }
    }

    private static func debugFullErrorBodiesEnabled(environment: [String: String]) -> Bool {
        environment[self.debugFullErrorBodiesEnvKey] == "1"
    }

    private static func sanitizedHeaderValue(_ raw: String?) -> String? {
        OpenRouterSettingsReader.cleaned(raw)
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
