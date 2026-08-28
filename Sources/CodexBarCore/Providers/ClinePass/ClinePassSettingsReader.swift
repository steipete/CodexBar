import Foundation

public enum ClinePassSettingsReader {
    public static let apiKeyEnvironmentKey = "CLINE_API_KEY"
    public static let alternateAPIKeyEnvironmentKey = "CLINEPASS_API_KEY"
    public static let apiKeyEnvironmentKeys = [
        Self.apiKeyEnvironmentKey,
        Self.alternateAPIKeyEnvironmentKey,
    ]

    public static func apiKey(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        for key in self.apiKeyEnvironmentKeys {
            if let value = self.cleaned(environment[key]) {
                return value
            }
        }
        return nil
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
