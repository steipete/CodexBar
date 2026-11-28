import Foundation

public enum MistralUsageError: LocalizedError, Sendable {
    case missingCookie
    case invalidCredentials
    case httpStatus(Int)
    case apiError(String)
    case parseFailed(String)

    var allowsPartialBilling: Bool {
        switch self {
        case .httpStatus(404), .httpStatus(410), .parseFailed:
            true
        case let .httpStatus(status):
            (500...599).contains(status)
        default:
            false
        }
    }

    var partialBillingDiagnostic: String {
        switch self {
        case let .httpStatus(status):
            "Mistral spend and token history unavailable (HTTP \(status)); showing available allowances or credits."
        default:
            "Mistral spend and token history unavailable; the billing response was not usable."
        }
    }

    public var errorDescription: String? {
        switch self {
        case .missingCookie:
            "No Mistral session cookies found in browsers."
        case .invalidCredentials:
            UsageFormatter.localized("Mistral session expired or invalid.")
        case let .httpStatus(status):
            "Mistral API error: HTTP \(status)"
        case let .apiError(detail):
            "Mistral API error: \(detail)"
        case let .parseFailed(detail):
            "Failed to parse Mistral billing response: \(detail)"
        }
    }
}

enum MistralSettingsError: LocalizedError {
    case missingCookie
    case invalidCookie

    var errorDescription: String? {
        switch self {
        case .missingCookie:
            "No Mistral session cookies found in browsers."
        case .invalidCookie:
            "Mistral cookie header is invalid or missing ory_session cookie."
        }
    }
}
