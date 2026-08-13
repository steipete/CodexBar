import Foundation

public enum ReplicateUsageError: LocalizedError, Sendable, Equatable {
    case missingCookie
    case invalidCookie
    case invalidCredentials
    case rateLimited
    case apiError(Int)
    case parseFailed(String)
    case networkError(String)

    public var errorDescription: String? {
        switch self {
        case .missingCookie:
            "No Replicate session cookies found. Sign in at replicate.com/account/billing, then refresh."
        case .invalidCookie:
            "Replicate cookie header is invalid. Paste a Cookie header from a billing-page request."
        case .invalidCredentials:
            "Replicate session rejected. Sign in again or paste a fresh Cookie header."
        case .rateLimited:
            "Replicate rate limit exceeded. Usage will refresh on the next cycle."
        case let .apiError(code):
            "Replicate billing API returned HTTP \(code)."
        case let .parseFailed(message):
            "Could not parse Replicate billing data: \(message)"
        case let .networkError(message):
            "Replicate network error: \(message)"
        }
    }
}
