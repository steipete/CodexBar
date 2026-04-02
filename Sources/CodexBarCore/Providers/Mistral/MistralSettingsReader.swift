import Foundation

public enum MistralSettingsReader {
    public static let apiKeyEnvironmentKey = "MISTRAL_API_KEY"
    public static let apiTokenKey = apiKeyEnvironmentKey
    public static let manualCookieEnvironmentKeys = [
        "MISTRAL_COOKIE_HEADER",
        "MISTRAL_COOKIE",
        "MISTRAL_MANUAL_COOKIE",
    ]
    public static let csrfTokenEnvironmentKeys = [
        "MISTRAL_CSRF_TOKEN",
    ]

    public static func apiKey(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        self.cleaned(environment[self.apiKeyEnvironmentKey])
    }

    public static func apiToken(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        self.apiKey(environment: environment)
    }

    public static func apiURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = self.cleaned(environment["MISTRAL_API_URL"]),
           let url = URL(string: override)
        {
            return url
        }
        return URL(string: "https://api.mistral.ai/v1")!
    }

    public static func adminURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = self.cleaned(environment["MISTRAL_ADMIN_URL"]),
           let url = URL(string: override)
        {
            return url
        }
        return URL(string: "https://admin.mistral.ai")!
    }

    public static func consoleURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = self.cleaned(environment["MISTRAL_CONSOLE_URL"]),
           let url = URL(string: override)
        {
            return url
        }
        return URL(string: "https://console.mistral.ai")!
    }

    public static func csrfToken(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        for key in self.csrfTokenEnvironmentKeys {
            if let value = self.cleaned(environment[key]) {
                return value
            }
        }
        return nil
    }

    public static func cookieHeader(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        for key in self.manualCookieEnvironmentKeys {
            if let value = CookieHeaderNormalizer.normalize(environment[key]) {
                return value
            }
        }
        return nil
    }

    public static func cookieOverride(environment: [String: String] = ProcessInfo.processInfo.environment)
        -> MistralCookieOverride?
    {
        MistralCookieHeader.override(
            from: self.cookieHeader(environment: environment),
            explicitCSRFToken: self.csrfToken(environment: environment))
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
