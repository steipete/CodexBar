import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum PoeUsageError: LocalizedError, Sendable {
    case missingCredentials
    case networkError(String)
    case apiError(String)
    case unauthorized
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "Missing Poe API token."
        case let .networkError(message):
            "Poe network error: \(message)"
        case let .apiError(message):
            "Poe API error: \(message)"
        case .unauthorized:
            "Invalid or expired Poe API token."
        case let .parseFailed(message):
            "Failed to parse Poe response: \(message)"
        }
    }
}

public struct PoeUsageFetcher: Sendable {
    private static let log = CodexBarLog.logger(LogCategories.poeUsage)
    private static let usageURL = URL(string: "https://api.poe.com/usage/current_balance")!
    private static let timeoutSeconds: TimeInterval = 15

    public static func fetchUsage(apiKey: String) async throws -> PoeUsageSnapshot {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw PoeUsageError.missingCredentials
        }

        var request = URLRequest(url: self.usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = Self.timeoutSeconds

        let response = try await ProviderHTTPClient.shared.response(for: request)
        let data = response.data
        guard response.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            Self.log.error("Poe API returned \(response.statusCode): \(body)")
            if response.statusCode == 401 || response.statusCode == 403 {
                throw PoeUsageError.unauthorized
            }
            throw PoeUsageError.apiError("HTTP \(response.statusCode)")
        }

        return try self.parseSnapshot(data: data)
    }

    static func _parseSnapshotForTesting(_ data: Data) throws -> PoeUsageSnapshot {
        try self.parseSnapshot(data: data)
    }

    private static func parseSnapshot(data: Data) throws -> PoeUsageSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PoeUsageError.parseFailed("Invalid JSON")
        }

        let balance = self.double(from: root["current_point_balance"])

        return PoeUsageSnapshot(
            currentPointBalance: balance,
            updatedAt: Date())
    }

    // MARK: - Value parsing

    private static func double(from value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            let raw = number.doubleValue
            return raw.isFinite ? raw : nil
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let raw = Double(trimmed), raw.isFinite else { return nil }
            return raw
        default:
            return nil
        }
    }
}
