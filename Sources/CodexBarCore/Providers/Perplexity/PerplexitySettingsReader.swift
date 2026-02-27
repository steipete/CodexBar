import Foundation

public enum PerplexitySettingsReader {
    public static func sessionToken(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        let raw = environment["PERPLEXITY_SESSION_TOKEN"]
            ?? environment["perplexity_session_token"]
        if let token = self.cleaned(raw) { return token }

        // PERPLEXITY_COOKIE may be a full Cookie header string; extract the session token from it.
        if let cookieRaw = environment["PERPLEXITY_COOKIE"] {
            return PerplexityCookieHeader.override(from: self.cleaned(cookieRaw))?.token
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
            value.removeFirst()
            value.removeLast()
        }

        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
