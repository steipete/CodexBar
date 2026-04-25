import Foundation

public enum MistralUsageError: LocalizedError, Sendable {
    case missingCookie
    case invalidCredentials
    case apiError(String)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingCookie:
            "No Mistral session cookies found in browsers."
        case .invalidCredentials:
            "Mistral session expired or invalid (HTTP 401/403)."
        case let .apiError(detail):
            "Mistral API error: \(detail)"
        case let .parseFailed(detail):
            "Failed to parse Mistral billing response: \(detail)"
        }
    }
}

enum MistralSettingsError: LocalizedError {
    case missingCookie
    case invalidCookie

    var errorDescription: String? {
        switch self {
        case .missingCookie:
            "No Mistral session cookies found in browsers."
        case .invalidCookie:
            "Mistral cookie header is invalid or missing ory_session cookie."
        }
    }
}
