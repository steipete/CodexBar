import Foundation

public enum KiloSettingsReader {
    public static let apiTokenKey = "KILO_API_KEY"

    public static func apiToken(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        self.cleaned(environment[self.apiTokenKey])
    }

    static func cleaned(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }

        if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
            (value.hasPrefix("'") && value.hasSuffix("'"))
        {
            value.removeFirst()
            value.removeLast()
        }

        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

public enum KiloAPIError: LocalizedError, Sendable {
    case missingToken
    case invalidToken
    case networkError(String)
    case apiError(String)
    case parseFailed(String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .missingToken:
            "Kilo API token not found. Set KILO_API_KEY environment variable."
        case .invalidToken:
            "Invalid Kilo API token."
        case let .networkError(message):
            "Kilo network error: \(message)"
        case let .apiError(message):
            "Kilo API error: \(message)"
        case let .parseFailed(message):
            "Failed to parse Kilo response: \(message)"
        case .invalidResponse:
            "Invalid response from Kilo API"
        }
    }
}
