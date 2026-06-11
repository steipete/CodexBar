import Foundation

public enum KimiSettingsReader {
    public static let apiKeyEnvironmentKeys = [
        "KIMI_CODE_API_KEY",
        "KIMI_API_KEY",
    ]
    public static let codeAPIBaseURLEnvironmentKey = "KIMI_CODE_BASE_URL"
    public static let defaultCodeAPIBaseURL = URL(string: "https://api.kimi.com")!

    public static func authToken(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let raw = environment["KIMI_AUTH_TOKEN"] ?? environment["kimi_auth_token"]
        return self.cleaned(raw)
    }

    public static func apiKey(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        for key in self.apiKeyEnvironmentKeys {
            if let value = self.cleaned(environment[key]) {
                return value
            }
        }
        return nil
    }

    public static func codeAPIBaseURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        guard let raw = self.cleaned(environment[self.codeAPIBaseURLEnvironmentKey]),
              URL(string: raw)?.scheme != nil,
              let url = ProviderEndpointOverrideValidator().validatedURL(raw)
        else {
            return self.defaultCodeAPIBaseURL
        }
        return url
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
