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
            "CommandCode session cookie not found. Sign in to commandcode.ai in Chrome."
        case .invalidCredentials:
            "CommandCode session is invalid or expired. Sign in to commandcode.ai again."
        case let .networkError(message):
            "CommandCode network error: \(message)"
        case let .apiError(status):
            "CommandCode API returned status \(status)."
        case let .parseFailed(message):
            "Could not parse CommandCode response: \(message)"
        case let .unknownPlan(planID):
            "Unknown CommandCode plan: \(planID). Add it to CommandCodePlanCatalog."
        }
    }

    public var isAuthRelated: Bool {
        switch self {
        case .missingCredentials, .invalidCredentials: true
        default: false
        }
    }
}
