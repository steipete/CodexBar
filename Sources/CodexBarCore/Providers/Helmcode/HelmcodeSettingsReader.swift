import Foundation

public enum HelmcodeSettingsReader {
    public static let cookieHeaderEnvironmentKey = "HELMCODE_COOKIE"

    public static func cookieHeader(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        let raw = environment[self.cookieHeaderEnvironmentKey] ?? environment["helmcode_cookie"]
        return CookieHeaderNormalizer.normalize(raw)
    }
}
