import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum MiniMaxWebSessionDomain: String, CaseIterable, Hashable, Sendable {
    case global
    case chinaMainland
    case legacyChina

    static func candidates(for region: MiniMaxAPIRegion) -> [Self] {
        region == .chinaMainland ? [.chinaMainland, .legacyChina] : [.global]
    }

    var rootDomain: String {
        switch self {
        case .global: "minimax.io"
        case .chinaMainland: "minimax.cn"
        case .legacyChina: "minimaxi.com"
        }
    }

    var storageOrigins: [String] {
        ["https://platform.\(self.rootDomain)", "https://www.\(self.rootDomain)", "https://\(self.rootDomain)"]
    }

    var cacheScope: CookieHeaderCache.Scope {
        // Older headers lost domain/path attributes and cannot be safely migrated.
        .providerVariant("minimax.web-session.v2.\(self.rawValue)")
    }

    var quotaURL: URL {
        switch self {
        case .global: MiniMaxAPIRegion.global.remainsURL
        case .chinaMainland: URL(string: "https://www.minimax.cn/backend/account/token_plan/remains_percent")!
        case .legacyChina: MiniMaxAPIRegion.chinaMainland.remainsURL
        }
    }

    func cookieURLs(for region: MiniMaxAPIRegion, environment: [String: String]) -> [URL] {
        // Custom HTTPS proxies use the corresponding provider origin, never cookies imported from the proxy.
        let environment = self.environment(environment)
        let requests = MiniMaxUsageFetcher.resolveRemainsURLs(region: region, environment: environment) + [
            MiniMaxUsageFetcher.resolveCodingPlanURL(region: region, environment: environment),
        ]
        return requests.compactMap { self.cookieURL(for: $0, region: region, environment: environment) }
    }

    func cookieURL(for request: URL, region: MiniMaxAPIRegion, environment: [String: String]) -> URL? {
        guard request.scheme?.lowercased() == "https" else { return nil }
        let host = request.host?.lowercased() ?? ""
        if host == self.rootDomain || host.hasSuffix(".\(self.rootDomain)") { return request }
        guard !Self.allCases.contains(where: {
            host == $0.rootDomain || host.hasSuffix(".\($0.rootDomain)")
        }) else { return nil }

        let environment = self.environment(environment)
        let canonical = self.environment([:])
        let aliases = [
            (
                MiniMaxUsageFetcher.resolveCodingPlanURL(region: region, environment: environment),
                MiniMaxUsageFetcher.resolveCodingPlanURL(region: region, environment: canonical)),
            (
                MiniMaxUsageFetcher.resolveBillingHistoryURL(region: region, environment: environment, page: 1),
                MiniMaxUsageFetcher.originURL(from: self.quotaURL)
                    .appendingPathComponent(MiniMaxAPIRegion.billingHistoryPath)),
        ] + MiniMaxUsageFetcher.resolveRemainsURLs(region: region, environment: environment).map {
            ($0, self.quotaURL)
        }
        if let alias = aliases.first(where: { Self.matchesEndpoint(request, $0.0) }) { return alias.1 }
        if let combo = try? MiniMaxSubscriptionMetadataFetcher.resolveComboURL(
            region: region, environment: environment), Self.matchesEndpoint(request, combo),
            let canonicalCombo = try? MiniMaxSubscriptionMetadataFetcher.resolveComboURL(
                region: region, environment: canonical)
        {
            guard let host = canonicalCombo.host,
                  host == self.rootDomain || host.hasSuffix(".\(self.rootDomain)") else { return nil }
            return canonicalCombo
        }
        return nil
    }

    private static func matchesEndpoint(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased() && lhs.host?.lowercased() == rhs.host?.lowercased() &&
            (lhs.port ?? 443) == (rhs.port ?? 443) && lhs.path == rhs.path
    }

    func environment(_ environment: [String: String]) -> [String: String] {
        guard SettingsValue.cleaned(environment[MiniMaxSettingsReader.hostKey]) == nil,
              SettingsValue.cleaned(environment[MiniMaxSettingsReader.codingPlanURLKey]) == nil,
              SettingsValue.cleaned(environment[MiniMaxSettingsReader.remainsURLKey]) == nil
        else { return environment }

        var result = environment
        switch self {
        case .global:
            break
        case .chinaMainland:
            result[MiniMaxSettingsReader.codingPlanURLKey] = "https://platform.minimax.cn/console/usage"
            result[MiniMaxSettingsReader.remainsURLKey] =
                "https://www.minimax.cn/backend/account/token_plan/remains_percent"
        case .legacyChina:
            result[MiniMaxSettingsReader.hostKey] = MiniMaxAPIRegion.chinaMainland.baseURLString
        }
        return result
    }
}

struct MiniMaxWebSession: Sendable {
    let cookieHeader: String
    let sourceLabel: String
    let domain: MiniMaxWebSessionDomain
    let cookies: [MiniMaxBrowserCookie]?

    init(
        cookieHeader: String,
        sourceLabel: String,
        domain: MiniMaxWebSessionDomain,
        cookies: [MiniMaxBrowserCookie]? = nil)
    {
        self.cookieHeader = cookieHeader
        self.sourceLabel = sourceLabel
        self.domain = domain
        self.cookies = cookies
    }

    var cacheableCookieHeader: String? {
        // A plain header cannot preserve host/path restrictions. Reimport scoped sessions instead of widening them.
        guard let cookies else { return self.cookieHeader }
        guard cookies.allSatisfy({
            $0.domain == self.domain.rootDomain && $0.includesSubdomains && $0.path == "/"
        }) else { return nil }
        return self.cookieHeader
    }

    func cookieHeader(for url: URL) -> String? {
        guard let cookies else { return self.cookieHeader }
        return Self.cookieHeader(from: cookies, for: url)
    }

    static func cookieHeader(from cookies: [MiniMaxBrowserCookie], for url: URL) -> String? {
        let matching = cookies.filter { $0.matches(url) }.sorted {
            if $0.path.count != $1.path.count { return $0.path.count > $1.path.count }
            return $0.domain.count > $1.domain.count
        }
        var names = Set<String>()
        let header = matching.filter { names.insert($0.name).inserted }
            .map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        return header.isEmpty ? nil : header
    }

    var groupID: String? {
        MiniMaxCookieHeader.override(from: self.cookieHeader)?.groupID
    }

    var usesTokenCookie: Bool {
        self.domain == .chinaMainland && CookieHeaderNormalizer.pairs(from: self.cookieHeader)
            .contains { $0.name == "_token" && !$0.value.isEmpty }
    }
}

struct MiniMaxBrowserCookie: Sendable {
    let domain: String
    let includesSubdomains: Bool
    let path: String
    let name: String
    let value: String
    let expires: Date?
    let isSecure: Bool

    func matches(_ url: URL, now: Date = Date()) -> Bool {
        guard let host = url.host?.lowercased(),
              host == self.domain || (self.includesSubdomains && host.hasSuffix(".\(self.domain)")),
              self.expires.map({ $0 > now }) ?? true,
              !self.isSecure || url.scheme?.lowercased() == "https"
        else { return false }
        return url.path == self.path || (url.path.hasPrefix(self.path) &&
            (self.path.hasSuffix("/") || url.path.dropFirst(self.path.count).hasPrefix("/")))
    }
}

struct MiniMaxBrowserSessionTransport: ProviderHTTPTransport {
    private static let sharedSession: URLSession = {
        let configuration = ProviderHTTPClient.defaultConfiguration()
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    let session: MiniMaxWebSession
    let region: MiniMaxAPIRegion
    @ProcessEnvironment private(set) var environment: [String: String]
    var cookieBearer: String?
    var transport: (any ProviderHTTPTransport)?

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let request = try self.authenticatedRequest(request)
        if let transport { return try await transport.data(for: request) }
        return try await Self.sharedSession.data(
            for: request, delegate: MiniMaxBrowserSessionRedirectDelegate(transport: self))
    }

    func authenticatedRequest(_ request: URLRequest) throws -> URLRequest {
        guard let url = request.url,
              let origin = self.session.domain.cookieURL(for: url, region: self.region, environment: self.environment)
        else { throw MiniMaxUsageError.parseFailed("No MiniMax browser cookies match the request URL.") }
        let header = self.session.cookieHeader(for: origin)
        let canUseBearer = request.value(forHTTPHeaderField: "Authorization") != nil &&
            (self.cookieBearer == nil || CookieHeaderNormalizer.pairs(from: header ?? "").contains(where: {
                $0.name == "HERTZ-SESSION" && $0.value == self.cookieBearer
            }))
        guard header != nil || canUseBearer else {
            throw MiniMaxUsageError.parseFailed("No MiniMax browser credentials match the request URL.")
        }
        var request = request
        request.setValue(header, forHTTPHeaderField: "Cookie")
        if !canUseBearer { request.setValue(nil, forHTTPHeaderField: "Authorization") }
        request.httpShouldHandleCookies = false
        return request
    }
}

final class MiniMaxBrowserSessionRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let transport: MiniMaxBrowserSessionTransport

    init(transport: MiniMaxBrowserSessionTransport) {
        self.transport = transport
    }

    func urlSession(
        _: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void)
    {
        completionHandler(self.redirectRequest(originalURL: task.originalRequest?.url, request: request))
    }

    func redirectRequest(originalURL: URL?, request: URLRequest) -> URLRequest? {
        guard let request = ProviderHTTPRedirectGuardDelegate.guardedRedirectRequest(
            originalURL: originalURL, redirectRequest: request) else { return nil }
        return try? self.transport.authenticatedRequest(request)
    }
}
