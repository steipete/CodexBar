import Foundation

public enum KimiAPIError: LocalizedError, Sendable, Equatable {
    case missingToken
    case invalidToken
    case invalidRequest(String)
    case networkError(String)
    case apiError(String)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingToken:
            "Kimi auth token is missing. Please add your JWT token from the Kimi console."
        case .invalidToken:
            "Kimi auth token is invalid or expired. Please refresh your token."
        case let .invalidRequest(message):
            "Invalid request: \(message)"
        case let .networkError(message):
            "Kimi network error: \(message)"
        case let .apiError(message):
            "Kimi API error: \(message)"
        case let .parseFailed(message):
            "Failed to parse Kimi usage data: \(message)"
        }
    }
}
