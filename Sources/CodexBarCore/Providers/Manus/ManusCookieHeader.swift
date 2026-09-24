import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum ManusCookieHeader {
    public static let sessionCookieName = "session_id"

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
}
