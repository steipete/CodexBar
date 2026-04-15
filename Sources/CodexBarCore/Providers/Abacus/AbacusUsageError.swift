import Foundation

// MARK: - Abacus Usage Error

public enum AbacusUsageError: LocalizedError, Sendable, Equatable {
    case noSessionCookie
    case sessionExpired
    case networkError(String)
    case parseFailed(String)
    case unauthorized

    /// Whether this error indicates an authentication/session problem that
    /// should trigger cache eviction and candidate fallthrough.
    /// Parse failures are deterministic — retrying with another session
    /// produces the same result, so they are NOT recoverable.
    public var isRecoverable: Bool {
        switch self {
        case .unauthorized, .sessionExpired: true
        default: false
        }
    }

    public var isAuthRelated: Bool {
        self.isRecoverable
    }

    public var errorDescription: String? {
        switch self {
        case .noSessionCookie:
            "No Abacus AI session found. Please log in to apps.abacus.ai in your browser or paste a Cookie header in manual mode."
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
    public static let notSupported = AbacusUsageError.networkError("Abacus AI is only supported on macOS.")
}
#endif
