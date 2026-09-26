import Foundation

public enum VeniceUsageError: LocalizedError, Sendable, Equatable {
    case missingCredentials
    case cookiesDisabled
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
        case .cookiesDisabled:
            "Venice browser cookies are disabled. Enable cookies in Settings to use the Web source."
        case .missingCredentials:
            "Venice session cookie not found (__session, __session_<suffix>, or __venice-auth.session-token). "
                + "Open a signed-in venice.ai tab and retry, or paste a fresh Cookie header."
        case .invalidCredentials, .expiredSession:
            "Venice browser session is invalid or expired. Keep a signed-in venice.ai tab active and retry; "
                + "Clerk sessions last about 60 seconds. In Manual mode, paste a fresh Cookie header."
        case .anonymousSession:
            "Venice browser session is anonymous and has no subscription quota."
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
