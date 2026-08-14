import Foundation

public enum MuseSettingsReader: Sendable {
    public static let apiKeyEnvironmentKeys = ["MUSE_API_KEY", "META_API_KEY", "META_MUSE_API_KEY"]
    public static let baseURLEnvironmentKey = "MUSE_API_URL"

    public static func apiKey(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        for key in apiKeyEnvironmentKeys {
            if let value = cleaned(environment[key]) {
                return value
            }
        }
        return nil
    }

    public static func baseURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        cleaned(environment[baseURLEnvironmentKey])
    }

    private static func cleaned(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
            value = String(value.dropFirst().dropLast())
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
