import Foundation

public enum CodebuffUsageError: LocalizedError, Sendable, Equatable {
    case missingCredentials
    case unauthorized
    case endpointNotFound
    case serviceUnavailable(Int)
    case apiError(Int)
    case networkError(String)
    case parseFailed(String)

    public static let missingToken: CodebuffUsageError = .missingCredentials

    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "Codebuff API token not configured. Set CODEBUFF_API_KEY or run `codebuff login` to " +
                "populate ~/.config/manicode/credentials.json."
        case .unauthorized:
            "Unauthorized. Please sign in to Codebuff again."
        case .endpointNotFound:
            "Codebuff usage endpoint not found."
        case let .serviceUnavailable(status):
            "Codebuff API is temporarily unavailable (status \(status))."
        case let .apiError(status):
            "Codebuff API returned an unexpected status (\(status))."
        case let .networkError(message):
            "Codebuff API error: \(message)"
        case let .parseFailed(message):
            "Could not parse Codebuff usage: \(message)"
        }
    }

    public var isAuthRelated: Bool {
        switch self {
        case .unauthorized, .missingCredentials: true
        default: false
        }
    }
}
