import Foundation

public struct MiniMaxAPISettingsReader: Sendable {
    public static let apiTokenKey = "MINIMAX_API_KEY"
    public static let codingPlanAPITokenKey = "MINIMAX_CODING_API_KEY"
    public static let apiTokenEnvironmentKeys = [
        Self.codingPlanAPITokenKey,
        Self.apiTokenKey,
    ]

    public enum APIKeyKind: Sendable {
        case codingPlan
        case standard
        case unknown
    }

    public static func apiToken(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        for key in self.apiTokenEnvironmentKeys {
            if let token = SettingsValue.cleaned(environment[key]) { return token }
        }
        return nil
    }

    public static func apiKeyKind(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> APIKeyKind?
    {
        self.apiKeyKind(token: self.apiToken(environment: environment))
    }

    public static func apiKeyKind(token: String?) -> APIKeyKind? {
        guard let cleaned = SettingsValue.cleaned(token) else { return nil }
        if cleaned.hasPrefix("sk-cp-") { return .codingPlan }
        if cleaned.hasPrefix("sk-api-") { return .standard }
        return .unknown
    }
}

public enum MiniMaxAPISettingsError: LocalizedError, Sendable {
    case missingToken

    public var errorDescription: String? {
        switch self {
        case .missingToken:
            "MiniMax API token not found. Set apiKey in ~/.codexbar/config.json, " +
                "MINIMAX_CODING_API_KEY, or MINIMAX_API_KEY."
        }
    }
}
