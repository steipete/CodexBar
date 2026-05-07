import Foundation

public enum CommandCodeUsageError: LocalizedError, Sendable, Equatable {
    case missingCredentials
    case invalidCredentials
    case networkError(String)
    case apiError(Int)
    case parseFailed(String)
    case unknownPlan(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "Command Code session cookie not found. Sign in to commandcode.ai in Chrome."
        case .invalidCredentials:
            "Command Code session is invalid or expired. Sign in to commandcode.ai again."
        case let .networkError(message):
            "Command Code network error: \(message)"
        case let .apiError(status):
            "Command Code API returned status \(status)."
        case let .parseFailed(message):
            "Could not parse Command Code response: \(message)"
        case let .unknownPlan(planID):
            "Unknown Command Code plan: \(planID). Add it to CommandCodePlanCatalog."
        }
    }

    public var isAuthRelated: Bool {
        switch self {
        case .missingCredentials, .invalidCredentials: true
        default: false
        }
    }
}
