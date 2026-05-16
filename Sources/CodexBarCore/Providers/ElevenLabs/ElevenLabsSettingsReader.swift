import Foundation

public enum ElevenLabsSettingsReader {
    public static let apiKeyEnvironmentKey = "ELEVENLABS_API_KEY"
    public static let apiKeyEnvironmentKeys = [
        Self.apiKeyEnvironmentKey,
        "XI_API_KEY",
    ]
    public static let apiURLEnvironmentKey = "ELEVENLABS_API_URL"

    public static func apiKey(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        for key in self.apiKeyEnvironmentKeys {
            guard let token = self.cleaned(environment[key]) else { continue }
            return token
        }
        return nil
    }

    public static func apiURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = self.cleaned(environment[self.apiURLEnvironmentKey]),
           let url = URL(string: override)
        {
            return url
        }
        return URL(string: "https://api.elevenlabs.io")!
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
