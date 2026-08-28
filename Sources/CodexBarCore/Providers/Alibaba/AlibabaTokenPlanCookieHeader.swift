import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Alibaba Token Plan cookie-header pair.
///
/// Wraps the shared `OneConsoleCookieHeaders` so the rest of the codebase
/// keeps referring to `AlibabaTokenPlanCookieHeaders`. The cached-header
/// round-trip uses a namespace unique to Alibaba Token Plan so it can never
/// collide with Qwen Cloud or another provider's cached entry.
public typealias AlibabaTokenPlanCookieHeaders = OneConsoleCookieHeaders

extension OneConsoleCookieHeaders {
    static let alibabaTokenPlanCacheNamespace = "alibaba_token_plan"
}

extension OneConsoleCookieHeaders {
    public init?(alibabaTokenPlanCachedHeader raw: String?) {
        if let headers = OneConsoleCookieHeaders(
            cachedHeader: raw,
            cacheNamespace: Self.alibabaTokenPlanCacheNamespace)
        {
            self = headers
        } else if let headers = OneConsoleCookieHeaders(singleHeader: raw) {
            self = headers
        } else {
            return nil
        }
    }

    public func cacheAlibabaTokenPlanCookieHeader() -> String {
        self.cacheCookieHeader(namespace: Self.alibabaTokenPlanCacheNamespace)
    }
}

enum AlibabaTokenPlanCookieHeader {
    static let cacheNamespace = OneConsoleCookieHeaders.alibabaTokenPlanCacheNamespace

    static func headers(
        from cookies: [HTTPCookie],
        region: AlibabaTokenPlanAPIRegion = .international,
        environment: [String: String] = ProcessInfo.processInfo.environment) -> AlibabaTokenPlanCookieHeaders?
    {
        guard let apiHeader = OneConsoleCookieHeaderBuilder.header(
            from: cookies,
            targetURL: AlibabaTokenPlanUsageFetcher.resolveQuotaURL(region: region, environment: environment)),
            let dashboardHeader = OneConsoleCookieHeaderBuilder.header(
                from: cookies,
                targetURL: AlibabaTokenPlanUsageFetcher.dashboardURL(region: region, environment: environment))
        else {
            return nil
        }
        return AlibabaTokenPlanCookieHeaders(apiCookieHeader: apiHeader, dashboardCookieHeader: dashboardHeader)
    }

    static func header(from cookies: [HTTPCookie], targetURL: URL) -> String? {
        OneConsoleCookieHeaderBuilder.header(from: cookies, targetURL: targetURL)
    }
}
