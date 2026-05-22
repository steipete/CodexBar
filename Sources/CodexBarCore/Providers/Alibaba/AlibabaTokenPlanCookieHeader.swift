import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct AlibabaTokenPlanCookieHeaders: Sendable {
    private static let cachedAPIHeaderName = "__codexbar_alibaba_token_plan_api"
    private static let cachedDashboardHeaderName = "__codexbar_alibaba_token_plan_dashboard"

    let apiCookieHeader: String
    let dashboardCookieHeader: String

    init(apiCookieHeader: String, dashboardCookieHeader: String) {
        self.apiCookieHeader = apiCookieHeader
        self.dashboardCookieHeader = dashboardCookieHeader
    }

    init?(singleHeader raw: String?) {
        guard let normalized = CookieHeaderNormalizer.normalize(raw) else { return nil }
        self.apiCookieHeader = normalized
        self.dashboardCookieHeader = normalized
    }

    init?(cachedHeader raw: String?) {
        var valuesByName: [String: String] = [:]
        for pair in CookieHeaderNormalizer.pairs(from: raw ?? "") {
            valuesByName[pair.name] = pair.value
        }
        if let encodedAPI = valuesByName[Self.cachedAPIHeaderName],
           let encodedDashboard = valuesByName[Self.cachedDashboardHeaderName],
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

    var cacheCookieHeader: String {
        [
            "\(Self.cachedAPIHeaderName)=\(Self.encodeCachedHeader(self.apiCookieHeader))",
            "\(Self.cachedDashboardHeaderName)=\(Self.encodeCachedHeader(self.dashboardCookieHeader))",
        ].joined(separator: "; ")
    }

    var apiCookieNames: [String] {
        Self.cookieNames(from: self.apiCookieHeader)
    }

    var dashboardCookieNames: [String] {
        Self.cookieNames(from: self.dashboardCookieHeader)
    }

    func hasCookie(named name: String) -> Bool {
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

enum AlibabaTokenPlanCookieHeader {
    static func headers(
        from cookies: [HTTPCookie],
        environment: [String: String] = ProcessInfo.processInfo.environment) -> AlibabaTokenPlanCookieHeaders?
    {
        guard let apiHeader = self.header(
            from: cookies,
            targetURL: AlibabaTokenPlanUsageFetcher.resolveQuotaURL(environment: environment)),
            let dashboardHeader = self.header(
                from: cookies,
                targetURL: AlibabaTokenPlanUsageFetcher.dashboardURL(environment: environment))
        else {
            return nil
        }
        return AlibabaTokenPlanCookieHeaders(apiCookieHeader: apiHeader, dashboardCookieHeader: dashboardHeader)
    }

    static func header(from cookies: [HTTPCookie], targetURL: URL) -> String? {
        var byName: [String: HTTPCookie] = [:]
        for cookie in cookies {
            guard !cookie.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            guard !cookie.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            if let expiry = cookie.expiresDate, expiry < Date() { continue }
            guard self.matchesRequestURL(cookie: cookie, url: targetURL) else { continue }

            if let existing = byName[cookie.name] {
                if self.cookieSortKey(for: cookie) >= self.cookieSortKey(for: existing) {
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
    fileprivate func uniquedSorted() -> [String] {
        Array(Set(self)).sorted()
    }
}
