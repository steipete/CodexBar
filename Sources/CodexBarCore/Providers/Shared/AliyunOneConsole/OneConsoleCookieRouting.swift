import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Redirect policy for Aliyun OneConsole sessions with distinct dashboard and API cookie scopes.
///
/// Trusted dashboard/API redirects receive the matching cookie header. Cross-origin
/// redirects are followed only as credential-free GET/HEAD navigations; body-bearing
/// redirects are rejected so a 307/308 cannot forward `sec_token` or request parameters.
public struct OneConsoleCookieRouting: Sendable {
    private static let redirectStatusCodes: Set<Int> = [301, 302, 303, 307, 308]

    public let apiURL: URL
    public let dashboardURL: URL
    public let apiCookieHeader: String
    public let dashboardCookieHeader: String

    public init(
        apiURL: URL,
        dashboardURL: URL,
        apiCookieHeader: String,
        dashboardCookieHeader: String)
    {
        self.apiURL = apiURL
        self.dashboardURL = dashboardURL
        self.apiCookieHeader = apiCookieHeader
        self.dashboardCookieHeader = dashboardCookieHeader
    }

    public func redirectedRequest(
        forRedirectFrom original: URLRequest,
        response: HTTPURLResponse,
        to redirected: URLRequest) -> URLRequest?
    {
        guard Self.redirectStatusCodes.contains(response.statusCode) else { return nil }
        guard let originalURL = original.url,
              originalURL.scheme?.caseInsensitiveCompare("https") == .orderedSame,
              originalURL.user == nil,
              originalURL.password == nil
        else {
            return nil
        }
        let sourceURL = response.url ?? originalURL
        guard sourceURL.scheme?.caseInsensitiveCompare("https") == .orderedSame,
              sourceURL.user == nil,
              sourceURL.password == nil
        else {
            return nil
        }
        guard let redirectedURL = redirected.url,
              redirectedURL.scheme?.caseInsensitiveCompare("https") == .orderedSame,
              redirectedURL.host != nil,
              redirectedURL.user == nil,
              redirectedURL.password == nil
        else {
            return nil
        }

        let isCrossOrigin = !Self.isSameOrigin(sourceURL, redirectedURL)
        if isCrossOrigin, !Self.isCredentialFreeNavigation(redirected) {
            return nil
        }

        let acceptsHTML = original.value(forHTTPHeaderField: "Accept")?.contains("text/html") == true
        var routed: URLRequest
        if isCrossOrigin {
            guard let sanitized = Self.sanitizedNavigation(from: redirected) else { return nil }
            routed = sanitized
        } else {
            routed = redirected
        }
        if Self.isSameOrigin(redirectedURL, self.apiURL),
           redirectedURL.path == self.apiURL.path,
           !acceptsHTML
        {
            routed.setValue(self.apiCookieHeader, forHTTPHeaderField: "Cookie")
            return routed
        }
        if Self.isSameOrigin(redirectedURL, self.dashboardURL) {
            routed.setValue(self.dashboardCookieHeader, forHTTPHeaderField: "Cookie")
            return routed
        }

        return Self.sanitizedNavigation(from: routed)
    }

    private static func isCredentialFreeNavigation(_ request: URLRequest) -> Bool {
        let method = request.httpMethod?.uppercased() ?? "GET"
        guard method == "GET" || method == "HEAD" else { return false }
        return request.httpBody == nil && request.httpBodyStream == nil
    }

    private static func sanitizedNavigation(from request: URLRequest) -> URLRequest? {
        guard let url = request.url, self.isCredentialFreeNavigation(request) else { return nil }
        var sanitized = URLRequest(
            url: url,
            cachePolicy: request.cachePolicy,
            timeoutInterval: request.timeoutInterval)
        sanitized.httpMethod = request.httpMethod?.uppercased() ?? "GET"
        for header in ["Accept", "Accept-Language", "User-Agent"] {
            if let value = request.value(forHTTPHeaderField: header) {
                sanitized.setValue(value, forHTTPHeaderField: header)
            }
        }
        return sanitized
    }

    private static func isSameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased() &&
            lhs.host?.lowercased() == rhs.host?.lowercased() &&
            self.normalizedPort(lhs) == self.normalizedPort(rhs)
    }

    private static func normalizedPort(_ url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }
}
