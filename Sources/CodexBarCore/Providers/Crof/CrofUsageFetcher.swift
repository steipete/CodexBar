import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct CrofUsageResponse: Decodable, Sendable {
    public let credits: Double
    public let requestsPlan: Double
    public let usableRequests: Double

    enum CodingKeys: String, CodingKey {
        case credits
        case requestsPlan = "requests_plan"
        case usableRequests = "usable_requests"
    }
}

public enum CrofUsageError: LocalizedError, Sendable, Equatable {
    case missingCredentials
    case networkError(String)
    case apiError(Int)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "Missing Crof API key."
        case let .networkError(message):
            "Crof network error: \(message)"
        case let .apiError(statusCode):
            "Crof API error: HTTP \(statusCode)"
        case let .parseFailed(message):
            "Failed to parse Crof response: \(message)"
        }
    }
}

public enum CrofUsageFetcher {
    public static let usageURL = URL(string: "https://crof.ai/usage_api/")!
    private static let timeoutSeconds: TimeInterval = 15

    public static func fetchUsage(
        apiKey: String,
        session: URLSession = .shared) async throws -> CrofUsageSnapshot
    {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CrofUsageError.missingCredentials
        }

        var request = URLRequest(url: self.usageURL)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.timeoutSeconds
        request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw CrofUsageError.networkError(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CrofUsageError.networkError("Invalid response")
        }
        guard httpResponse.statusCode == 200 else {
            throw CrofUsageError.apiError(httpResponse.statusCode)
        }

        return try self.parseSnapshot(data)
    }

    static func _parseSnapshotForTesting(_ data: Data) throws -> CrofUsageSnapshot {
        try self.parseSnapshot(data)
    }

    private static func parseSnapshot(_ data: Data) throws -> CrofUsageSnapshot {
        let decoded: CrofUsageResponse
        do {
            decoded = try JSONDecoder().decode(CrofUsageResponse.self, from: data)
        } catch {
            throw CrofUsageError.parseFailed(error.localizedDescription)
        }

        return CrofUsageSnapshot(
            credits: decoded.credits,
            requestsPlan: decoded.requestsPlan,
            usableRequests: decoded.usableRequests,
            updatedAt: Date())
    }
}
