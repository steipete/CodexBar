import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The one credential the Helmcode provider will use for a fetch: its normalized header, the raw
/// pre-normalization text (so a cURL capture can be host-detected), and where it came from. Selected
/// in exactly one place so a manual paste and an environment cookie can never both be consulted.
public struct HelmcodeCredentialSelection: Sendable, Equatable {
    public enum Origin: Sendable, Equatable {
        case manual
        case environment
    }

    public let cookieHeader: String
    public let rawCapture: String
    public let origin: Origin

    public init(cookieHeader: String, rawCapture: String, origin: Origin) {
        self.cookieHeader = cookieHeader
        self.rawCapture = rawCapture
        self.origin = origin
    }
}

public enum HelmcodeCookieHeader {
    /// Selects the single credential for this fetch: `.off` → nil; a manual source with a normalizable
    /// header → manual; otherwise `HELMCODE_COOKIE`/`helmcode_cookie` with a normalizable header →
    /// environment. An empty (non-normalizable) manual value is not a credential, so selection falls
    /// through to the environment credential — and carries that credential's own raw capture so host
    /// detection routes it to the tenant the capture came from.
    public static func selectCredential(context: ProviderFetchContext) -> HelmcodeCredentialSelection? {
        self.selectCredential(
            cookieSource: context.settings?.helmcode?.cookieSource,
            manualCookieHeader: context.settings?.helmcode?.manualCookieHeader,
            environment: context.env)
    }

    public static func selectCredential(
        cookieSource: ProviderCookieSource?,
        manualCookieHeader: String?,
        environment: [String: String]) -> HelmcodeCredentialSelection?
    {
        if cookieSource == .off {
            return nil
        }
        if cookieSource == .manual,
           let header = CookieHeaderNormalizer.normalize(manualCookieHeader)
        {
            return HelmcodeCredentialSelection(
                cookieHeader: header,
                rawCapture: manualCookieHeader ?? "",
                origin: .manual)
        }
        // The reader accepts both spellings; uppercase wins so callers that export both stay consistent.
        let raw = environment[HelmcodeSettingsReader.cookieHeaderEnvironmentKey]
            ?? environment[HelmcodeSettingsReader.cookieHeaderEnvironmentKey.lowercased()]
        if let header = CookieHeaderNormalizer.normalize(raw) {
            return HelmcodeCredentialSelection(cookieHeader: header, rawCapture: raw ?? "", origin: .environment)
        }
        return nil
    }

    /// Builds the request header with per-cookie boundary diagnostics: expired and path-mismatched
    /// cookies are excluded and reported by name, never by value.
    static func headerWithDiagnostics(
        from cookies: [HTTPCookie],
        for url: URL,
        now: Date = Date())
        -> (header: String?, included: [String], expired: [String], pathExcluded: [String])
    {
        guard let host = url.host?.lowercased() else { return (nil, [], [], []) }
        let requestPath = url.path.isEmpty ? "/" : url.path
        let isHTTPS = url.scheme?.lowercased() == "https"

        var included: [String] = []
        var expired: [String] = []
        var pathExcluded: [String] = []
        var matching: [HTTPCookie] = []
        for cookie in cookies.sorted(by: Self.cookieOrder) {
            if cookie.expiresDate.map({ $0 <= now }) == true {
                expired.append(cookie.name)
                continue
            }
            guard !cookie.isSecure || isHTTPS else { continue }
            guard self.domain(cookie.domain, matches: host) else { continue }
            guard self.path(cookie.path, matches: requestPath) else {
                pathExcluded.append(cookie.name)
                continue
            }
            included.append(cookie.name)
            matching.append(cookie)
        }

        guard !matching.isEmpty else { return (nil, included, expired, pathExcluded) }
        let header = matching.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        return (header, included, expired, pathExcluded)
    }

    static func header(from cookies: [HTTPCookie], for url: URL, now: Date = Date()) -> String? {
        self.headerWithDiagnostics(from: cookies, for: url, now: now).header
    }

    private static func cookieOrder(_ lhs: HTTPCookie, _ rhs: HTTPCookie) -> Bool {
        if lhs.path.count != rhs.path.count {
            return lhs.path.count > rhs.path.count
        }
        if lhs.name != rhs.name {
            return lhs.name < rhs.name
        }
        return lhs.domain < rhs.domain
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
