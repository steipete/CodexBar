import Foundation

public enum GroqSettingsReader {
    public static let apiKeyEnvironmentKey = "GROQ_API_KEY"
    public static let apiURLEnvironmentKey = "GROQ_API_URL"

    public static func apiKey(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        self.cleaned(environment[self.apiKeyEnvironmentKey])
    }

    public static func apiURL(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL
    {
        if let override = self.validAPIURL(environment: environment) {
            return override
        }
        return URL(string: "https://api.groq.com/v1")!
    }

    public static func validateEndpointOverrides(
        environment: [String: String] = ProcessInfo.processInfo.environment) throws
    {
        if self.hasExplicitNonHTTPSURL(environment[self.apiURLEnvironmentKey]) {
            throw GroqSettingsError.invalidEndpointOverride(self.apiURLEnvironmentKey)
        }
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

    private static func validAPIURL(environment: [String: String]) -> URL? {
        guard let raw = self.cleaned(environment[self.apiURLEnvironmentKey]) else { return nil }
        if let url = URL(string: raw), let scheme = url.scheme {
            return scheme.lowercased() == "https" ? url : nil
        }
        return URL(string: "https://\(raw)")
    }

    private static func hasExplicitNonHTTPSURL(_ raw: String?) -> Bool {
        guard let cleaned = self.cleaned(raw),
              let scheme = URL(string: cleaned)?.scheme
        else { return false }
        return scheme.lowercased() != "https"
    }
}

public enum GroqSettingsError: LocalizedError, Sendable, Equatable {
    case invalidEndpointOverride(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidEndpointOverride(key):
            return "Groq endpoint override \(key) must use HTTPS or a bare host."
        }
    }
}
