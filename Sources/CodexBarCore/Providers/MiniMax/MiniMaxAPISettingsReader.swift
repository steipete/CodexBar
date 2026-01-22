import Foundation

public struct MiniMaxAPISettingsReader: Sendable {
    public static let apiTokenKey = "MINIMAX_API_KEY"

    public enum APIKeyKind: Sendable {
        case codingPlan
        case standard
        case unknown
    }

    public static func apiToken(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        if let token = self.cleaned(environment[apiTokenKey]) { return token }
        return nil
    }

    public static func apiKeyKind(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> APIKeyKind?
    {
        self.apiKeyKind(token: self.apiToken(environment: environment))
    }

    public static func apiKeyKind(token: String?) -> APIKeyKind? {
        guard let cleaned = self.cleaned(token) else { return nil }
        if cleaned.hasPrefix("sk-cp-") { return .codingPlan }
        if cleaned.hasPrefix("sk-api-") { return .standard }
        return .unknown
    }

    static func cleaned(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }

        if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
            (value.hasPrefix("'") && value.hasSuffix("'"))
        {
            value.removeFirst()
            value.removeLast()
        }

        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

public enum MiniMaxAPISettingsError: LocalizedError, Sendable {
    case missingToken

    public var errorDescription: String? {
        switch self {
        case .missingToken:
            "MiniMax API token not found. Set apiKey in ~/.codexbar/config.json or MINIMAX_API_KEY."
        }
    }
}
