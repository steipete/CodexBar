import Foundation

public enum LongCatSettingsReader {
    /// Manual cookie header for the LongCat web console (longcat.chat).
    public static func cookieHeader(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let raw = environment["LONGCAT_MANUAL_COOKIE"] ?? environment["longcat_manual_cookie"]
        return self.cleaned(raw)
    }

    /// LongCat OpenAI/Anthropic-compatible API key. Not used for usage (the public
    /// API exposes no usage endpoint) but kept for parity and future signals.
    public static func apiKey(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let raw = environment["LONGCAT_API_KEY"] ?? environment["longcat_api_key"]
        return self.cleaned(raw)
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
