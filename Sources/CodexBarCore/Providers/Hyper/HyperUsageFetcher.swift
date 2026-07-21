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
            tertiary: nil,
            providerCost: ProviderCostSnapshot(
                used: self.balance,
                limit: 0,
                currencyCode: "Hypercredits",
                period: "Hypercredits balance",
                updatedAt: self.updatedAt),
            updatedAt: self.updatedAt,
            identity: ProviderIdentitySnapshot(
                providerID: .hyper,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: nil))
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
    private static let log = CodexBarLog.logger(LogCategories.hyperUsage)
    private static let creditsURL = URL(string: "https://api.hyper.charm.land/v1/credits")!

    public static func fetchUsage(
        apiKey: String,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared) async throws -> HyperUsageSnapshot
    {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HyperUsageError.missingCredentials
        }

        var request = URLRequest(url: self.creditsURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let data: Data
        let urlResponse: URLResponse
        do {
            (data, urlResponse) = try await transport.data(for: request)
        } catch {
            throw HyperUsageError.networkError(error.localizedDescription)
        }
        guard let response = urlResponse as? HTTPURLResponse else {
            throw HyperUsageError.networkError("Invalid response")
        }
        guard response.statusCode == 200 else {
            if response.statusCode == 401 || response.statusCode == 403 {
                throw HyperUsageError.missingCredentials
            }
            self.log.error("Charm Hyper API returned \(response.statusCode)")
            throw HyperUsageError.apiError("HTTP \(response.statusCode)")
        }
        return try self.parseSnapshot(data: data)
    }

    static func _parseSnapshotForTesting(_ data: Data, now: Date = Date()) throws -> HyperUsageSnapshot {
        try self.parseSnapshot(data: data, now: now)
    }

    private static func parseSnapshot(data: Data, now: Date = Date()) throws -> HyperUsageSnapshot {
        do {
            let response = try JSONDecoder().decode(HyperCreditsResponse.self, from: data)
            guard response.balance.isFinite, response.balance >= 0 else {
                throw HyperUsageError.parseFailed("Balance must be a non-negative number")
            }
            return HyperUsageSnapshot(balance: response.balance, updatedAt: now)
        } catch let error as HyperUsageError {
            throw error
        } catch {
            throw HyperUsageError.parseFailed(error.localizedDescription)
        }
    }
}
