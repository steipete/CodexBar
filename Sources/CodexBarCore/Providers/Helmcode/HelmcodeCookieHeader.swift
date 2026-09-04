import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HelmcodeCookieOverride: Sendable {
    public let cookieHeader: String

    public init(cookieHeader: String) {
        self.cookieHeader = cookieHeader
    }
}

public enum HelmcodeCookieHeader {
    public static func resolveCookieOverride(context: ProviderFetchContext) -> HelmcodeCookieOverride? {
        if context.settings?.helmcode?.cookieSource == .off {
            return nil
        }

        if let settings = context.settings?.helmcode,
           settings.cookieSource == .manual,
           let header = CookieHeaderNormalizer.normalize(settings.manualCookieHeader)
        {
            return HelmcodeCookieOverride(cookieHeader: header)
        }

        guard let header = HelmcodeSettingsReader.cookieHeader(environment: context.env) else {
            return nil
        }
        return HelmcodeCookieOverride(cookieHeader: header)
    }

    static func header(from cookies: [HTTPCookie], for url: URL, now: Date = Date()) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        let requestPath = url.path.isEmpty ? "/" : url.path
        let isHTTPS = url.scheme?.lowercased() == "https"

        let matching = cookies.filter { cookie in
            guard cookie.expiresDate.map({ $0 > now }) ?? true else { return false }
            guard !cookie.isSecure || isHTTPS else { return false }
            guard self.domain(cookie.domain, matches: host) else { return false }
            return self.path(cookie.path, matches: requestPath)
        }.sorted { lhs, rhs in
            if lhs.path.count != rhs.path.count {
                return lhs.path.count > rhs.path.count
            }
            if lhs.name != rhs.name {
                return lhs.name < rhs.name
            }
            return lhs.domain < rhs.domain
        }

        guard !matching.isEmpty else { return nil }
        return matching.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    private static func domain(_ cookieDomain: String, matches host: String) -> Bool {
        let normalized = cookieDomain.lowercased()
        if normalized.hasPrefix(".") {
            let base = String(normalized.dropFirst())
            return host == base || host.hasSuffix("." + base)
        }
        return host == normalized
    }

    private static func path(_ cookiePath: String, matches requestPath: String) -> Bool {
        let normalized = cookiePath.isEmpty ? "/" : cookiePath
        guard requestPath.hasPrefix(normalized) else { return false }
        if requestPath.count == normalized.count || normalized.hasSuffix("/") {
            return true
        }
        let boundary = requestPath.index(requestPath.startIndex, offsetBy: normalized.count)
        return requestPath[boundary] == "/"
    }
}
