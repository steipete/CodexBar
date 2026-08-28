import Foundation

public enum KimiAPIError: LocalizedError, Sendable, Equatable {
    case missingToken
    case invalidToken
    case missingAPIKey
    case invalidAPIKey
    case invalidRequest(String)
    case networkError(String)
    case apiError(String)
    case parseFailed(String)
    case expiredCodeCredential
    case invalidCodeCredential

    public var errorDescription: String? {
        switch self {
        case .missingToken:
            "Kimi auth token is missing. Please add your JWT token from the Kimi console."
        case .invalidToken:
            "Kimi auth token is invalid or expired. Please refresh your token."
        case .missingAPIKey:
            "Kimi Code API key is missing. Add it in Settings > Providers > Kimi or set KIMI_CODE_API_KEY."
        case .invalidAPIKey:
            "Kimi Code API key is invalid or expired. Please refresh your API key."
        case let .invalidRequest(message):
            "Invalid request: \(message)"
        case let .networkError(message):
            "Kimi network error: \(message)"
        case let .apiError(message):
            "Kimi API error: \(message)"
        case let .parseFailed(message):
            "Failed to parse Kimi usage data: \(message)"
        case .expiredCodeCredential:
            "Kimi Code CLI credential is expired. Sign in again with Kimi Code CLI or set KIMI_CODE_API_KEY; " +
                "CodexBar does not refresh CLI-owned credentials."
        case .invalidCodeCredential:
            "Kimi Code CLI credential is invalid or expired. Sign in again with Kimi Code CLI or set " +
                "KIMI_CODE_API_KEY; CodexBar does not refresh CLI-owned credentials."
        }
    }
}
