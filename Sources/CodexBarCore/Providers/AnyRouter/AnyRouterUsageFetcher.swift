import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum AnyRouterUsageError: LocalizedError, Equatable, Sendable {
    case missingCredentials
    case invalidCredentials
    case apiError(Int)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "Missing AnyRouter API key. Add one in Settings or set ANYROUTER_API_KEY."
        case .invalidCredentials:
            "AnyRouter rejected the API key. Check the key on the AnyRouter dashboard."
        case let .apiError(statusCode):
            "AnyRouter API returned HTTP \(statusCode)."
        case let .parseFailed(message):
            "Could not parse AnyRouter credits: \(message)"
        }
    }
}

/// `GET /api/v1/credits` response. AnyRouter returns the balance fields at the top level
/// (unlike OpenRouter, which wraps them in a `data` object). The payload also carries
/// `monthly_balance`, `topup_balance`, and `today_cost`, which nothing displays yet.
private struct AnyRouterCreditsResponse: Decodable {
    let balance: Double
    let used: Double
    let currency: String?
}

public struct AnyRouterUsageSnapshot: Codable, Sendable, Equatable {
    /// Total credit available to spend, in `currencyCode` (AnyRouter-issued plus purchased).
    public let balance: Double
    /// Cumulative lifetime spend.
    public let used: Double
    public let currencyCode: String
    public let updatedAt: Date

    public init(
        balance: Double,
        used: Double,
        currencyCode: String,
        updatedAt: Date)
    {
        self.balance = balance
        self.used = used
        self.currencyCode = currencyCode
        self.updatedAt = updatedAt
    }

    /// Everything ever granted or purchased: what is still spendable plus what has been spent.
    public var totalCredits: Double {
        max(0, self.balance + self.used)
    }

    /// Share of granted credit already spent (0-100).
    public var usedPercent: Double {
        let total = self.totalCredits
        guard total > 0 else { return 0 }
        return min(100, max(0, self.used / total * 100))
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        let identity = ProviderIdentitySnapshot(
            providerID: .anyrouter,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: "Balance: \(UsageFormatter.currencyString(self.balance, currencyCode: self.currencyCode))")

        return UsageSnapshot(
            primary: RateWindow(
                usedPercent: self.usedPercent,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: nil),
            secondary: nil,
            providerCost: ProviderCostSnapshot(
                used: self.used,
                limit: self.totalCredits,
                currencyCode: self.currencyCode,
                period: "Lifetime",
                updatedAt: self.updatedAt),
            updatedAt: self.updatedAt,
            identity: identity,
            dataConfidence: .exact)
    }
}

public enum AnyRouterUsageFetcher {
    private static let log = CodexBarLog.logger(LogCategories.anyRouterUsage)
    private static let requestTimeoutSeconds: TimeInterval = 15

    public static func fetchUsage(
        apiKey: String,
        baseURL: URL = AnyRouterSettingsReader.defaultBaseURL,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        updatedAt: Date = Date()) async throws -> AnyRouterUsageSnapshot
    {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AnyRouterUsageError.missingCredentials
        }

        var request = URLRequest(url: baseURL.appendingPathComponent("credits"))
        request.httpMethod = "GET"
        request.timeoutInterval = Self.requestTimeoutSeconds
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let response = try await transport.response(for: request)
        if response.statusCode == 401 || response.statusCode == 403 {
            throw AnyRouterUsageError.invalidCredentials
        }
        guard (200..<300).contains(response.statusCode) else {
            Self.log.error("AnyRouter credits API returned \(response.statusCode)")
            throw AnyRouterUsageError.apiError(response.statusCode)
        }
        return try self.parseSnapshot(data: response.data, updatedAt: updatedAt)
    }

    public static func _parseSnapshotForTesting(
        _ data: Data,
        updatedAt: Date) throws -> AnyRouterUsageSnapshot
    {
        try self.parseSnapshot(data: data, updatedAt: updatedAt)
    }

    private static func parseSnapshot(data: Data, updatedAt: Date) throws -> AnyRouterUsageSnapshot {
        do {
            let response = try JSONDecoder().decode(AnyRouterCreditsResponse.self, from: data)
            return AnyRouterUsageSnapshot(
                balance: response.balance,
                used: response.used,
                currencyCode: response.currency?.uppercased() ?? "USD",
                updatedAt: updatedAt)
        } catch {
            Self.log.error("AnyRouter credits parsing failed: \(error.localizedDescription)")
            throw AnyRouterUsageError.parseFailed(error.localizedDescription)
        }
    }
}
