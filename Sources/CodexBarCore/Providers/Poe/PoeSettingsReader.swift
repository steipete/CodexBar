import Foundation

public enum PoeSettingsReader {
    public static let apiKeyEnvironmentKey = "POE_API_KEY"
    public static let oauthAPIKeyEnvironmentKey = "POE_OAUTH_API_KEY"
    public static let oauthAPIKeyExpiresAtEnvironmentKey = "POE_OAUTH_API_KEY_EXPIRES_AT"
    public static let oauthAPIKeyExpiresInEnvironmentKey = "POE_OAUTH_API_KEY_EXPIRES_IN"

    public static func apiKey(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        self.cleaned(environment[self.apiKeyEnvironmentKey])
    }

    public static func oauthAPIKey(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        self.cleaned(environment[self.oauthAPIKeyEnvironmentKey])
    }

    public static func oauthAPIKeyIsExpired(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()) -> Bool
    {
        if let expiresAt = self.oauthAPIKeyExpiresAt(environment: environment) {
            return expiresAt <= now
        }
        if let expiresIn = self.oauthAPIKeyExpiresIn(environment: environment) {
            return expiresIn <= 0
        }
        return false
    }

    public static func oauthAPIKeyExpiresAt(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> Date?
    {
        guard let raw = self.cleaned(environment[self.oauthAPIKeyExpiresAtEnvironmentKey]) else {
            return nil
        }
        if let timestamp = TimeInterval(raw) {
            return Date(timeIntervalSince1970: timestamp)
        }
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: raw)
    }

    public static func oauthAPIKeyExpiresIn(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> TimeInterval?
    {
        guard let raw = self.cleaned(environment[self.oauthAPIKeyExpiresInEnvironmentKey]),
              let value = TimeInterval(raw)
        else {
            return nil
        }
        return value
    }

    private static func cleaned(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }

        if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
            (value.hasPrefix("'") && value.hasSuffix("'"))
        {
            value = String(value.dropFirst().dropLast())
        }

        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
