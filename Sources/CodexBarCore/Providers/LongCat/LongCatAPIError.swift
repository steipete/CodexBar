import Foundation

public enum LongCatAPIError: LocalizedError, Sendable, Equatable {
    case missingCookies
    case invalidSession
    case invalidRequest(String)
    case networkError(String)
    case apiError(String)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingCookies:
            "LongCat session cookies are missing. Sign in at longcat.chat, or paste a cookie header."
        case .invalidSession:
            "LongCat session is invalid or expired. Please sign in again at longcat.chat."
        case let .invalidRequest(message):
            "Invalid request: \(message)"
        case let .networkError(message):
            "LongCat network error: \(message)"
        case let .apiError(message):
            "LongCat API error: \(message)"
        case let .parseFailed(message):
            "Failed to parse LongCat usage data: \(message)"
        }
    }
}
