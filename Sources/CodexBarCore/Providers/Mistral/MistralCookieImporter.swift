import Foundation

#if os(macOS)
import SweetCookieKit

private let mistralCookieImportOrder: BrowserCookieImportOrder =
    ProviderDefaults.metadata[.mistral]?.browserCookieOrder ?? Browser.defaultImportOrder

public enum MistralCookieImporter {
    private static let cookieClient = BrowserCookieClient()
    private static let cookieDomains = ["mistral.ai", "admin.mistral.ai", "auth.mistral.ai"]

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

        /// Extracts the CSRF token from the `csrftoken` cookie for the `X-CSRFTOKEN` header.
        public var csrfToken: String? {
            self.cookies.first { $0.name == "csrftoken" }?.value
        }
    }

    /// Returns `true` if any cookie name starts with `ory_session_` (the Ory Kratos session cookie).
    private static func hasSessionCookie(_ cookies: [HTTPCookie]) -> Bool {
        cookies.contains { $0.name.hasPrefix("ory_session_") }
    }

    public static func importSession(
        browserDetection: BrowserDetection,
        preferredBrowsers: [Browser] = [.chrome],
        logger: ((String) -> Void)? = nil) throws -> SessionInfo
    {
        let log: (String) -> Void = { msg in logger?("[mistral-cookie] \(msg)") }
        let installedBrowsers = preferredBrowsers.isEmpty
            ? mistralCookieImportOrder.cookieImportCandidates(using: browserDetection)
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
                        guard Self.hasSessionCookie(httpCookies) else {
                            log("Skipping \(source.label) cookies: missing ory_session_* cookie")
                            continue
                        }
                        log("Found \(httpCookies.count) Mistral cookies in \(source.label)")
                        return SessionInfo(cookies: httpCookies, sourceLabel: source.label)
                    }
                }
            } catch {
                BrowserCookieAccessGate.recordIfNeeded(error)
                log("\(browserSource.displayName) cookie import failed: \(error.localizedDescription)")
            }
        }

        throw MistralCookieImportError.noCookies
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

enum MistralCookieImportError: LocalizedError {
    case noCookies

    var errorDescription: String? {
        switch self {
        case .noCookies:
            "No Mistral session cookies found in browsers."
        }
    }
}
#endif
