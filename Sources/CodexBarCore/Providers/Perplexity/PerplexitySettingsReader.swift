import Foundation

public enum PerplexitySettingsReader {
    public static func sessionCookieOverride(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> PerplexityCookieOverride?
    {
        let raw = environment["PERPLEXITY_SESSION_TOKEN"]
            ?? environment["perplexity_session_token"]
        if let token = self.cleaned(raw) { return PerplexityCookieHeader.override(from: token) }

        // PERPLEXITY_COOKIE may be a full Cookie header string; preserve the matching session cookie name.
        if let cookieRaw = environment["PERPLEXITY_COOKIE"] {
            return PerplexityCookieHeader.override(from: self.cleaned(cookieRaw))
        }
        return nil
    }

    public static func sessionToken(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        self.sessionCookieOverride(environment: environment)?.token
    }

    private static func cleaned(_ raw: String?) -> String? {
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
