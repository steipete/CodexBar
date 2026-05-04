import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct OpenAICompatibleVerifier: Sendable {
    public struct Result: Sendable {
        public let isConnected: Bool
        public let modelCount: Int
        public let modelNames: [String]
        public let verifiedAt: Date

        public init(isConnected: Bool, modelCount: Int, modelNames: [String], verifiedAt: Date) {
            self.isConnected = isConnected
            self.modelCount = modelCount
            self.modelNames = modelNames
            self.verifiedAt = verifiedAt
        }
    }

    public enum VerificationError: LocalizedError, Sendable {
        case missingCredentials
        case networkError(String)
        case apiError(String)
        case parseFailed(String)

        public var errorDescription: String? {
            switch self {
            case .missingCredentials:
                "Missing API key."
            case let .networkError(message):
                "Network error: \(message)"
            case let .apiError(message):
                "API error: \(message)"
            case let .parseFailed(message):
                "Failed to parse response: \(message)"
            }
        }
    }

    private static let timeoutSeconds: TimeInterval = 15

    public static func verify(
        baseURL: URL,
        apiKey: String,
        logger: CodexBarLogger? = nil
    ) async throws -> Result {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VerificationError.missingCredentials
        }

        let modelsURL = baseURL.appendingPathComponent("models")
        var request = URLRequest(url: modelsURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = Self.timeoutSeconds

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw VerificationError.networkError("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            logger?.error("API returned \(httpResponse.statusCode): \(body)")
            throw VerificationError.apiError("HTTP \(httpResponse.statusCode)")
        }

        return try Self.parseResult(data: data)
    }

    static func _parseResultForTesting(_ data: Data) throws -> Result {
        try self.parseResult(data: data)
    }

    private static func parseResult(data: Data) throws -> Result {
        let decoded: ModelsResponse
        do {
            decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
        } catch {
            throw VerificationError.parseFailed(error.localizedDescription)
        }

        let modelNames = decoded.data.prefix(5).map(\.id)
        return Result(
            isConnected: true,
            modelCount: decoded.data.count,
            modelNames: Array(modelNames),
            verifiedAt: Date())
    }
}

// MARK: - API response types

private struct ModelsResponse: Decodable, Sendable {
    let data: [ModelEntry]
}

private struct ModelEntry: Decodable, Sendable {
    let id: String
}
