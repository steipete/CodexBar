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
    case missingAPIToken
    case invalidAPIToken
    case parseFailed(String)
    case networkError(String)
    case noSessionCookie

    public var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            "Not logged in to Amp. Please log in via ampcode.com."
        case .invalidCredentials:
            "Amp session cookie expired. Please log in again."
        case .missingAPIToken:
            "Amp access token not configured. Set AMP_API_KEY or add it in Settings."
        case .invalidAPIToken:
            "Amp access token is invalid or expired."
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
    private static let sessionCookieNames: Set<String> = [
        "session",
    ]

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
                let sources = try Self.cookieClient.codexBarRecords(
                    matching: query,
                    in: browserSource,
                    logger: log)
                for source in sources where !source.records.isEmpty {
                    let cookies = BrowserCookieClient.makeHTTPCookies(source.records, origin: query.origin)
                    guard !cookies.isEmpty else { continue }
                    let names = cookies.map(\.name).joined(separator: ", ")
                    log("\(source.label) cookies: \(names)")
                    let sessionCookies = cookies.filter { Self.sessionCookieNames.contains($0.name) }
                    if !sessionCookies.isEmpty {
                        log("Found Amp session cookie in \(source.label)")
                        return SessionInfo(cookies: sessionCookies, sourceLabel: source.label)
                    }
                    log("\(source.label) cookies found, but no Amp session cookie present")
                    log("Expected one of: \(Self.sessionCookieNames.joined(separator: ", "))")
                }
            } catch {
                BrowserCookieAccessGate.recordIfNeeded(error)
                log("\(browserSource.displayName) cookie import failed: \(error.localizedDescription)")
            }
        }

        throw AmpUsageError.noSessionCookie
    }
}
#endif

public struct AmpUsageFetcher: Sendable {
    private static let settingsURL = URL(string: "https://ampcode.com/settings")!
    static let usageURL = URL(string: "https://ampcode.com/api/internal?userDisplayBalanceInfo")!
    @MainActor private static var recentDumps: [String] = []

    public let browserDetection: BrowserDetection
    private let makeURLSession: @Sendable (URLSessionTaskDelegate?) -> URLSession
    private let finishURLSession: @Sendable (URLSession) -> Void

    public init(browserDetection: BrowserDetection) {
        self.browserDetection = browserDetection
        self.makeURLSession = { delegate in
            URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        }
        self.finishURLSession = { $0.finishTasksAndInvalidate() }
    }

    init(
        browserDetection: BrowserDetection,
        makeURLSession: @escaping @Sendable (URLSessionTaskDelegate?) -> URLSession,
        finishURLSession: @escaping @Sendable (URLSession) -> Void = { $0.finishTasksAndInvalidate() })
    {
        self.browserDetection = browserDetection
        self.makeURLSession = makeURLSession
        self.finishURLSession = finishURLSession
    }

    public func fetch(
        cookieHeaderOverride: String? = nil,
        logger: ((String) -> Void)? = nil,
        now: Date = Date()) async throws -> AmpUsageSnapshot
    {
        let log: (String) -> Void = { msg in logger?("[amp] \(msg)") }
        let cookieHeader = try await self.resolveCookieHeader(override: cookieHeaderOverride, logger: log)

        if let logger {
            let names = self.cookieNames(from: cookieHeader)
            if !names.isEmpty {
                logger("[amp] Cookie names: \(names.joined(separator: ", "))")
            }
            let diagnostics = RedirectDiagnostics(cookieHeader: cookieHeader, logger: logger)
            do {
                let (html, responseInfo) = try await self.fetchLegacyHTMLWithDiagnostics(
                    cookieHeader: cookieHeader,
                    diagnostics: diagnostics)
                self.logDiagnostics(responseInfo: responseInfo, diagnostics: diagnostics, logger: logger)
                return try AmpUsageParser.parse(html: html, now: now)
            } catch {
                self.logDiagnostics(responseInfo: nil, diagnostics: diagnostics, logger: logger)
                logger("[amp] Fetch failed: \(error.localizedDescription)")
                throw error
            }
        }

        let diagnostics = RedirectDiagnostics(cookieHeader: cookieHeader, logger: nil)
        let (html, _) = try await self.fetchLegacyHTMLWithDiagnostics(
            cookieHeader: cookieHeader,
            diagnostics: diagnostics)
        return try AmpUsageParser.parse(html: html, now: now)
    }

    public func fetch(
        apiToken: String,
        logger: ((String) -> Void)? = nil,
        now: Date = Date()) async throws -> AmpUsageSnapshot
    {
        guard let token = AmpSettingsReader.cleaned(apiToken) else {
            throw AmpUsageError.missingAPIToken
        }
        let request = try Self.makeUsageAPIRequest(apiToken: token)
        let diagnostics = APIRedirectDiagnostics(logger: logger)
        let session = self.makeURLSession(diagnostics)
        defer { self.finishURLSession(session) }
        let httpResponse = try await session.response(for: request)
        logger?("[amp] API response: \(httpResponse.statusCode) " +
            "\(httpResponse.response.url?.absoluteString ?? "unknown")")
        try Self.validateAPIResponse(httpResponse)
        return try Self.parseUsageAPIResponse(httpResponse.data, now: now)
    }

    public func debugRawProbe(cookieHeaderOverride: String? = nil) async -> String {
        let stamp = ISO8601DateFormatter().string(from: Date())
        var lines: [String] = []
        lines.append("=== Amp Debug Probe @ \(stamp) ===")
        lines.append("")

        do {
            let cookieHeader = try await self.resolveCookieHeader(
                override: cookieHeaderOverride,
                logger: { msg in lines.append("[cookie] \(msg)") })
            let diagnostics = RedirectDiagnostics(cookieHeader: cookieHeader, logger: nil)
            let cookieNames = CookieHeaderNormalizer.pairs(from: cookieHeader).map(\.name)
            lines.append("Cookie names: \(cookieNames.joined(separator: ", "))")

            let (html, responseInfo) = try await self.fetchLegacyHTMLWithDiagnostics(
                cookieHeader: cookieHeader,
                diagnostics: diagnostics)
            let snapshot = try AmpUsageParser.parse(html: html)

            lines.append("")
            lines.append("Fetch Success")
            lines.append("Status: \(responseInfo.statusCode) \(responseInfo.url)")

            if !diagnostics.redirects.isEmpty {
                lines.append("")
                lines.append("Redirects:")
                for entry in diagnostics.redirects {
                    lines.append("  \(entry)")
                }
            }

            lines.append("")
            lines.append("Amp Free:")
            lines.append("  quota=\(snapshot.freeQuota?.description ?? "nil")")
            lines.append("  used=\(snapshot.freeUsed?.description ?? "nil")")
            lines.append("  hourlyReplenishment=\(snapshot.hourlyReplenishment?.description ?? "nil")")
            lines.append("  windowHours=\(snapshot.windowHours?.description ?? "nil")")
            lines.append("  individualCredits=\(snapshot.individualCredits?.description ?? "nil")")
            for workspace in snapshot.workspaceBalances {
                lines.append("  workspace[\(workspace.name)]=\(workspace.remaining)")
            }

            let output = lines.joined(separator: "\n")
            Task { @MainActor in Self.recordDump(output) }
            return output
        } catch {
            lines.append("")
            lines.append("Probe Failed: \(error.localizedDescription)")
            let output = lines.joined(separator: "\n")
            Task { @MainActor in Self.recordDump(output) }
            return output
        }
    }

    public static func latestDumps() async -> String {
        await MainActor.run {
            let result = Self.recentDumps.joined(separator: "\n\n---\n\n")
            return result.isEmpty ? "No Amp probe dumps captured yet." : result
        }
    }

    private func resolveCookieHeader(
        override: String?,
        logger: ((String) -> Void)?) async throws -> String
    {
        if let override = CookieHeaderNormalizer.normalize(override) {
            if let sessionHeader = self.sessionCookieHeader(from: override) {
                logger?("[amp] Using manual session cookie")
                return sessionHeader
            }
            throw AmpUsageError.noSessionCookie
        }
        #if os(macOS)
        let session = try AmpCookieImporter.importSession(browserDetection: self.browserDetection, logger: logger)
        logger?("[amp] Using cookies from \(session.sourceLabel)")
        return session.cookieHeader
        #else
        throw AmpUsageError.noSessionCookie
        #endif
    }

    static func makeUsageAPIRequest(apiToken: String) throws -> URLRequest {
        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "method": "userDisplayBalanceInfo",
            "params": [:],
        ])
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        return request
    }

    private func fetchLegacyHTMLWithDiagnostics(
        cookieHeader: String,
        diagnostics: RedirectDiagnostics) async throws -> (String, ResponseInfo)
    {
        var request = URLRequest(url: Self.settingsURL)
        request.httpMethod = "GET"
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue(
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            forHTTPHeaderField: "accept")
        Self.applyBrowserHeaders(to: &request)

        let session = self.makeURLSession(diagnostics)
        defer { self.finishURLSession(session) }
        let httpResponse = try await session.response(for: request)
        let responseInfo = ResponseInfo(
            statusCode: httpResponse.statusCode,
            url: httpResponse.response.url?.absoluteString ?? "unknown")
        try Self.validateBrowserResponse(response: httpResponse, diagnostics: diagnostics)

        let html = String(data: httpResponse.data, encoding: .utf8) ?? ""
        return (html, responseInfo)
    }

    static func parseUsageAPIResponse(_ data: Data, now: Date = Date()) throws -> AmpUsageSnapshot {
        let response: UsageAPIResponse
        do {
            response = try JSONDecoder().decode(UsageAPIResponse.self, from: data)
        } catch {
            throw AmpUsageError.parseFailed("Invalid Amp usage API response.")
        }

        guard response.ok else {
            if response.error?.code == "auth-required" {
                throw AmpUsageError.invalidAPIToken
            }
            throw AmpUsageError.networkError(response.error?.message ?? "Amp usage API returned an error.")
        }
        guard let displayText = response.result?.displayText, !displayText.isEmpty else {
            throw AmpUsageError.parseFailed("Missing Amp usage display text.")
        }
        return try AmpUsageParser.parse(displayText: displayText, now: now)
    }

    private static func applyBrowserHeaders(to request: inout URLRequest) {
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
                "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36",
            forHTTPHeaderField: "user-agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "accept-language")
        request.setValue("https://ampcode.com", forHTTPHeaderField: "origin")
        request.setValue(self.settingsURL.absoluteString, forHTTPHeaderField: "referer")
    }

    private static func validateBrowserResponse(
        response: ProviderHTTPResponse,
        diagnostics: RedirectDiagnostics) throws
    {
        guard response.statusCode == 200 else {
            if response.statusCode == 401 || response.statusCode == 403 || diagnostics.detectedLoginRedirect {
                throw AmpUsageError.invalidCredentials
            }
            throw AmpUsageError.networkError("HTTP \(response.statusCode)")
        }
    }

    private static func validateAPIResponse(_ response: ProviderHTTPResponse) throws {
        guard response.statusCode == 200 else {
            if response.statusCode == 401 || response.statusCode == 403 {
                throw AmpUsageError.invalidAPIToken
            }
            throw AmpUsageError.networkError("HTTP \(response.statusCode)")
        }
    }

    @MainActor private static func recordDump(_ text: String) {
        if self.recentDumps.count >= 5 {
            self.recentDumps.removeFirst()
        }
        self.recentDumps.append(text)
    }

    private final class RedirectDiagnostics: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let cookieHeader: String
        private let logger: ((String) -> Void)?
        var redirects: [String] = []
        private(set) var detectedLoginRedirect = false

        init(cookieHeader: String, logger: ((String) -> Void)?) {
            self.cookieHeader = cookieHeader
            self.logger = logger
        }

        func urlSession(
            _: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void)
        {
            let from = response.url?.absoluteString ?? "unknown"
            let to = request.url?.absoluteString ?? "unknown"
            self.redirects.append("\(response.statusCode) \(from) -> \(to)")

            if let toURL = request.url, AmpUsageFetcher.isLoginRedirect(toURL) {
                if let logger {
                    logger("[amp] Detected login redirect, aborting (invalid session)")
                }
                self.detectedLoginRedirect = true
                completionHandler(nil)
                return
            }

            var updated = request
            if AmpUsageFetcher.shouldAttachCookie(to: request.url), !self.cookieHeader.isEmpty {
                updated.setValue(self.cookieHeader, forHTTPHeaderField: "Cookie")
            } else {
                updated.setValue(nil, forHTTPHeaderField: "Cookie")
            }
            if let referer = response.url?.absoluteString {
                updated.setValue(referer, forHTTPHeaderField: "referer")
            }
            if let logger {
                logger("[amp] Redirect \(response.statusCode) \(from) -> \(to)")
            }
            completionHandler(updated)
        }
    }

    /// Amp's balance RPC should not redirect. Refusing redirects guarantees the bearer token cannot cross hosts.
    private final class APIRedirectDiagnostics: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let logger: ((String) -> Void)?

        init(logger: ((String) -> Void)?) {
            self.logger = logger
        }

        func urlSession(
            _: URLSession,
            task _: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void)
        {
            let from = response.url?.absoluteString ?? "unknown"
            let to = request.url?.absoluteString ?? "unknown"
            self.logger?("[amp] API redirect blocked: \(response.statusCode) \(from) -> \(to)")
            completionHandler(nil)
        }
    }

    private struct ResponseInfo {
        let statusCode: Int
        let url: String
    }

    private struct UsageAPIResponse: Decodable {
        let ok: Bool
        let result: Result?
        let error: APIError?

        struct Result: Decodable {
            let displayText: String
        }

        struct APIError: Decodable {
            let code: String?
            let message: String?
        }
    }

    private func logDiagnostics(
        responseInfo: ResponseInfo?,
        diagnostics: RedirectDiagnostics,
        logger: (String) -> Void)
    {
        if let responseInfo {
            logger("[amp] Response: \(responseInfo.statusCode) \(responseInfo.url)")
        }
        if !diagnostics.redirects.isEmpty {
            logger("[amp] Redirects:")
            for entry in diagnostics.redirects {
                logger("[amp]   \(entry)")
            }
        }
    }

    private func cookieNames(from header: String) -> [String] {
        header.split(separator: ";").compactMap { part in
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let idx = trimmed.firstIndex(of: "=") else { return nil }
            let name = trimmed[..<idx].trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : String(name)
        }
    }

    private func sessionCookieHeader(from header: String) -> String? {
        let pairs = CookieHeaderNormalizer.pairs(from: header)
        let sessionPairs = pairs.filter { $0.name == "session" }
        guard !sessionPairs.isEmpty else { return nil }
        return sessionPairs.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    static func shouldAttachCookie(to url: URL?) -> Bool {
        guard url?.scheme?.lowercased() == "https" else { return false }
        return self.isAmpHost(url)
    }

    private static func isAmpHost(_ url: URL?) -> Bool {
        guard let host = url?.host?.lowercased() else { return false }
        if host == "ampcode.com" || host == "www.ampcode.com" {
            return true
        }
        return host.hasSuffix(".ampcode.com")
    }

    static func isLoginRedirect(_ url: URL) -> Bool {
        guard self.isAmpHost(url) else { return false }
        if url.host?.lowercased() == "auth.ampcode.com" {
            return true
        }

        let path = url.path.lowercased()
        let components = path.split(separator: "/").map(String.init)
        if components.contains("login") {
            return true
        }
        if components.contains("signin") {
            return true
        }
        if components.contains("sign-in") {
            return true
        }

        // Amp currently redirects to /auth/sign-in?returnTo=... when session is invalid. Keep this slightly broader
        // than one exact path so we keep working if Amp changes auth routes.
        if components.contains("auth") {
            let query = url.query?.lowercased() ?? ""
            if query.contains("returnto=") {
                return true
            }
            if query.contains("redirect=") {
                return true
            }
            if query.contains("redirectto=") {
                return true
            }
        }

        return false
    }
}
