import Foundation

public struct FireworksSettingsReader: Sendable {
    public static let apiKeyEnvironmentKeys = [
        "FIREWORKS_API_KEY",
        "FIREWORKS_KEY",
    ]
    public static let accountSlugEnvironmentKey = "FIREWORKS_ACCOUNT_SLUG"
    public static let configAPIKeyEnvironmentKey = "CODEXBAR_FIREWORKS_API_KEY"
    public static let configAccountSlugEnvironmentKey = "CODEXBAR_FIREWORKS_ACCOUNT_SLUG"

    public static func apiKey(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        for key in [self.configAPIKeyEnvironmentKey] + self.apiKeyEnvironmentKeys {
            guard let raw = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty
            else {
                continue
            }
            let cleaned = Self.cleaned(raw)
            if !cleaned.isEmpty {
                return cleaned
            }
        }
        return nil
    }

    public static func accountSlug(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        for key in [self.configAccountSlugEnvironmentKey, self.accountSlugEnvironmentKey] {
            guard let raw = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty
            else {
                continue
            }
            let cleaned = Self.cleaned(raw)
            if !cleaned.isEmpty {
                return cleaned
            }
        }
        return nil
    }

    private static func cleaned(_ raw: String) -> String {
        var value = raw
        if (value.hasPrefix("\"") && value.hasSuffix("\""))
            || (value.hasPrefix("'") && value.hasSuffix("'"))
        {
            value = String(value.dropFirst().dropLast())
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
