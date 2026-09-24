#if os(macOS)
import Foundation
import SweetCookieKit

/// kimi.ai keeps its session JWT in local storage (`access_token`) instead of a `kimi-auth` cookie.
enum KimiLocalStorageTokenImporter {
    static let tokenKey = "access_token"

    private static let log = CodexBarLog.logger(LogCategories.provider(.kimi, scope: "storage"))

    static func importTokens(
        region: KimiRegion,
        browserDetection: BrowserDetection = BrowserDetection(),
        localStorage: BrowserLocalStorageAPI = .live,
        now: Date = Date()) -> [String]
    {
        var seen = Set<String>()
        return self.candidates(region: region, browserDetection: browserDetection, localStorage: localStorage)
            .compactMap { candidate in
                guard let token = self.normalizedToken(candidate.value, now: now), seen.insert(token).inserted else {
                    return nil
                }
                self.log.debug("Found Kimi access_token in \(candidate.label)")
                return token
            }
    }

    /// True when a browser holds a Kimi session whose short-lived access token has lapsed.
    /// CodexBar never uses the refresh token: rotating it would sign the browser out.
    static func hasExpiredToken(
        region: KimiRegion,
        browserDetection: BrowserDetection = BrowserDetection(),
        localStorage: BrowserLocalStorageAPI = .live,
        now: Date = Date()) -> Bool
    {
        self.candidates(region: region, browserDetection: browserDetection, localStorage: localStorage)
            .contains { candidate in
                guard let token = self.normalizedToken(candidate.value, now: .distantPast) else { return false }
                return KimiDesktopAuthToken.isExpired(token, now: now)
            }
    }

    private static func candidates(
        region: KimiRegion,
        browserDetection: BrowserDetection,
        localStorage: BrowserLocalStorageAPI) -> [(label: String, value: String)]
    {
        let host = region.webBaseURL.host ?? "www.\(region.domain)"
        let browsers = Browser.defaultImportOrder.browsersWithProfileData(using: browserDetection)
        let logger: @Sendable (String) -> Void = { Self.log.debug($0) }

        var candidates: [(label: String, value: String)] = []
        let chromium = localStorage.profiles(
            for: "https://\(host)",
            browsers: browsers.filter(\.usesChromiumProfileStore),
            using: browserDetection,
            logger: logger)
        for profile in chromium {
            if let entry = profile.entries.first(where: { $0.key == self.tokenKey }) {
                candidates.append((profile.label, entry.value))
            }
        }
        let gecko = SQLiteWebStorageReader.geckoValues(
            key: self.tokenKey,
            host: host,
            browsers: browsers.filter(\.usesGeckoProfileStore))
        candidates += gecko.map { ($0.sourceLabel, $0.value) }
        // Safari local storage lives under the WebKit container, not the cookie file BrowserDetection checks.
        candidates += SQLiteWebStorageReader.safariValues(key: self.tokenKey, host: host)
            .map { ($0.sourceLabel, $0.value) }
        return candidates
    }

    /// Accepts a bare or JSON-quoted JWT and drops tokens that are already expired.
    static func normalizedToken(_ raw: String, now: Date = Date()) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            value = String(value.dropFirst().dropLast())
        }
        guard value.split(separator: ".", omittingEmptySubsequences: false).count == 3,
              value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }),
              !KimiDesktopAuthToken.isExpired(value, now: now)
        else { return nil }
        return value
    }
}
#endif
