import Foundation

public struct MoonshotSettingsReader: Sendable {
    public static let apiKeyEnvironmentKeys = [
        "MOONSHOT_API_KEY",
        "MOONSHOT_KEY",
    ]
    public static let regionEnvironmentKey = "MOONSHOT_REGION"
    public static let configAPIKeyEnvironmentKey = "CODEXBAR_MOONSHOT_API_KEY"
    public static let configAPIKeyRegionEnvironmentKey = "CODEXBAR_MOONSHOT_API_KEY_REGION"

    public static func apiKey(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        self.apiKey(for: self.region(environment: environment), environment: environment)
    }

    public static func apiKey(
        for region: MoonshotRegion,
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        if let apiKey = self.regionBoundConfigAPIKey(for: region, environment: environment) {
            return apiKey
        }

        guard self.region(environment: environment) == region else { return nil }
        for key in self.apiKeyEnvironmentKeys {
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

    private static func regionBoundConfigAPIKey(
        for region: MoonshotRegion,
        environment: [String: String]) -> String?
    {
        guard let rawRegion = environment[self.configAPIKeyRegionEnvironmentKey],
              MoonshotRegion(rawValue: cleaned(rawRegion).lowercased()) == region,
              let rawKey = environment[self.configAPIKeyEnvironmentKey]
        else { return nil }
        let key = Self.cleaned(rawKey)
        return key.isEmpty ? nil : key
    }

    public static func region(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> MoonshotRegion
    {
        guard let raw = environment[self.regionEnvironmentKey] else {
            return .international
        }
        let cleaned = Self.cleaned(raw).lowercased()
        return MoonshotRegion(rawValue: cleaned) ?? .international
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
