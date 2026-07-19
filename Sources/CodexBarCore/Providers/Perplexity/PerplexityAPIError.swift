import Foundation

public enum PerplexityAPIError: LocalizedError, Sendable, Equatable {
    case missingToken
    case invalidCookie
    case invalidToken
    case networkError(String)
    case apiError(String)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingToken:
            "Perplexity session token is missing. Please log into Perplexity in your browser."
        case .invalidCookie:
            "Perplexity manual cookie header is empty or invalid."
        case .invalidToken:
            "Perplexity session token is invalid or expired. Please log in again."
        case let .networkError(message):
            "Perplexity network error: \(message)"
        case let .apiError(message):
            "Perplexity API error: \(message)"
        case let .parseFailed(message):
            "Failed to parse Perplexity usage data: \(message)"
        }
    }
}
