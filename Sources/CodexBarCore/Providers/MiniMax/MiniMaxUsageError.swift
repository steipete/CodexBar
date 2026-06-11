import Foundation

public enum MiniMaxUsageError: LocalizedError, Sendable, Equatable {
    case invalidCredentials
    case networkError(String)
    case apiError(String)
    case parseFailed(String)
    case invalidEndpointOverride(String)

    public var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            "MiniMax credentials are invalid or expired."
        case let .networkError(message):
            "MiniMax network error: \(message)"
        case let .apiError(message):
            "MiniMax API error: \(message)"
        case let .parseFailed(message):
            "Failed to parse MiniMax coding plan: \(message)"
        case let .invalidEndpointOverride(key):
            "MiniMax endpoint override \(key) is not allowed. " +
                "Use an HTTPS endpoint without user info or encoded host tricks. " +
                "If MINIMAX_REQUIRE_PROVIDER_ENDPOINT_OVERRIDES=true is set, the endpoint must also be MiniMax-owned."
        }
    }
}
