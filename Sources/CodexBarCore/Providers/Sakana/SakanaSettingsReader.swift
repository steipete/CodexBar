import Foundation

public enum SakanaSettingsReader {
    public static let cookieHeaderKey = "SAKANA_COOKIE"

    public static func cookieHeader(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        CookieHeaderNormalizer.normalize(SettingsValue.cleaned(environment[self.cookieHeaderKey]))
    }
}
