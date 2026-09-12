import Foundation

public enum PerplexitySettingsReader {
    public static func sessionCookieOverride(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> PerplexityCookieOverride?
    {
        let raw = environment["PERPLEXITY_SESSION_TOKEN"]
            ?? environment["perplexity_session_token"]
        if let token = SettingsValue.cleaned(raw) { return PerplexityCookieHeader.override(from: token) }

        // PERPLEXITY_COOKIE may be a full Cookie header string; preserve the matching session cookie name.
        if let cookieRaw = environment["PERPLEXITY_COOKIE"] {
            return PerplexityCookieHeader.override(from: SettingsValue.cleaned(cookieRaw))
        }
        return nil
    }

    public static func sessionToken(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        self.sessionCookieOverride(environment: environment)?.token
    }
}
