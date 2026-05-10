import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct OpenAIAPICreditGrant: Decodable, Sendable {
    public let grantAmount: Double?
    public let usedAmount: Double?
    public let expiresAt: Date?

    private enum CodingKeys: String, CodingKey {
        case grantAmount = "grant_amount"
        case usedAmount = "used_amount"
        case expiresAt = "expires_at"
    }
}

public struct OpenAIAPICreditGrantsList: Decodable, Sendable {
    public let data: [OpenAIAPICreditGrant]
}

public struct OpenAIAPICreditGrantsResponse: Decodable, Sendable {
    public let totalGranted: Double
    public let totalUsed: Double
    public let totalAvailable: Double
    public let grants: OpenAIAPICreditGrantsList?

    private enum CodingKeys: String, CodingKey {
        case totalGranted = "total_granted"
        case totalUsed = "total_used"
        case totalAvailable = "total_available"
        case grants
    }
}

public enum OpenAIAPICreditBalanceError: LocalizedError, Sendable, Equatable {
    case missingCredentials
    case networkError(String)
    case apiError(Int)
    case forbidden
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "Missing OpenAI API key."
        case let .networkError(message):
            "OpenAI API credit balance network error: \(message)"
        case let .apiError(statusCode):
            "OpenAI API credit balance error: HTTP \(statusCode)"
        case .forbidden:
            "OpenAI API credit balance endpoint returned HTTP 403. Use a legacy/user API key with billing access; " +
                "project keys may not expose credit grants."
        case let .parseFailed(message):
            "Failed to parse OpenAI API credit balance: \(message)"
        }
    }
}

public struct OpenAIAPICreditBalanceSnapshot: Sendable {
    public let totalGranted: Double
    public let totalUsed: Double
    public let totalAvailable: Double
    public let nextGrantExpiry: Date?
    public let updatedAt: Date

    public init(
        totalGranted: Double,
        totalUsed: Double,
        totalAvailable: Double,
        nextGrantExpiry: Date?,
        updatedAt: Date = Date())
    {
        self.totalGranted = totalGranted
        self.totalUsed = totalUsed
        self.totalAvailable = totalAvailable
        self.nextGrantExpiry = nextGrantExpiry
        self.updatedAt = updatedAt
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        let usedPercent: Double = if self.totalGranted > 0 {
            min(100, max(0, (self.totalUsed / self.totalGranted) * 100))
        } else {
            self.totalAvailable > 0 ? 0 : 100
        }

        let primary = RateWindow(
            usedPercent: usedPercent,
            windowMinutes: nil,
            resetsAt: self.nextGrantExpiry,
            resetDescription: "\(Self.formatUSD(self.totalAvailable)) available")

        return UsageSnapshot(
            primary: primary,
            secondary: nil,
            providerCost: ProviderCostSnapshot(
                used: max(0, self.totalUsed),
                limit: max(0, self.totalGranted),
                currencyCode: "USD",
                period: "API credits",
                resetsAt: self.nextGrantExpiry,
                updatedAt: self.updatedAt),
            updatedAt: self.updatedAt,
            identity: ProviderIdentitySnapshot(
                providerID: .openai,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: "API balance: \(Self.formatUSD(self.totalAvailable))"))
    }

    private static func formatUSD(_ value: Double) -> String {
        UsageFormatter.currencyString(max(0, value), currencyCode: "USD")
    }
}

public enum OpenAIAPICreditBalanceFetcher {
    public static let creditGrantsURL = URL(string: "https://api.openai.com/v1/dashboard/billing/credit_grants")!
    private static let timeoutSeconds: TimeInterval = 15

    public static func fetchBalance(
        apiKey: String,
        url: URL = Self.creditGrantsURL,
        session: URLSession = .shared,
        now: Date = Date()) async throws -> OpenAIAPICreditBalanceSnapshot
    {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw OpenAIAPICreditBalanceError.missingCredentials
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.timeoutSeconds
        request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw OpenAIAPICreditBalanceError.networkError(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIAPICreditBalanceError.networkError("Invalid response")
        }
        guard httpResponse.statusCode != 403 else {
            throw OpenAIAPICreditBalanceError.forbidden
        }
        guard httpResponse.statusCode == 200 else {
            throw OpenAIAPICreditBalanceError.apiError(httpResponse.statusCode)
        }

        return try self.parseSnapshot(data, now: now)
    }

    public static func _parseSnapshotForTesting(
        _ data: Data,
        now: Date = Date()) throws -> OpenAIAPICreditBalanceSnapshot
    {
        try self.parseSnapshot(data, now: now)
    }

    private static func parseSnapshot(_ data: Data, now: Date) throws -> OpenAIAPICreditBalanceSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        let decoded: OpenAIAPICreditGrantsResponse
        do {
            decoded = try decoder.decode(OpenAIAPICreditGrantsResponse.self, from: data)
        } catch {
            throw OpenAIAPICreditBalanceError.parseFailed(error.localizedDescription)
        }

        let nextExpiry = decoded.grants?.data
            .compactMap(\.expiresAt)
            .filter { $0 > now }
            .min()

        return OpenAIAPICreditBalanceSnapshot(
            totalGranted: decoded.totalGranted,
            totalUsed: decoded.totalUsed,
            totalAvailable: decoded.totalAvailable,
            nextGrantExpiry: nextExpiry,
            updatedAt: now)
    }
}
