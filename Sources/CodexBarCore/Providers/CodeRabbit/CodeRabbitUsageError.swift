import Foundation

public enum CodeRabbitUsageError: LocalizedError, Sendable, Equatable {
    case notLoggedIn
    case cliFailed(Int32)
    case parseFailed

    public var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            "Not signed in to CodeRabbit. Run coderabbit auth login."
        case let .cliFailed(code):
            "CodeRabbit CLI failed with exit code \(code). Run coderabbit usage for details."
        case .parseFailed:
            "Could not extract review or billing information from CodeRabbit CLI output."
        }
    }
}
