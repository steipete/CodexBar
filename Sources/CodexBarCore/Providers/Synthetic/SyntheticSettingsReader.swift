import Foundation

public struct SyntheticSettingsReader: Sendable {
    public static let apiKeyKey = "SYNTHETIC_API_KEY"

    public static func apiKey(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        if let token = SettingsValue.cleaned(environment[apiKeyKey]) { return token }
        return nil
    }
}

public enum SyntheticSettingsError: LocalizedError, Sendable {
    case missingToken

    public var errorDescription: String? {
        switch self {
        case .missingToken:
            "Synthetic API key not found. Set apiKey in ~/.codexbar/config.json or SYNTHETIC_API_KEY."
        }
    }
}
