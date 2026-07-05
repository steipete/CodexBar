import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct DeepSeekPlatformSession: Sendable, Equatable {
    public let cookieHeader: String?
    public let authorizationHeader: String?

    public init(cookieHeader: String?, authorizationHeader: String?) {
        self.cookieHeader = cookieHeader?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.authorizationHeader = authorizationHeader?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isEmpty: Bool {
        guard let cookieHeader, !cookieHeader.isEmpty else {
            return self.authorizationHeader?.isEmpty ?? true
        }
        return false
    }

    /// Serialized DevTools-style payload for settings/cache (`Authorization` + `Cookie` lines).
    var storagePayload: String {
        var lines: [String] = []
        if let authorizationHeader = self.authorizationHeader, !authorizationHeader.isEmpty {
            if authorizationHeader.lowercased().hasPrefix("bearer ") {
                lines.append("Authorization: \(authorizationHeader)")
            } else {
                lines.append("Authorization: Bearer \(authorizationHeader)")
            }
        }
        if let cookieHeader = self.cookieHeader, !cookieHeader.isEmpty {
            lines.append("Cookie: \(cookieHeader)")
        }
        return lines.joined(separator: "\n")
    }
}

enum DeepSeekCookieHeader {
    static let knownCookieNames: Set<String> = [
        "ds_session_id",
        "intercom-session-guh50jw4",
        "intercom-device-id-guh50jw4",
    ]

    static func session(from raw: String?) -> DeepSeekPlatformSession? {
        // Multi-line DevTools paste (e.g. "Authorization: …\nCookie: …"): parse the raw
        // lines directly, because cookie-focused normalization would drop the
        // Authorization header before we ever see it.
        if let raw {
            let lines = raw.split(whereSeparator: \.isNewline)
            if lines.count > 1, let session = self.multilineSession(from: lines) {
                return session
            }
        }

        guard let normalized = CookieHeaderNormalizer.normalize(raw) else { return nil }
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.lowercased().hasPrefix("bearer ") {
            return DeepSeekPlatformSession(cookieHeader: nil, authorizationHeader: trimmed)
        }

        var cookieParts: [String] = []
        var authorizationHeader: String?
        for line in trimmed.split(whereSeparator: \.isNewline) {
            let piece = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty else { continue }
            if piece.lowercased().hasPrefix("authorization:") {
                let value = piece.dropFirst("authorization:".count)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty {
                    authorizationHeader = value
                }
                continue
            }
            if piece.lowercased().hasPrefix("cookie:") {
                let value = piece.dropFirst("cookie:".count)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty {
                    cookieParts.append(value)
                }
                continue
            }
            if piece.lowercased().hasPrefix("bearer ") {
                authorizationHeader = piece
                continue
            }
            cookieParts.append(piece)
        }

        let cookieHeader = cookieParts.joined(separator: "; ")
        let session = DeepSeekPlatformSession(
            cookieHeader: cookieHeader.isEmpty ? nil : cookieHeader,
            authorizationHeader: authorizationHeader)
        return session.isEmpty ? nil : session
    }

    private static func multilineSession(
        from lines: [Substring]) -> DeepSeekPlatformSession?
    {
        var cookieParts: [String] = []
        var authorizationHeader: String?
        for line in lines {
            let piece = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty else { continue }
            let lower = piece.lowercased()
            if lower.hasPrefix("authorization:") {
                let value = piece.dropFirst("authorization:".count)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { authorizationHeader = value }
            } else if lower.hasPrefix("bearer ") {
                authorizationHeader = piece
            } else if lower.hasPrefix("cookie:") {
                let value = piece.dropFirst("cookie:".count)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { cookieParts.append(value) }
            } else {
                cookieParts.append(piece)
            }
        }
        let cookieHeader = cookieParts.joined(separator: "; ")
        let session = DeepSeekPlatformSession(
            cookieHeader: cookieHeader.isEmpty ? nil : cookieHeader,
            authorizationHeader: authorizationHeader)
        return session.isEmpty ? nil : session
    }

    static func header(from cookies: [HTTPCookie]) -> String? {
        let requestURL = URL(string: "https://platform.deepseek.com/api/v0/users/get_user_summary")!
        var byName: [String: HTTPCookie] = [:]
        for cookie in cookies {
            guard !cookie.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            if let expiry = cookie.expiresDate, expiry < Date() { continue }
            guard Self.matchesRequestURL(cookie: cookie, url: requestURL) else { continue }

            if let existing = byName[cookie.name] {
                if Self.cookieSortKey(for: cookie) >= Self.cookieSortKey(for: existing) {
                    byName[cookie.name] = cookie
                }
            } else {
                byName[cookie.name] = cookie
            }
        }

        guard byName.keys.contains(where: { Self.knownCookieNames.contains($0) }) else {
            // WAF-only cookies (HWWAF*) are not a platform login session.
            return nil
        }
        return byName.keys.sorted().compactMap { name in
            guard let cookie = byName[name] else { return nil }
            return "\(cookie.name)=\(cookie.value)"
        }.joined(separator: "; ")
    }

    /// Includes WAF and platform cookies when a bearer token is present but `ds_session_id` is absent.
    static func supplementalHeader(from cookies: [HTTPCookie]) -> String? {
        let requestURL = URL(string: "https://platform.deepseek.com/api/v0/users/get_user_summary")!
        var byName: [String: HTTPCookie] = [:]
        for cookie in cookies {
            guard !cookie.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            if let expiry = cookie.expiresDate, expiry < Date() { continue }
            guard Self.matchesRequestURL(cookie: cookie, url: requestURL) else { continue }
            if cookie.name.hasPrefix(".thumbcache") { continue }
            byName[cookie.name] = cookie
        }
        guard !byName.isEmpty else { return nil }
        return byName.keys.sorted().compactMap { name in
            guard let cookie = byName[name] else { return nil }
            return "\(cookie.name)=\(cookie.value)"
        }.joined(separator: "; ")
    }

    static func isAuthFailurePayload(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        if Self.isAuthFailureCode(object["code"]) {
            return true
        }
        if let dataObject = object["data"] as? [String: Any],
           Self.isAuthFailureCode(dataObject["biz_code"])
        {
            return true
        }
        let message = (object["msg"] as? String ?? "").lowercased()
        return message.contains("authorization failed") || message.contains("missing token")
    }

    private static func isAuthFailureCode(_ value: Any?) -> Bool {
        guard let code = value as? Int else { return false }
        return code == 40002 || code == 40003
    }

    private static func matchesRequestURL(cookie: HTTPCookie, url: URL) -> Bool {
        guard let host = url.host else { return false }
        let normalizedDomain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !normalizedDomain.isEmpty else { return false }
        if host == normalizedDomain || host.hasSuffix(".\(normalizedDomain)") {
            return true
        }
        // Auth cookies are often issued on chat.deepseek.com but are valid for platform APIs.
        if Self.knownCookieNames.contains(cookie.name), Self.isDeepSeekDomain(normalizedDomain) {
            return true
        }
        return false
    }

    private static func isDeepSeekDomain(_ normalizedDomain: String) -> Bool {
        normalizedDomain == "deepseek.com" || normalizedDomain.hasSuffix(".deepseek.com")
    }

    private static func cookieSortKey(for cookie: HTTPCookie) -> (Int, Int, Date) {
        let pathLength = cookie.path.count
        let normalizedDomain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let domainLength = normalizedDomain.count
        let expiry = cookie.expiresDate ?? .distantPast
        return (pathLength, domainLength, expiry)
    }
}
