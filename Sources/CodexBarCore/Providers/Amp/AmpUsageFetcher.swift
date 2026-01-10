import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if os(macOS)
import SweetCookieKit
#endif

public enum AmpUsageError: LocalizedError, Sendable {
    case notLoggedIn
    case invalidCredentials
    case parseFailed(String)
    case networkError(String)
    case noSessionCookie

    public var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            "Not logged in to Amp. Please log in via ampcode.com."
        case .invalidCredentials:
            "Amp session cookie expired. Please log in again."
        case let .parseFailed(message):
            "Could not parse Amp usage: \(message)"
        case let .networkError(message):
            "Amp request failed: \(message)"
        case .noSessionCookie:
            "No Amp session cookie found. Please log in to ampcode.com in your browser."
        }
    }
}

#if os(macOS)
private let ampCookieImportOrder: BrowserCookieImportOrder =
    ProviderDefaults.metadata[.amp]?.browserCookieOrder ?? Browser.defaultImportOrder

public enum AmpCookieImporter {
    private static let cookieClient = BrowserCookieClient()
    private static let cookieDomains = ["ampcode.com", "www.ampcode.com"]

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
        logger: ((String) -> Void)? = nil) throws -> SessionInfo
    {
        let log: (String) -> Void = { msg in logger?("[amp-cookie] \(msg)") }

        let installed = ampCookieImportOrder.cookieImportCandidates(using: browserDetection)
        for browserSource in installed {
            do {
                let query = BrowserCookieQuery(domains: self.cookieDomains)
                let sources = try Self.cookieClient.records(
                    matching: query,
                    in: browserSource,
                    logger: log)
                for source in sources where !source.records.isEmpty {
                    let cookies = BrowserCookieClient.makeHTTPCookies(source.records, origin: query.origin)
                    guard !cookies.isEmpty else { continue }
                    let names = cookies.map(\.name).joined(separator: ", ")
                    log("Found Amp cookies in \(source.label): \(names)")
                    return SessionInfo(cookies: cookies, sourceLabel: source.label)
                }
            } catch {
                log("\(browserSource.displayName) cookie import failed: \(error.localizedDescription)")
            }
        }

        throw AmpUsageError.noSessionCookie
    }
}
#endif

public struct AmpUsageFetcher: Sendable {
    private static let settingsURL = URL(string: "https://ampcode.com/settings")!

    public let browserDetection: BrowserDetection

    public init(browserDetection: BrowserDetection) {
        self.browserDetection = browserDetection
    }

    public func fetch(
        cookieHeaderOverride: String? = nil,
        logger: ((String) -> Void)? = nil,
        now: Date = Date()) async throws -> AmpUsageSnapshot
    {
        let log: (String) -> Void = { msg in logger?("[amp] \(msg)") }
        let cookieHeader = try await self.resolveCookieHeader(override: cookieHeaderOverride, logger: log)

        var request = URLRequest(url: Self.settingsURL)
        request.httpMethod = "GET"
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "accept")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
                "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36",
            forHTTPHeaderField: "user-agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "accept-language")
        request.setValue("https://ampcode.com", forHTTPHeaderField: "origin")
        request.setValue(Self.settingsURL.absoluteString, forHTTPHeaderField: "referer")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AmpUsageError.networkError("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw AmpUsageError.invalidCredentials
            }
            log("Amp returned \(httpResponse.statusCode): \(body)")
            throw AmpUsageError.networkError("HTTP \(httpResponse.statusCode)")
        }

        let html = String(data: data, encoding: .utf8) ?? ""
        return try AmpUsageParser.parse(html: html, now: now)
    }

    private func resolveCookieHeader(
        override: String?,
        logger: ((String) -> Void)?) async throws -> String
    {
        if let override = CookieHeaderNormalizer.normalize(override) {
            return override
        }
        #if os(macOS)
        let session = try AmpCookieImporter.importSession(browserDetection: self.browserDetection, logger: logger)
        return session.cookieHeader
        #else
        throw AmpUsageError.noSessionCookie
        #endif
    }
}
