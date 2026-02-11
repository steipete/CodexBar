import Foundation

public enum CodeBuddyAPIError: LocalizedError, Sendable, Equatable {
    case missingCookies
    case missingEnterpriseID
    case invalidCookies
    case invalidRequest(String)
    case networkError(String)
    case apiError(String)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingCookies:
            "CodeBuddy cookies are missing. Please import cookies from your browser."
        case .missingEnterpriseID:
            "CodeBuddy enterprise ID is missing. Please sign in to CodeBuddy dashboard."
        case .invalidCookies:
            "CodeBuddy cookies are invalid or expired. Please re-import cookies."
        case let .invalidRequest(message):
            "Invalid request: \(message)"
        case let .networkError(message):
            "CodeBuddy network error: \(message)"
        case let .apiError(message):
            "CodeBuddy API error: \(message)"
        case let .parseFailed(message):
            "Failed to parse CodeBuddy usage data: \(message)"
        }
    }
}
