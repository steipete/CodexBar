import Foundation

public enum SakanaSettingsReader {
    public static let cookieHeaderKey = "SAKANA_COOKIE"

    public static func cookieHeader(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        CookieHeaderNormalizer.normalize(self.cleaned(environment[self.cookieHeaderKey]))
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
}
