import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum ManusCookieHeader {
    public static let sessionCookieName = "session_id"

    public static func resolveToken(context: ProviderFetchContext) -> String? {
        guard let settings = context.settings?.manus, settings.cookieSource == .manual else { return nil }
        return self.token(from: settings.manualCookieHeader)
    }

    public static func token(from raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }

        if !raw.contains("="), !raw.contains(";") {
            return raw
        }

        let pairs = CookieHeaderNormalizer.pairs(from: raw)
        for pair in pairs where pair.name.caseInsensitiveCompare(self.sessionCookieName) == .orderedSame {
            let token = pair.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty {
                return token
            }
        }
        return nil
    }

    public static func sessionToken(from cookies: [HTTPCookie]) -> String? {
        for cookie in cookies where cookie.name.caseInsensitiveCompare(self.sessionCookieName) == .orderedSame {
            let token = cookie.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty {
                return token
            }
        }
        return nil
    }
}
