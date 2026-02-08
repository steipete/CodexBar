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
        max(0, totalCredits - totalUsage)
    }

    /// Usage percentage (0-100)
    public var usedPercent: Double {
        guard totalCredits > 0 else { return 0 }
        return min(100, (totalUsage / totalCredits) * 100)
    }
}

/// OpenRouter key info API response (for rate limits)
public struct OpenRouterKeyResponse: Decodable, Sendable {
    public let data: OpenRouterKeyData
}

/// OpenRouter key data with rate limit info
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
public struct OpenRouterRateLimit: Decodable, Sendable {
    /// Number of requests allowed
    public let requests: Int
    /// Interval for the rate limit (e.g., "10s", "1m")
    public let interval: String
}

/// Complete OpenRouter usage snapshot
public struct OpenRouterUsageSnapshot: Sendable {
    public let totalCredits: Double
    public let totalUsage: Double
    public let balance: Double
    public let usedPercent: Double
    public let rateLimit: OpenRouterRateLimit?
    public let updatedAt: Date

    public init(
        totalCredits: Double,
        totalUsage: Double,
        balance: Double,
        usedPercent: Double,
        rateLimit: OpenRouterRateLimit?,
        updatedAt: Date)
    {
        self.totalCredits = totalCredits
        self.totalUsage = totalUsage
        self.balance = balance
        self.usedPercent = usedPercent
        self.rateLimit = rateLimit
        self.updatedAt = updatedAt
    }

    /// Returns true if this snapshot contains valid data
    public var isValid: Bool {
        totalCredits >= 0
    }
}

extension OpenRouterUsageSnapshot {
    public func toUsageSnapshot() -> UsageSnapshot {
        // Primary: credits usage percentage
        let primary = RateWindow(
            usedPercent: usedPercent,
            windowMinutes: nil,
            resetsAt: nil,
            resetDescription: "Credits")

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
            updatedAt: updatedAt,
            identity: identity)
    }
}

/// Fetches usage stats from the OpenRouter API
public struct OpenRouterUsageFetcher: Sendable {
    private static let log = CodexBarLog.logger(LogCategories.openRouterUsage)

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

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenRouterUsageError.networkError("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            Self.log.error("OpenRouter API returned \(httpResponse.statusCode): \(errorMessage)")
            throw OpenRouterUsageError.apiError("HTTP \(httpResponse.statusCode): \(errorMessage)")
        }

        // Log raw response for debugging
        if let jsonString = String(data: data, encoding: .utf8) {
            Self.log.debug("OpenRouter credits response: \(jsonString)")
        }

        do {
            let decoder = JSONDecoder()
            let creditsResponse = try decoder.decode(OpenRouterCreditsResponse.self, from: data)

            // Optionally fetch rate limit info from /key endpoint
            let rateLimit = await fetchRateLimit(apiKey: apiKey, baseURL: baseURL)

            return OpenRouterUsageSnapshot(
                totalCredits: creditsResponse.data.totalCredits,
                totalUsage: creditsResponse.data.totalUsage,
                balance: creditsResponse.data.balance,
                usedPercent: creditsResponse.data.usedPercent,
                rateLimit: rateLimit,
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

    /// Fetches rate limit info from /key endpoint
    private static func fetchRateLimit(apiKey: String, baseURL: URL) async -> OpenRouterRateLimit? {
        let keyURL = baseURL.appendingPathComponent("key")

        var request = URLRequest(url: keyURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200
            else {
                return nil
            }

            let decoder = JSONDecoder()
            let keyResponse = try decoder.decode(OpenRouterKeyResponse.self, from: data)
            return keyResponse.data.rateLimit
        } catch {
            Self.log.debug("Failed to fetch OpenRouter rate limit: \(error.localizedDescription)")
            return nil
        }
    }
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
