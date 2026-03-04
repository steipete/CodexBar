import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Manus GetAvailableCredits API response
public struct ManusCreditsResponse: Decodable, Sendable {
    /// Total remaining credits across all credit types
    public let totalCredits: Double
    /// Free (non-plan) credits remaining
    public let freeCredits: Double
    /// Monthly plan credits remaining
    public let periodicCredits: Double
    /// Add-on credits remaining
    public let addonCredits: Double
    /// Auto-refresh credits remaining
    public let refreshCredits: Double
    /// Maximum auto-refresh credits
    public let maxRefreshCredits: Double
    /// Monthly plan credit limit (> 0 on paid plans)
    public let proMonthlyCredits: Double
    /// Event / promotional credits remaining
    public let eventCredits: Double

    private enum CodingKeys: String, CodingKey {
        case totalCredits
        case freeCredits
        case periodicCredits
        case addonCredits
        case refreshCredits
        case maxRefreshCredits
        case proMonthlyCredits
        case eventCredits
    }
}

/// Fetches credit usage from the Manus API using a session_id bearer token
public enum ManusUsageFetcher {
    private static let log = CodexBarLog.logger(LogCategories.manusUsage)
    private static let creditsURL =
        URL(string: "https://api.manus.im/user.v1.UserService/GetAvailableCredits")!
    private static let requestTimeoutSeconds: TimeInterval = 15

    public static func fetchUsage(sessionToken: String, now: Date = Date()) async throws -> ManusCreditsResponse {
        guard !sessionToken.isEmpty else {
            throw ManusAPIError.missingToken
        }

        var request = URLRequest(url: self.creditsURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("https://manus.im", forHTTPHeaderField: "Origin")
        request.setValue("https://manus.im/", forHTTPHeaderField: "Referer")
        let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
            "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [String: String]())
        request.timeoutInterval = Self.requestTimeoutSeconds

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ManusAPIError.networkError("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            let responseBody = String(data: data, encoding: .utf8) ?? "<binary data>"
            Self.log.error("Manus API returned \(httpResponse.statusCode): \(responseBody)")

            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw ManusAPIError.invalidToken
            }
            throw ManusAPIError.apiError("HTTP \(httpResponse.statusCode)")
        }

        do {
            let decoder = JSONDecoder()
            return try decoder.decode(ManusCreditsResponse.self, from: data)
        } catch let error as DecodingError {
            Self.log.error("Manus JSON decoding error: \(error.localizedDescription)")
            throw ManusAPIError.parseFailed(error.localizedDescription)
        }
    }
}

extension ManusCreditsResponse {
    public func toUsageSnapshot(now: Date = Date()) -> UsageSnapshot {
        // On paid plans, proMonthlyCredits > 0. Show plan utilisation as a percentage bar.
        let primary: RateWindow? = if self.proMonthlyCredits > 0 {
            RateWindow(
                usedPercent: min(
                    100,
                    max(0, (self.proMonthlyCredits - self.periodicCredits) / self.proMonthlyCredits * 100)),
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: nil)
        } else {
            nil
        }

        let balanceStr = String(format: "%.0f credits", self.totalCredits)
        let identity = ProviderIdentitySnapshot(
            providerID: .manus,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: "Balance: \(balanceStr)")

        // Represent credit balance as a ProviderCostSnapshot (used / limit in "credits" currency).
        // On paid plans: used = plan credits consumed, limit = plan total.
        // On free plans: used = 0, limit = freeCredits (remaining is the limit itself).
        let providerCost: ProviderCostSnapshot?
        if self.proMonthlyCredits > 0 {
            let used = max(0, self.proMonthlyCredits - self.periodicCredits)
            providerCost = ProviderCostSnapshot(
                used: used,
                limit: self.proMonthlyCredits,
                currencyCode: "credits",
                period: "Monthly",
                resetsAt: nil,
                updatedAt: now)
        } else {
            providerCost = ProviderCostSnapshot(
                used: 0,
                limit: self.totalCredits,
                currencyCode: "credits",
                period: nil,
                resetsAt: nil,
                updatedAt: now)
        }

        return UsageSnapshot(
            primary: primary,
            secondary: nil,
            tertiary: nil,
            providerCost: providerCost,
            updatedAt: now,
            identity: identity)
    }
}

public enum ManusAPIError: LocalizedError, Sendable {
    case missingToken
    case invalidToken
    case networkError(String)
    case apiError(String)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingToken:
            "No Manus session token provided."
        case .invalidToken:
            "Invalid Manus session token."
        case let .networkError(message):
            "Manus network error: \(message)"
        case let .apiError(message):
            "Manus API error: \(message)"
        case let .parseFailed(message):
            "Failed to parse Manus response: \(message)"
        }
    }
}
