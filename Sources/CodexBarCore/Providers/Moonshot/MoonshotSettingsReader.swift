import Foundation

public struct MoonshotSettingsReader: Sendable {
    public static let apiKeyEnvironmentKeys = [
        "MOONSHOT_API_KEY",
        "MOONSHOT_KEY",
    ]
    public static let regionEnvironmentKey = "MOONSHOT_REGION"

    public static func apiKey(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
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
        if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
            (value.hasPrefix("'") && value.hasSuffix("'"))
        {
            value.removeFirst()
            value.removeLast()
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
