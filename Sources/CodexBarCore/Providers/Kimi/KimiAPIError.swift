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
            "Kimi Code credentials are missing. Sign into the Kimi CLI or provide KIMI_API_KEY."
        case .invalidToken:
            "Kimi Code credentials are invalid or expired."
        case let .invalidRequest(message):
            "Kimi request failed: \(message)"
        case let .networkError(message):
            "Kimi network error: \(message)"
        case let .apiError(message):
            "Kimi API error: \(message)"
        case let .parseFailed(message):
            "Failed to parse Kimi usage data: \(message)"
        }
    }
}
