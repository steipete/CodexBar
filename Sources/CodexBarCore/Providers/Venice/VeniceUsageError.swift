import Foundation

public enum VeniceUsageError: LocalizedError, Sendable, Equatable {
    case missingCredentials
    case invalidCredentials
    case anonymousSession
    case expiredSession
    case missingQuota
    case tokenAccountUnsupported
    case networkError(String)
    case apiError(Int)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "Venice browser session cookie not found. Sign in to venice.ai in your browser."
        case .invalidCredentials:
            "Venice browser session is invalid or expired. Sign in to venice.ai again."
        case .anonymousSession:
            "Venice browser session is anonymous and has no subscription quota."
        case .expiredSession:
            "Venice browser session token is expired. Sign in to venice.ai again."
        case .missingQuota:
            "Venice browser session did not include subscription quota."
        case let .networkError(message):
            "Venice network error: \(message)"
        case let .apiError(status):
            "Venice session API returned status \(status)."
        case let .parseFailed(message):
            "Could not parse Venice session: \(message)"
        case .tokenAccountUnsupported:
            "Venice web quota cannot be scoped to a token account. Fetch without --account."
        }
    }

    /// Session-specific authentication failures: worth retrying with the next
    /// imported browser profile instead of failing the whole fetch.
    public var isSessionAuthenticationFailure: Bool {
        switch self {
        case .invalidCredentials, .anonymousSession, .expiredSession:
            true
        default:
            false
        }
    }

    public var isAuthRelated: Bool {
        switch self {
        case .missingCredentials, .invalidCredentials, .anonymousSession, .expiredSession:
            true
        default:
            false
        }
    }
}
