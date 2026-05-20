import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum WaferUsageError: LocalizedError, Sendable {
    case missingCredentials
    case networkError(String)
    case apiError(String)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "Missing Wafer API key."
        case let .networkError(message):
            "Wafer network error: \(message)"
        case let .apiError(message):
            "Wafer API error: \(message)"
        case let .parseFailed(message):
            "Failed to parse Wafer response: \(message)"
        }
    }
}

private struct WaferModelsResponse: Decodable {
    let data: [WaferModel]
}

private struct WaferModel: Decodable {
    let id: String
}

public struct WaferUsageFetcher: Sendable {
    private static let log = CodexBarLog.logger(LogCategories.waferUsage)
    private static let modelsURL = URL(string: "https://pass.wafer.ai/v1/models")!
    private static let timeoutSeconds: TimeInterval = 15

    public static func fetchUsage(
        apiKey: String,
        session transport: any ProviderHTTPTransport = ProviderHTTPClient.shared) async throws -> WaferUsageSnapshot
    {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw WaferUsageError.missingCredentials
        }

        var request = URLRequest(url: self.modelsURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = Self.timeoutSeconds

        let response: ProviderHTTPResponse
        do {
            response = try await transport.response(for: request)
        } catch {
            throw WaferUsageError.networkError(error.localizedDescription)
        }

        guard response.statusCode == 200 else {
            let body = String(data: response.data, encoding: .utf8) ?? ""
            self.log.error("Wafer API returned \(response.statusCode): \(body)")
            throw WaferUsageError.apiError("HTTP \(response.statusCode)")
        }

        do {
            _ = try JSONDecoder().decode(WaferModelsResponse.self, from: response.data)
        } catch {
            self.log.error("Failed to parse Wafer response: \(error.localizedDescription)")
            throw WaferUsageError.parseFailed(error.localizedDescription)
        }

        return WaferUsageSnapshot(isAvailable: true, updatedAt: Date())
    }
}
