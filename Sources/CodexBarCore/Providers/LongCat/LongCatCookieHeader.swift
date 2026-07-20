import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct LongCatCookieOverride: Sendable {
    /// Full `Cookie:` header value (e.g. `name=value; name2=value2`).
    public let cookieHeader: String

    public init(cookieHeader: String) {
        self.cookieHeader = cookieHeader
    }
}

public enum LongCatCookieHeader {
    private static let log = CodexBarLog.logger(LogCategories.longcatCookie)
    private static let headerPatterns: [String] = [
        #"(?i)-H\s*'Cookie:\s*([^']+)'"#,
        #"(?i)-H\s*"Cookie:\s*([^"]+)""#,
        #"(?i)\bcookie:\s*'([^']+)'"#,
        #"(?i)\bcookie:\s*"([^"]+)""#,
        #"(?i)\bcookie:\s*([^\r\n]+)"#,
    ]

    public static func resolveCookieOverride(context: ProviderFetchContext) -> LongCatCookieOverride? {
        // Off disables LongCat web auth entirely — including a lingering env cookie.
        if context.settings?.longcat?.cookieSource == .off {
            return nil
        }

        if let settings = context.settings?.longcat, settings.cookieSource == .manual {
            if let manual = settings.manualCookieHeader, !manual.isEmpty {
                return self.override(from: manual)
            }
        }

        // Route env cookies through the settings reader so the lower-case
        // `longcat_manual_cookie` alias and quote-trimming apply on the env path too.
        if let envValue = LongCatSettingsReader.cookieHeader(environment: context.env),
           let envHeader = self.override(from: envValue)
        {
            return envHeader
        }

        return nil
    }

    public static func override(from raw: String?) -> LongCatCookieOverride? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }

        if let header = self.extractHeader(from: raw) {
            return LongCatCookieOverride(cookieHeader: header)
        }

        // A bare `name=value; ...` string is itself a usable cookie header.
        if raw.contains("=") {
            return LongCatCookieOverride(cookieHeader: raw)
        }

        return nil
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

    private static func extractHeader(from raw: String) -> String? {
        for pattern in self.headerPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { continue }
            let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
            guard let match = regex.firstMatch(in: raw, options: [], range: range),
                  match.numberOfRanges >= 2,
                  let captureRange = Range(match.range(at: 1), in: raw)
            else {
                continue
            }
            let captured = String(raw[captureRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !captured.isEmpty {
                return captured
            }
        }
        return nil
    }
}
