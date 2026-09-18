import Foundation

public enum ManusSettingsReader {
    public static func sessionToken(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let rawToken = environment["MANUS_SESSION_TOKEN"]
            ?? environment["manus_session_token"]
            ?? environment["MANUS_SESSION_ID"]
            ?? environment["manus_session_id"]
        if let token = ManusCookieHeader.token(from: SettingsValue.cleaned(rawToken)) {
            return token
        }

        let rawCookie = environment["MANUS_COOKIE"] ?? environment["manus_cookie"]
        return ManusCookieHeader.token(from: SettingsValue.cleaned(rawCookie))
    }
}
