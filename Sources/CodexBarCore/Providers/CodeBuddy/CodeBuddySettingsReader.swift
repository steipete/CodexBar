import Foundation

public enum CodeBuddySettingsReader {
    public static func cookieHeader(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let raw = environment["CODEBUDDY_COOKIE"] ?? environment["codebuddy_cookie"]
        return self.cleaned(raw)
    }

    public static func enterpriseID(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let raw = environment["CODEBUDDY_ENTERPRISE_ID"] ?? environment["codebuddy_enterprise_id"]
        return self.cleaned(raw)
    }

    private static func cleaned(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Handle quoted strings
        if (cleaned.hasPrefix("\"") && cleaned.hasSuffix("\"")) ||
            (cleaned.hasPrefix("'") && cleaned.hasSuffix("'"))
        {
            cleaned = String(cleaned.dropFirst().dropLast())
        }
        return cleaned.isEmpty ? nil : cleaned
    }
}
