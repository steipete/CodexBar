import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// CheapestInference /v1/usage API response
public struct CheapestInferenceAPIResponse: Decodable, Sendable {
    public let success: Bool
    public let data: CheapestInferenceUsageData
}

/// CheapestInference usage data from /v1/usage
public struct CheapestInferenceUsageData: Decodable, Sendable {
    public let budget: CheapestInferenceBudget
    public let rateLimits: CheapestInferenceRateLimits
    public let plan: CheapestInferencePlan
    public let credits: CheapestInferenceCredits
    public let key: CheapestInferenceKeyInfo

    private enum CodingKeys: String, CodingKey {
        case budget
        case rateLimits = "rate_limits"
        case plan
        case credits
        case key
    }
}

public struct CheapestInferenceBudget: Decodable, Sendable {
    public let spent: Double
    public let limit: Double?
    public let duration: String?
    public let resetsAt: String?

    private enum CodingKeys: String, CodingKey {
        case spent
        case limit
        case duration
        case resetsAt = "resets_at"
    }
}

public struct CheapestInferenceRateLimits: Decodable, Sendable {
    public let rpm: Int?
    public let tpm: Int?
}

public struct CheapestInferencePlan: Decodable, Sendable {
    public let slug: String?
    public let status: String?
    public let expiresAt: String?

    private enum CodingKeys: String, CodingKey {
        case slug
        case status
        case expiresAt = "expires_at"
    }
}

public struct CheapestInferenceCredits: Decodable, Sendable {
    public let balance: Double
}

public struct CheapestInferenceKeyInfo: Decodable, Sendable {
    public let name: String
    public let type: String
    public let createdAt: String

    private enum CodingKeys: String, CodingKey {
        case name
        case type
        case createdAt = "created_at"
    }
}

/// Complete CheapestInference usage snapshot
public struct CheapestInferenceUsageSnapshot: Codable, Sendable {
    public let spent: Double
    public let limit: Double?
    public let duration: String?
    public let resetsAt: Date?
    public let planSlug: String?
    public let planStatus: String?
    public let creditBalance: Double
    public let rpm: Int?
    public let tpm: Int?
    public let updatedAt: Date

    /// Budget utilization as 0-100 percentage
    public var usedPercent: Double {
        guard let limit, limit > 0 else { return 0 }
        return min(100, (self.spent / limit) * 100)
    }

    /// Returns true if this snapshot contains valid budget data
    public var hasBudget: Bool {
        self.limit != nil && self.limit! > 0
    }
}

extension CheapestInferenceUsageSnapshot {
    public func toUsageSnapshot() -> UsageSnapshot {
        let primary: RateWindow? = if self.hasBudget {
            RateWindow(
                usedPercent: self.usedPercent,
                windowMinutes: self.windowMinutes,
                resetsAt: self.resetsAt,
                resetDescription: nil)
        } else {
            nil
        }

        // Show plan and credit balance in identity
        let planStr = self.planSlug?.capitalized ?? "Unknown"
        let balanceStr = String(format: "$%.2f", self.creditBalance)
        let identity = ProviderIdentitySnapshot(
            providerID: .cheapestinference,
            accountEmail: nil,
            accountOrganization: "\(planStr) plan",
            loginMethod: "Credits: \(balanceStr)")

        return UsageSnapshot(
            primary: primary,
            secondary: nil,
            tertiary: nil,
            providerCost: nil,
            updatedAt: self.updatedAt,
            identity: identity)
    }

    /// Parse duration string (e.g. "5h", "30d", "1h") to minutes
    private var windowMinutes: Int? {
        guard let duration else { return nil }
        let scanner = Scanner(string: duration)
        guard let value = scanner.scanInt() else { return nil }
        let unit = String(duration.dropFirst(String(value).count))
        switch unit {
        case "m": return value
        case "h": return value * 60
        case "d": return value * 60 * 24
        default: return nil
        }
    }
}

/// Fetches usage stats from the CheapestInference API
public struct CheapestInferenceUsageFetcher: Sendable {
    private static let log = CodexBarLog.logger(LogCategories.cheapestInferenceUsage)
    private static let requestTimeoutSeconds: TimeInterval = 15

    /// Fetches usage from CheapestInference using the provided API key
    public static func fetchUsage(
        apiKey: String,
        environment: [String: String] = ProcessInfo.processInfo.environment) async throws
        -> CheapestInferenceUsageSnapshot
    {
        guard !apiKey.isEmpty else {
            throw CheapestInferenceUsageError.invalidCredentials
        }

        let baseURL = CheapestInferenceSettingsReader.apiURL(environment: environment)
        let usageURL = baseURL.appendingPathComponent("v1/usage")

        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = Self.requestTimeoutSeconds

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CheapestInferenceUsageError.networkError("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            Self.log.error("CheapestInference API returned \(httpResponse.statusCode)")
            if httpResponse.statusCode == 401 {
                throw CheapestInferenceUsageError.invalidCredentials
            }
            throw CheapestInferenceUsageError.apiError("HTTP \(httpResponse.statusCode)")
        }

        do {
            let decoder = JSONDecoder()
            let apiResponse = try decoder.decode(CheapestInferenceAPIResponse.self, from: data)
            let d = apiResponse.data

            // Parse resets_at ISO8601 date
            var resetsAt: Date?
            if let resetsAtStr = d.budget.resetsAt {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                resetsAt = formatter.date(from: resetsAtStr)
                if resetsAt == nil {
                    // Try without fractional seconds
                    formatter.formatOptions = [.withInternetDateTime]
                    resetsAt = formatter.date(from: resetsAtStr)
                }
            }

            return CheapestInferenceUsageSnapshot(
                spent: d.budget.spent,
                limit: d.budget.limit,
                duration: d.budget.duration,
                resetsAt: resetsAt,
                planSlug: d.plan.slug,
                planStatus: d.plan.status,
                creditBalance: d.credits.balance,
                rpm: d.rateLimits.rpm,
                tpm: d.rateLimits.tpm,
                updatedAt: Date())
        } catch let error as DecodingError {
            Self.log.error("CheapestInference JSON decoding error: \(error.localizedDescription)")
            throw CheapestInferenceUsageError.parseFailed(error.localizedDescription)
        } catch let error as CheapestInferenceUsageError {
            throw error
        } catch {
            Self.log.error("CheapestInference parsing error: \(error.localizedDescription)")
            throw CheapestInferenceUsageError.parseFailed(error.localizedDescription)
        }
    }
}

/// Errors that can occur during CheapestInference usage fetching
public enum CheapestInferenceUsageError: LocalizedError, Sendable {
    case invalidCredentials
    case networkError(String)
    case apiError(String)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            "Invalid CheapestInference API credentials"
        case let .networkError(message):
            "CheapestInference network error: \(message)"
        case let .apiError(message):
            "CheapestInference API error: \(message)"
        case let .parseFailed(message):
            "Failed to parse CheapestInference response: \(message)"
        }
    }
}
