import Foundation

public struct HyperSettingsReader: Sendable {
    public static let apiKeyEnvironmentKey = "HYPER_API_KEY"

    public static let apiKeyEnvironmentKeys = [
        Self.apiKeyEnvironmentKey,
    ]

    public static func apiKey(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        for key in self.apiKeyEnvironmentKeys {
            guard let token = self.cleaned(environment[key]) else { continue }
            return token
        }
        return nil
    }

    static func cleaned(_ raw: String?) -> String? {
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
