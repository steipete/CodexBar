import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Generic cookie-header pair for Aliyun OneConsole-based providers.
///
/// Each provider keeps one HTTPCookie jar but may need to send a slightly
/// different Cookie header on dashboard GETs versus API POSTs (different
/// host scopes, different CSRF / sec_token presence). This struct holds
/// both headers together and handles the cached-header round-trip so
/// providers don't reinvent that plumbing.
public struct OneConsoleCookieHeaders: Sendable {
    public let apiCookieHeader: String
    public let dashboardCookieHeader: String

    public init(apiCookieHeader: String, dashboardCookieHeader: String) {
        self.apiCookieHeader = apiCookieHeader
        self.dashboardCookieHeader = dashboardCookieHeader
    }

    public init?(singleHeader raw: String?) {
        guard let normalized = CookieHeaderNormalizer.normalize(raw) else { return nil }
        self.apiCookieHeader = normalized
        self.dashboardCookieHeader = normalized
    }

    public init?(cachedHeader raw: String?, cacheNamespace: String) {
        var valuesByName: [String: String] = [:]
        for pair in CookieHeaderNormalizer.pairs(from: raw ?? "") {
            valuesByName[pair.name] = pair.value
        }
        if let encodedAPI = valuesByName["__codexbar_\(cacheNamespace)_api"],
           let encodedDashboard = valuesByName["__codexbar_\(cacheNamespace)_dashboard"],
           let apiHeader = Self.decodeCachedHeader(encodedAPI),
           let dashboardHeader = Self.decodeCachedHeader(encodedDashboard),
           let normalizedAPI = CookieHeaderNormalizer.normalize(apiHeader),
           let normalizedDashboard = CookieHeaderNormalizer.normalize(dashboardHeader)
        {
            self.init(apiCookieHeader: normalizedAPI, dashboardCookieHeader: normalizedDashboard)
            return
        }

        self.init(singleHeader: raw)
    }

    public func cacheCookieHeader(namespace: String) -> String {
        [
            "__codexbar_\(namespace)_api=\(Self.encodeCachedHeader(self.apiCookieHeader))",
            "__codexbar_\(namespace)_dashboard=\(Self.encodeCachedHeader(self.dashboardCookieHeader))",
        ].joined(separator: "; ")
    }

    public var apiCookieNames: [String] {
        Self.cookieNames(from: self.apiCookieHeader)
    }

    public var dashboardCookieNames: [String] {
        Self.cookieNames(from: self.dashboardCookieHeader)
    }

    public func hasCookie(named name: String) -> Bool {
        Self.cookieNames(from: self.apiCookieHeader).contains(name) ||
            Self.cookieNames(from: self.dashboardCookieHeader).contains(name)
    }

    private static func cookieNames(from header: String) -> [String] {
        CookieHeaderNormalizer.pairs(from: header)
            .map(\.name)
            .filter { !$0.isEmpty }
            .uniquedSorted()
    }

    private static func encodeCachedHeader(_ header: String) -> String {
        Data(header.utf8).base64EncodedString()
    }

    private static func decodeCachedHeader(_ encoded: String) -> String? {
        guard let data = Data(base64Encoded: encoded) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Builds a Cookie header from an [HTTPCookie] jar scoped to a target URL.
public enum OneConsoleCookieHeaderBuilder {
    /// Returns a single Cookie header string that includes every cookie in
    /// `cookies` whose domain and path match `targetURL`, choosing the most
    /// specific cookie (longest path, longest domain, latest expiry) when
    /// duplicates exist.
    public static func header(from cookies: [HTTPCookie], targetURL: URL) -> String? {
        var byName: [String: HTTPCookie] = [:]
        for cookie in cookies {
            guard !cookie.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            guard !cookie.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            if let expiry = cookie.expiresDate, expiry < Date() { continue }
            guard Self.matchesRequestURL(cookie: cookie, url: targetURL) else { continue }

            if let existing = byName[cookie.name] {
                if Self.cookieSortKey(for: cookie) >= Self.cookieSortKey(for: existing) {
                    byName[cookie.name] = cookie
                }
            } else {
                byName[cookie.name] = cookie
            }
        }

        guard !byName.isEmpty else { return nil }
        return byName.keys.sorted().compactMap { name in
            guard let cookie = byName[name] else { return nil }
            return "\(cookie.name)=\(cookie.value)"
        }.joined(separator: "; ")
    }

    private static func matchesRequestURL(cookie: HTTPCookie, url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let normalizedDomain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !normalizedDomain.isEmpty else { return false }
        guard host == normalizedDomain || host.hasSuffix(".\(normalizedDomain)") else { return false }

        let cookiePath = cookie.path.isEmpty ? "/" : cookie.path
        let requestPath = url.path.isEmpty ? "/" : url.path
        if requestPath == cookiePath {
            return true
        }
        guard requestPath.hasPrefix(cookiePath) else { return false }
        guard cookiePath != "/" else { return true }
        if cookiePath.hasSuffix("/") {
            return true
        }
        guard
            let boundaryIndex = requestPath.index(
                requestPath.startIndex,
                offsetBy: cookiePath.count,
                limitedBy: requestPath.endIndex),
            boundaryIndex < requestPath.endIndex
        else {
            return true
        }
        return requestPath[boundaryIndex] == "/"
    }

    private static func cookieSortKey(for cookie: HTTPCookie) -> (Int, Int, Date) {
        let pathLength = cookie.path.count
        let normalizedDomain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let domainLength = normalizedDomain.count
        let expiry = cookie.expiresDate ?? .distantPast
        return (pathLength, domainLength, expiry)
    }
}

extension [String] {
    func uniquedSorted() -> [String] {
        Array(Set(self)).sorted()
    }
}
