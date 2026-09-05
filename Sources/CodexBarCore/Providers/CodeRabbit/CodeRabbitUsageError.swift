import Foundation

public enum CodeRabbitUsageError: LocalizedError, Sendable, Equatable {
    case notLoggedIn
    case missingCredentials
    case cliFailed(String)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            "Not signed in to CodeRabbit. Run `coderabbit auth login`."
        case .missingCredentials:
            "CodeRabbit credentials not found. Run `coderabbit auth login`."
        case let .cliFailed(message):
            "CodeRabbit CLI error: \(message)"
        case let .parseFailed(message):
            "Failed to parse CodeRabbit usage: \(message)"
        }
    }
}
