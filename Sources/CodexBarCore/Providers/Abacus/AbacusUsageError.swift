import Foundation

public enum AbacusUsageError: LocalizedError, Sendable {
    case noSessionCookie
    case sessionExpired
    case networkError(String)
    case parseFailed(String)
    case unauthorized

    /// Whether this error indicates an authentication/session problem that
    /// should trigger cache eviction and candidate fallthrough.
    public var isRecoverable: Bool {
        switch self {
        case .unauthorized, .sessionExpired, .parseFailed: true
        default: false
        }
    }

    public var isAuthRelated: Bool {
        switch self {
        case .unauthorized, .sessionExpired: true
        default: false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .noSessionCookie:
            "No Abacus AI session found. Please log in to apps.abacus.ai in your browser."
        case .sessionExpired:
            "Abacus AI session expired. Please log in again."
        case let .networkError(msg):
            "Abacus AI API error: \(msg)"
        case let .parseFailed(msg):
            "Could not parse Abacus AI usage: \(msg)"
        case .unauthorized:
            "Unauthorized. Please log in to Abacus AI."
        }
    }
}

#if !os(macOS)
extension AbacusUsageError {
    static let notSupported = AbacusUsageError.networkError("Abacus AI is only supported on macOS.")
}
#endif
