import Foundation

#if os(macOS)
import SweetCookieKit

private let mistralCookieImportOrder: BrowserCookieImportOrder =
    ProviderDefaults.metadata[.mistral]?.browserCookieOrder ?? Browser.defaultImportOrder

public enum MistralCookieImporter {
    private static let log = CodexBarLog.logger(LogCategories.mistralUsage)
    private static let cookieClient = BrowserCookieClient()
    private static let cookieDomains = ["console.mistral.ai", "admin.mistral.ai", "auth.mistral.ai", "mistral.ai"]

    public struct SessionInfo: Sendable {
        public let cookies: [HTTPCookie]
        public let sourceLabel: String

        public init(cookies: [HTTPCookie], sourceLabel: String) {
            self.cookies = cookies
            self.sourceLabel = sourceLabel
        }

        public var cookieOverride: MistralCookieOverride? {
            MistralCookieHeader.sessionCookie(from: self.cookies)
        }

        public var cookieHeader: String? {
            self.cookieOverride?.cookieHeader
        }

        public var csrfToken: String? {
            self.cookieOverride?.csrfToken
        }
    }

    public static func importSession(
        browserDetection: BrowserDetection = BrowserDetection(),
        logger: ((String) -> Void)? = nil) throws -> SessionInfo
    {
        let log: (String) -> Void = { message in self.emit(message, logger: logger) }

        for browserSource in mistralCookieImportOrder.cookieImportCandidates(using: browserDetection) {
            do {
                let query = BrowserCookieQuery(domains: self.cookieDomains)
                let sources = try Self.cookieClient.records(
                    matching: query,
                    in: browserSource,
                    logger: log)
                for source in sources where !source.records.isEmpty {
                    let httpCookies = BrowserCookieClient.makeHTTPCookies(source.records, origin: query.origin)
                    guard !httpCookies.isEmpty else { continue }
                    let session = SessionInfo(cookies: httpCookies, sourceLabel: source.label)
                    guard session.cookieOverride != nil else {
                        log("Skipping \(source.label) cookies: missing ory_session_* cookie")
                        continue
                    }
                    log("Found \(httpCookies.count) Mistral cookies in \(source.label)")
                    return session
                }
            } catch {
                BrowserCookieAccessGate.recordIfNeeded(error)
                log("\(browserSource.displayName) cookie import failed: \(error.localizedDescription)")
            }
        }

        throw MistralCookieImportError.noCookies
    }

    public static func hasSession(
        browserDetection: BrowserDetection = BrowserDetection(),
        logger: ((String) -> Void)? = nil) -> Bool
    {
        do {
            _ = try self.importSession(browserDetection: browserDetection, logger: logger)
            return true
        } catch {
            return false
        }
    }

    private static func emit(_ message: String, logger: ((String) -> Void)?) {
        logger?("[mistral-cookie] \(message)")
        self.log.debug(message)
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
