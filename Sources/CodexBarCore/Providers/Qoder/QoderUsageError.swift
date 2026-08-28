import Foundation

public enum QoderUsageError: LocalizedError, Sendable, Equatable {
    case missingCredentials
    case invalidCredentials
    case apiError(Int)
    case parseFailed(String)
    case networkError(String)

    public var isAuthRelated: Bool {
        switch self {
        case .missingCredentials, .invalidCredentials: true
        case .apiError, .parseFailed, .networkError: false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "Qoder session cookie not found. Sign in to qoder.com or qoder.com.cn in Chrome, or paste a Cookie header."
        case .invalidCredentials:
            "Qoder session is invalid or expired. Please sign in to Qoder again."
        case let .apiError(status):
            "Qoder API returned HTTP \(status)."
        case let .parseFailed(message):
            "Could not parse Qoder usage: \(message)"
        case let .networkError(message):
            "Qoder API error: \(message)"
        }
    }
}
