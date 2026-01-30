import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum PoeUsageError: LocalizedError, Sendable {
    case missingCredentials
    case networkError(String)
    case apiError(String)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "Missing POE_API_KEY environment variable."
        case let .networkError(message):
            "Poe network error: \(message)"
        case let .apiError(message):
            "Poe API error: \(message)"
        case let .parseFailed(message):
            "Failed to parse Poe response: \(message)"
        }
    }
}

public struct PoeUsageFetcher: Sendable {
    private static let log = CodexBarLog.logger(LogCategories.poeUsage)
    private static let balanceURL = URL(string: "https://api.poe.com/usage/current_balance")!

    public static func fetchUsage(apiKey: String) async throws -> PoeUsageSnapshot {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PoeUsageError.missingCredentials
        }

        var request = URLRequest(url: self.balanceURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PoeUsageError.networkError("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            Self.log.error("Poe API returned \(httpResponse.statusCode): \(body)")
            throw PoeUsageError.apiError(body)
        }

        if let jsonString = String(data: data, encoding: .utf8) {
            Self.log.debug("Poe API response: \(jsonString)")
        }

        return try Self.parseBalance(from: data)
    }

    /// Internal method for testing response parsing.
    public static func _parseBalanceForTesting(_ data: Data) throws -> PoeUsageSnapshot {
        try self.parseBalance(from: data)
    }

    private static func parseBalance(from data: Data) throws -> PoeUsageSnapshot {
        do {
            let decoded = try JSONDecoder().decode(PoeBalanceResponse.self, from: data)
            return PoeUsageSnapshot(pointBalance: decoded.currentPointBalance, updatedAt: Date())
        } catch {
            Self.log.error("Poe JSON decoding error: \(error.localizedDescription)")
            throw PoeUsageError.parseFailed(error.localizedDescription)
        }
    }
}
