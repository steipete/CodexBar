import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One cookie of a persisted Helmcode dashboard session. `domain` is stored in HTTPCookie form
/// (leading dot for domain-scoped cookies), so rebuilding the cookie preserves the browser's scope
/// and `HelmcodeCookieHeader.header(from:for:now:)` re-applies domain, path, secure, and expiry
/// checks per request.
public struct HelmcodeCachedCookie: Codable, Equatable, Sendable {
    public let name: String
    public let value: String
    public let domain: String
    public let path: String
    public let expires: Date?
    public let isSecure: Bool
    public let isHTTPOnly: Bool

    public init(
        name: String,
        value: String,
        domain: String,
        path: String,
        expires: Date?,
        isSecure: Bool,
        isHTTPOnly: Bool)
    {
        self.name = name
        self.value = value
        self.domain = domain
        self.path = path
        self.expires = expires
        self.isSecure = isSecure
        self.isHTTPOnly = isHTTPOnly
    }

    public init(cookie: HTTPCookie) {
        self.init(
            name: cookie.name,
            value: cookie.value ?? "",
            domain: cookie.domain,
            path: cookie.path,
            expires: cookie.expiresDate,
            isSecure: cookie.isSecure,
            isHTTPOnly: cookie.isHTTPOnly)
    }

    public func makeHTTPCookie() -> HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .domain: self.domain,
            .path: self.path,
            .name: self.name,
            .value: self.value,
            .secure: self.isSecure,
        ]
        if let originURL =
            URL(string: "https://\(self.domain.hasPrefix(".") ? String(self.domain.dropFirst()) : self.domain)")
        {
            properties[.originURL] = originURL
        }
        if self.isHTTPOnly {
            properties[.init("HttpOnly")] = "TRUE"
        }
        if let expires = self.expires {
            properties[.expires] = expires
        }
        return HTTPCookie(properties: properties)
    }
}

/// A persisted Helmcode dashboard session as cookie records. Cached sessions keep path and expiry
/// metadata so a replayed session is re-filtered per endpoint (a cookie scoped to `/api/usage` never
/// reaches billing, an expired cookie is dropped) instead of replaying one flat header everywhere.
public struct HelmcodeCachedSession: Codable, Equatable, Sendable {
    public let cookies: [HelmcodeCachedCookie]

    public init(cookies: [HelmcodeCachedCookie]) {
        self.cookies = cookies
    }

    /// Encoded for the `CookieHeaderCache` entry's `cookieHeader` field (same convention as
    /// ZoomMate's `encodedForStorage()`), so the existing cache infrastructure needs no changes.
    public func encodedForStorage() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(bytes: data, encoding: .utf8)
    }

    /// Decodes a persisted session. A legacy cache entry holds a flat `Cookie:` header string, which
    /// is not valid session JSON here — decoding fails and the caller treats it as a cache miss.
    public static func decode(_ stored: String) -> HelmcodeCachedSession? {
        guard let data = stored.data(using: .utf8),
              let session = try? JSONDecoder().decode(HelmcodeCachedSession.self, from: data),
              !session.cookies.isEmpty
        else { return nil }
        return session
    }

    /// Builds records from imported cookies that match the selected deployment's cookie domains,
    /// so a tenant's cache only ever holds cookies that belong to that tenant.
    public static func records(
        from cookies: [HTTPCookie],
        deployment: HelmcodeDeployment) -> HelmcodeCachedSession?
    {
        let domains = deployment.cookieDomains.map { $0.lowercased() }
        var records: [HelmcodeCachedCookie] = []
        for cookie in cookies {
            let host = cookie.domain.lowercased()
            let base = host.hasPrefix(".") ? String(host.dropFirst()) : host
            guard domains.contains(where: { base == $0 || base.hasSuffix("." + $0) }) else { continue }
            records.append(HelmcodeCachedCookie(cookie: cookie))
        }
        guard !records.isEmpty else { return nil }
        return HelmcodeCachedSession(cookies: records)
    }

    /// Rebuilds cookies for `fetchUsage(cookies:)`, including expired ones: the per-request header
    /// builder excludes and reports them by name, so the verbose boundary trace shows the exclusion.
    public func makeHTTPCookies() -> [HTTPCookie] {
        self.cookies.compactMap { $0.makeHTTPCookie() }
    }
}
