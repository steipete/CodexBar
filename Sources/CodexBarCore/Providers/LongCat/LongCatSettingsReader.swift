import Foundation

public enum LongCatSettingsReader {
    public static let cookieHeaderKey = "LONGCAT_MANUAL_COOKIE"

    /// Manual cookie header for the LongCat web console (longcat.chat).
    public static func cookieHeader(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let raw = environment[self.cookieHeaderKey] ?? environment["longcat_manual_cookie"]
        return SettingsValue.cleaned(raw)
    }

    /// LongCat OpenAI/Anthropic-compatible API key. Not used for usage (the public
    /// API exposes no usage endpoint) but kept for parity and future signals.
    public static func apiKey(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let raw = environment["LONGCAT_API_KEY"] ?? environment["longcat_api_key"]
        return SettingsValue.cleaned(raw)
    }
}
