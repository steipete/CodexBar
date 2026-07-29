import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Qwen Cloud cookie-header pair.
///
/// Wraps the shared `OneConsoleCookieHeaders` so the rest of the codebase
/// keeps referring to `QwenCloudCookieHeaders`. The cached-header round-trip
/// uses a namespace unique to Qwen Cloud so it can never collide with
/// Alibaba Token Plan or another provider's cached entry.
public typealias QwenCloudCookieHeaders = OneConsoleCookieHeaders

extension OneConsoleCookieHeaders {
    static let qwenCloudCacheNamespace = "qwen_cloud"

    public init?(qwenCloudCachedHeader raw: String?) {
        if let headers = OneConsoleCookieHeaders(cachedHeader: raw, cacheNamespace: Self.qwenCloudCacheNamespace) {
            self = headers
        } else if let headers = OneConsoleCookieHeaders(singleHeader: raw) {
            self = headers
        } else {
            return nil
        }
    }

    public func cacheQwenCloudCookieHeader() -> String {
        self.cacheCookieHeader(namespace: Self.qwenCloudCacheNamespace)
    }
}

enum QwenCloudCookieHeader {
    static let cacheNamespace = OneConsoleCookieHeaders.qwenCloudCacheNamespace

    static func headers(
        from cookies: [HTTPCookie],
        environment: [String: String] = ProcessInfo.processInfo.environment) -> QwenCloudCookieHeaders?
    {
        guard let apiHeader = OneConsoleCookieHeaderBuilder.header(
            from: cookies,
            targetURL: QwenCloudUsageFetcher.resolveQuotaURL(environment: environment)),
            let dashboardHeader = OneConsoleCookieHeaderBuilder.header(
                from: cookies,
                targetURL: QwenCloudUsageFetcher.dashboardURL(environment: environment))
        else {
            return nil
        }
        return QwenCloudCookieHeaders(apiCookieHeader: apiHeader, dashboardCookieHeader: dashboardHeader)
    }

    static func header(from cookies: [HTTPCookie], targetURL: URL) -> String? {
        OneConsoleCookieHeaderBuilder.header(from: cookies, targetURL: targetURL)
    }
}
