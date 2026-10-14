import Foundation

public enum CommandCodeUsageError: LocalizedError, Sendable, Equatable {
    case missingCredentials
    case invalidCredentials
    case missingAPIKey
    case invalidAPIKey
    case networkError(String)
    case apiError(Int)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "Command Code session cookie not found. Sign in to commandcode.ai in Chrome."
        case .invalidCredentials:
            "Command Code session is invalid or expired. Sign in to commandcode.ai again."
        case .missingAPIKey:
            "Command Code API key not found. Set COMMAND_CODE_API_KEY or add a key in Settings."
        case .invalidAPIKey:
            "Command Code API key is invalid or expired. "
                + "Replace it in Settings or update COMMAND_CODE_API_KEY."
        case let .networkError(message):
            "Command Code network error: \(message)"
        case let .apiError(status):
            "Command Code API returned status \(status)."
        case let .parseFailed(message):
            "Could not parse Command Code response: \(message)"
        }
    }

    public var isAuthRelated: Bool {
        switch self {
        case .missingCredentials, .invalidCredentials, .missingAPIKey, .invalidAPIKey: true
        default: false
        }
    }
}
