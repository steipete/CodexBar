import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HyperCreditsResponse: Decodable, Sendable {
    public let balance: Double
}

public struct HyperUsageSnapshot: Sendable {
    public let balance: Double
    public let updatedAt: Date

    public init(balance: Double, updatedAt: Date) {
        self.balance = balance
        self.updatedAt = updatedAt
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: ProviderCostSnapshot(
                used: self.balance,
                limit: 0,
                currencyCode: "HC",
                period: "Hypercredits balance",
                updatedAt: self.updatedAt),
            updatedAt: self.updatedAt,
            identity: ProviderIdentitySnapshot(
                providerID: .hyper,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: nil),
            dataConfidence: .exact)
    }
}

public enum HyperUsageError: LocalizedError, Sendable, Equatable {
    case missingCredentials
    case networkError(String)
    case apiError(String)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials: "Missing Charm Hyper API key."
        case let .networkError(message): "Charm Hyper network error: \(message)"
        case let .apiError(message): "Charm Hyper API error: \(message)"
        case let .parseFailed(message): "Failed to parse Charm Hyper response: \(message)"
        }
    }
}

public struct HyperUsageFetcher: Sendable {
    private static let creditsURL = URL(string: "https://hyper.charm.land/v1/credits")!

    public static func fetchUsage(apiKey: String) async throws -> HyperUsageSnapshot {
        try await self.fetchUsage(apiKey: apiKey, transport: ProviderHTTPClient.shared, now: Date())
    }

    static func _fetchUsageForTesting(
        apiKey: String,
        transport: any ProviderHTTPTransport,
        now: Date = Date()) async throws -> HyperUsageSnapshot
    {
        try await self.fetchUsage(apiKey: apiKey, transport: transport, now: now)
    }

    static func _parseSnapshotForTesting(_ data: Data, now: Date = Date()) throws -> HyperUsageSnapshot {
        try self.parseSnapshot(data: data, now: now)
    }

    private static func fetchUsage(
        apiKey: String,
        transport: any ProviderHTTPTransport,
        now: Date) async throws -> HyperUsageSnapshot
    {
        let token = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw HyperUsageError.missingCredentials }
        do {
            let response = try await transport.response(
                for: self.request(token: token),
                retryPolicy: .transientIdempotent)
            try self.validate(response)
            return try self.parseSnapshot(data: response.data, now: now)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as HyperUsageError {
            throw error
        } catch {
            throw HyperUsageError.networkError(error.localizedDescription)
        }
    }

    private static func request(token: String) -> URLRequest {
        var request = URLRequest(url: self.creditsURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        return request
    }

    private static func validate(_ response: ProviderHTTPResponse) throws {
        switch response.statusCode {
        case 200: return
        case 401: throw HyperUsageError.apiError("API key rejected (HTTP 401).")
        case 403: throw HyperUsageError.apiError("API key cannot access credits (HTTP 403).")
        default: throw HyperUsageError.apiError("HTTP \(response.statusCode)")
        }
    }

    private static func parseSnapshot(data: Data, now: Date) throws -> HyperUsageSnapshot {
        do {
            let response = try JSONDecoder().decode(HyperCreditsResponse.self, from: data)
            guard response.balance.isFinite, response.balance >= 0 else {
                throw HyperUsageError.parseFailed("Balance must be a non-negative number.")
            }
            return HyperUsageSnapshot(balance: response.balance, updatedAt: now)
        } catch let error as HyperUsageError {
            throw error
        } catch {
            throw HyperUsageError.parseFailed(error.localizedDescription)
        }
    }
}
