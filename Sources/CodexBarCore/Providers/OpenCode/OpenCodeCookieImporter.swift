import Foundation

#if os(macOS)
import SweetCookieKit

private let opencodeCookieImportOrder: BrowserCookieImportOrder =
    ProviderDefaults.metadata[.opencode]?.browserCookieOrder ?? Browser.defaultImportOrder

public enum OpenCodeCookieImporter {
    private static let cookieClient = BrowserCookieClient()
    private static let cookieDomains = ["opencode.ai", "app.opencode.ai"]

    public struct SessionInfo: Sendable {
        public let cookies: [HTTPCookie]
        public let sourceLabel: String

        public init(cookies: [HTTPCookie], sourceLabel: String) {
            self.cookies = cookies
            self.sourceLabel = sourceLabel
        }

        public var cookieHeader: String {
            self.cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        }
    }

    public static func importSession(
        browserDetection: BrowserDetection,
        preferredBrowsers: [Browser] = [.chrome],
        logger: ((String) -> Void)? = nil) throws -> SessionInfo
    {
        let log: (String) -> Void = { msg in logger?("[opencode-cookie] \(msg)") }
        let installedBrowsers = preferredBrowsers.isEmpty
            ? opencodeCookieImportOrder.cookieImportCandidates(using: browserDetection)
            : preferredBrowsers.cookieImportCandidates(using: browserDetection)

        for browserSource in installedBrowsers {
            do {
                let query = BrowserCookieQuery(domains: self.cookieDomains)
                let sources = try Self.cookieClient.records(
                    matching: query,
                    in: browserSource,
                    logger: log)
                for source in sources where !source.records.isEmpty {
                    let httpCookies = BrowserCookieClient.makeHTTPCookies(source.records, origin: query.origin)
                    if !httpCookies.isEmpty {
                        let hasAuthCookie = httpCookies.contains { cookie in
                            cookie.name == "auth" || cookie.name == "__Host-auth"
                        }
                        if !hasAuthCookie {
                            log("Skipping \(source.label) cookies: missing auth cookie")
                            continue
                        }
                        log("Found \(httpCookies.count) OpenCode cookies in \(source.label)")
                        return SessionInfo(cookies: httpCookies, sourceLabel: source.label)
                    }
                }
            } catch {
                BrowserCookieAccessGate.recordIfNeeded(error)
                log("\(browserSource.displayName) cookie import failed: \(error.localizedDescription)")
            }
        }

        throw OpenCodeCookieImportError.noCookies
    }

    public static func hasSession(
        browserDetection: BrowserDetection,
        preferredBrowsers: [Browser] = [.chrome],
        logger: ((String) -> Void)? = nil) -> Bool
    {
        do {
            _ = try self.importSession(
                browserDetection: browserDetection,
                preferredBrowsers: preferredBrowsers,
                logger: logger)
            return true
        } catch {
            return false
        }
    }
}

enum OpenCodeCookieImportError: LocalizedError {
    case noCookies

    var errorDescription: String? {
        switch self {
        case .noCookies:
            "No OpenCode session cookies found in browsers."
        }
    }
}
#endif
