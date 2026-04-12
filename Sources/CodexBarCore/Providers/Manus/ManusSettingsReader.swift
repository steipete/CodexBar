import Foundation

public enum ManusSettingsReader {
    public static func sessionToken(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let rawToken = environment["MANUS_SESSION_TOKEN"]
            ?? environment["manus_session_token"]
            ?? environment["MANUS_SESSION_ID"]
            ?? environment["manus_session_id"]
        if let token = ManusCookieHeader.token(from: self.cleaned(rawToken)) {
            return token
        }

        let rawCookie = environment["MANUS_COOKIE"] ?? environment["manus_cookie"]
        return ManusCookieHeader.token(from: self.cleaned(rawCookie))
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
