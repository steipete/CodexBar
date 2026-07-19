import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if os(macOS)
import SweetCookieKit
#endif

private let ollamaSessionCookieNames: Set<String> = [
    "session",
    "__Secure-session",
    "ollama_session",
    "__Host-ollama_session",
    "wos-session",
    "__Secure-next-auth.session-token",
    "next-auth.session-token",
]

private func isRecognizedOllamaSessionCookieName(_ name: String) -> Bool {
    if ollamaSessionCookieNames.contains(name) {
        return true
    }
    // next-auth can split tokens into chunked cookies: `<name>.0`, `<name>.1`, ...
    return name.hasPrefix("__Secure-next-auth.session-token.") ||
        name.hasPrefix("next-auth.session-token.")
}

private func hasRecognizedOllamaSessionCookie(in header: String) -> Bool {
    CookieHeaderNormalizer.pairs(from: header).contains { pair in
        isRecognizedOllamaSessionCookieName(pair.name)
    }
}

public enum OllamaUsageError: LocalizedError, Sendable {
    private static let signInURL = "https://ollama.com/signin"

    case missingAPIKey
    case notLoggedIn
    case invalidCredentials
    case apiUnauthorized
    case parseFailed(String)
    case networkError(String)
    case noSessionCookie
    case safariCookieAccessDenied
    case browserCookieDecryptionDenied(String)
    case browserCookieDecryptionDisabled(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "Missing Ollama API key. Set apiKey in ~/.codexbar/config.json or OLLAMA_API_KEY."
        case .notLoggedIn:
            "Not signed in to Ollama. Please sign in at \(Self.signInURL)."
        case .invalidCredentials:
            "Ollama session cookie expired. Please sign in again at \(Self.signInURL)."
        case .apiUnauthorized:
            "Ollama API key is invalid or revoked."
        case let .parseFailed(message):
            "Could not parse Ollama usage: \(message)"
        case let .networkError(message):
            "Ollama request failed: \(message)"
        case .noSessionCookie:
            "No Ollama session cookie found. Please sign in at \(Self.signInURL) in your browser."
        case .safariCookieAccessDenied:
            "Safari cookies need Full Disk Access for CodexBar (System Settings > Privacy & Security)."
        case let .browserCookieDecryptionDenied(browserName):
            "\(browserName) cookie decryption was declined in Keychain; retry with a manual refresh."
        case let .browserCookieDecryptionDisabled(browserName):
            "\(browserName) cookie decryption is disabled in CodexBar; enable Keychain access and refresh."
        }
    }
}

#if os(macOS)
private let ollamaCookieImportOrder: BrowserCookieImportOrder =
    ProviderDefaults.metadata[.ollama]?.browserCookieOrder ?? Browser.defaultImportOrder

public enum OllamaCookieImporter {
    private static let cookieClient = BrowserCookieClient()
    private static let cookieDomains = ["ollama.com", "www.ollama.com"]
    static let defaultPreferredBrowsers: [Browser] = [.chrome]
    static let defaultAllowFallbackBrowsers = true

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

    public static func importSessions(
        browserDetection: BrowserDetection,
        preferredBrowsers: [Browser] = [.chrome],
        allowFallbackBrowsers: Bool = false,
        logger: ((String) -> Void)? = nil) throws -> [SessionInfo]
    {
        let log: (String) -> Void = { msg in logger?("[ollama-cookie] \(msg)") }
        var accessError: OllamaUsageError?
        let preferredOrder = preferredBrowsers.isEmpty ? ollamaCookieImportOrder : preferredBrowsers
        let preferredSources = self.cookieSources(
            from: preferredOrder,
            browserDetection: browserDetection,
            accessError: &accessError)
        let preferredCandidates = self.collectSessionInfo(
            from: preferredSources,
            logger: log,
            accessError: &accessError)
        do {
            return try self.selectSessionInfos(from: preferredCandidates, logger: log)
        } catch OllamaUsageError.noSessionCookie {
            guard allowFallbackBrowsers, !preferredBrowsers.isEmpty else {
                throw accessError ?? OllamaUsageError.noSessionCookie
            }
        }

        let fallbackOrder = ollamaCookieImportOrder.filter { !preferredBrowsers.contains($0) }
        let fallbackSources = self.cookieSources(
            from: fallbackOrder,
            browserDetection: browserDetection,
            accessError: &accessError)
        if !fallbackSources.isEmpty {
            log("No recognized Ollama session in preferred browsers; trying fallback import order")
        }
        let fallbackCandidates = self.collectSessionInfo(
            from: fallbackSources,
            logger: log,
            accessError: &accessError)
        do {
            return try self.selectSessionInfos(from: fallbackCandidates, logger: log)
        } catch OllamaUsageError.noSessionCookie {
            throw accessError ?? OllamaUsageError.noSessionCookie
        }
    }

    public static func importSession(
        browserDetection: BrowserDetection,
        preferredBrowsers: [Browser] = [.chrome],
        allowFallbackBrowsers: Bool = false,
        logger: ((String) -> Void)? = nil) throws -> SessionInfo
    {
        let sessions = try self.importSessions(
            browserDetection: browserDetection,
            preferredBrowsers: preferredBrowsers,
            allowFallbackBrowsers: allowFallbackBrowsers,
            logger: logger)
        guard let first = sessions.first else {
            throw OllamaUsageError.noSessionCookie
        }
        return first
    }

    static func selectSessionInfos(
        from candidates: [SessionInfo],
        logger: ((String) -> Void)? = nil) throws -> [SessionInfo]
    {
        var recognized: [SessionInfo] = []
        for candidate in candidates {
            let names = candidate.cookies.map(\.name).joined(separator: ", ")
            logger?("\(candidate.sourceLabel) cookies: \(names)")
            if self.containsRecognizedSessionCookie(in: candidate.cookies) {
                logger?("Found Ollama session cookie in \(candidate.sourceLabel)")
                recognized.append(candidate)
            } else {
                logger?("\(candidate.sourceLabel) cookies found, but no recognized session cookie present")
            }
        }
        guard !recognized.isEmpty else {
            throw OllamaUsageError.noSessionCookie
        }
        return recognized
    }

    static func selectSessionInfo(
        from candidates: [SessionInfo],
        logger: ((String) -> Void)? = nil) throws -> SessionInfo
    {
        guard let first = try self.selectSessionInfos(from: candidates, logger: logger).first else {
            throw OllamaUsageError.noSessionCookie
        }
        return first
    }

    static func selectSessionInfosWithFallback(
        preferredCandidates: [SessionInfo],
        allowFallbackBrowsers: Bool,
        loadFallbackCandidates: () -> [SessionInfo],
        logger: ((String) -> Void)? = nil) throws -> [SessionInfo]
    {
        guard allowFallbackBrowsers else {
            return try self.selectSessionInfos(from: preferredCandidates, logger: logger)
        }
        do {
            return try self.selectSessionInfos(from: preferredCandidates, logger: logger)
        } catch OllamaUsageError.noSessionCookie {
            let fallbackCandidates = loadFallbackCandidates()
            return try self.selectSessionInfos(from: fallbackCandidates, logger: logger)
        }
    }

    static func selectSessionInfoWithFallback(
        preferredCandidates: [SessionInfo],
        allowFallbackBrowsers: Bool,
        loadFallbackCandidates: () -> [SessionInfo],
        logger: ((String) -> Void)? = nil) throws -> SessionInfo
    {
        guard let first = try self.selectSessionInfosWithFallback(
            preferredCandidates: preferredCandidates,
            allowFallbackBrowsers: allowFallbackBrowsers,
            loadFallbackCandidates: loadFallbackCandidates,
            logger: logger).first
        else {
            throw OllamaUsageError.noSessionCookie
        }
        return first
    }

    static func accessError(from error: Error) -> OllamaUsageError? {
        guard case let BrowserCookieError.accessDenied(browser, _) = error else { return nil }
        if browser == .safari {
            return .safariCookieAccessDenied
        }
        guard browser.usesKeychainForCookieDecryption else { return nil }
        return .browserCookieDecryptionDenied(browser.displayName)
    }

    static func suppressedAccessError(for browser: Browser, now: Date = Date()) -> OllamaUsageError? {
        guard browser.usesKeychainForCookieDecryption else { return nil }
        if KeychainAccessGate.isDisabled {
            return .browserCookieDecryptionDisabled(browser.displayName)
        }
        guard BrowserCookieAccessGate.hasActiveDenial(for: browser, now: now) else { return nil }
        return .browserCookieDecryptionDenied(browser.displayName)
    }

    private static func cookieSources(
        from browserOrder: [Browser],
        browserDetection: BrowserDetection,
        accessError: inout OllamaUsageError?) -> [Browser]
    {
        var sources: [Browser] = []
        for browser in browserOrder where browserDetection.isCookieSourceAvailable(browser) {
            guard self.shouldAttemptCookieSource(browser, accessError: &accessError) else { continue }
            sources.append(browser)
        }
        return sources
    }

    static func shouldAttemptCookieSource(
        _ browser: Browser,
        now: Date = Date(),
        accessError: inout OllamaUsageError?) -> Bool
    {
        guard BrowserCookieAccessGate.shouldAttempt(browser, now: now) else {
            accessError = accessError ?? self.suppressedAccessError(for: browser, now: now)
            return false
        }
        return true
    }

    private static func collectSessionInfo(
        from browserSources: [Browser],
        logger: @escaping (String) -> Void,
        accessError: inout OllamaUsageError?) -> [SessionInfo]
    {
        var candidates: [SessionInfo] = []
        for browserSource in browserSources {
            do {
                let query = BrowserCookieQuery(domains: self.cookieDomains)
                let sources = try Self.cookieClient.codexBarRecords(
                    matching: query,
                    in: browserSource,
                    logger: logger)
                for source in sources where !source.records.isEmpty {
                    let cookies = BrowserCookieClient.makeHTTPCookies(source.records, origin: query.origin)
                    guard !cookies.isEmpty else { continue }
                    candidates.append(SessionInfo(cookies: cookies, sourceLabel: source.label))
                }
            } catch {
                BrowserCookieAccessGate.recordIfNeeded(error)
                accessError = accessError ?? self.accessError(from: error)
                logger("\(browserSource.displayName) cookie import failed: \(error.localizedDescription)")
            }
        }
        return candidates
    }

    private static func containsRecognizedSessionCookie(in cookies: [HTTPCookie]) -> Bool {
        cookies.contains { cookie in
            isRecognizedOllamaSessionCookieName(cookie.name)
        }
    }
}
#endif

public struct OllamaUsageFetcher: Sendable {
    private static let settingsURL = URL(string: "https://ollama.com/settings")!
    @MainActor private static var recentDumps: [String] = []

    private struct CookieCandidate {
        let cookieHeader: String
        let sourceLabel: String
    }

    enum RetryableParseFailure: Error {
        case missingUsageData
    }

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
        manualCookieMode: Bool = false,
        logger: ((String) -> Void)? = nil,
        now: Date = Date()) async throws -> OllamaUsageSnapshot
    {
        let cookieCandidates = try await self.resolveCookieCandidates(
            override: cookieHeaderOverride,
            manualCookieMode: manualCookieMode,
            logger: logger)
        return try await self.fetchUsingCookieCandidates(
            cookieCandidates,
            logger: logger,
            now: now)
    }

    static func shouldRetryWithNextCookieCandidate(after error: Error) -> Bool {
        switch error {
        case OllamaUsageError.invalidCredentials, OllamaUsageError.notLoggedIn:
            true
        case RetryableParseFailure.missingUsageData:
            true
        default:
            false
        }
    }

    private func fetchUsingCookieCandidates(
        _ candidates: [CookieCandidate],
        logger: ((String) -> Void)?,
        now: Date) async throws -> OllamaUsageSnapshot
    {
        do {
            return try await ProviderCandidateRetryRunner.run(
                candidates,
                shouldRetry: { error in
                    Self.shouldRetryWithNextCookieCandidate(after: error)
                },
                onRetry: { candidate, _ in
                    logger?("[ollama] Auth failed for \(candidate.sourceLabel); trying next cookie candidate")
                },
                attempt: { candidate in
                    logger?("[ollama] Using cookies from \(candidate.sourceLabel)")
                    let names = self.cookieNames(from: candidate.cookieHeader)
                    if !names.isEmpty {
                        logger?("[ollama] Cookie names: \(names.joined(separator: ", "))")
                    }

                    let diagnostics = RedirectDiagnostics(cookieHeader: candidate.cookieHeader, logger: logger)
                    do {
                        let (html, responseInfo) = try await self.fetchHTMLWithDiagnostics(
                            cookieHeader: candidate.cookieHeader,
                            diagnostics: diagnostics)
                        if let logger {
                            self.logDiagnostics(responseInfo: responseInfo, diagnostics: diagnostics, logger: logger)
                        }
                        do {
                            return try Self.parseSnapshotForRetry(html: html, now: now)
                        } catch {
                            let surfacedError = Self.surfacedError(from: error)
                            if let logger {
                                logger("[ollama] Parse failed: \(surfacedError.localizedDescription)")
                                self.logHTMLHints(html: html, logger: logger)
                            }
                            throw error
                        }
                    } catch {
                        if let logger {
                            self.logDiagnostics(responseInfo: nil, diagnostics: diagnostics, logger: logger)
                        }
                        throw error
                    }
                })
        } catch ProviderCandidateRetryRunnerError.noCandidates {
            throw OllamaUsageError.noSessionCookie
        } catch {
            throw Self.surfacedError(from: error)
        }
    }

    private static func parseSnapshotForRetry(html: String, now: Date) throws -> OllamaUsageSnapshot {
        switch OllamaUsageParser.parseClassified(html: html, now: now) {
        case let .success(snapshot):
            return snapshot
        case .failure(.notLoggedIn):
            throw OllamaUsageError.notLoggedIn
        case .failure(.missingUsageData):
            throw RetryableParseFailure.missingUsageData
        }
    }

    private static func surfacedError(from error: Error) -> Error {
        switch error {
        case RetryableParseFailure.missingUsageData:
            OllamaUsageError.parseFailed("Missing Ollama usage data.")
        default:
            error
        }
    }

    private func resolveCookieCandidates(
        override: String?,
        manualCookieMode: Bool,
        logger: ((String) -> Void)?) async throws -> [CookieCandidate]
    {
        if let manualHeader = try Self.resolveManualCookieHeader(
            override: override,
            manualCookieMode: manualCookieMode,
            logger: logger)
        {
            return [CookieCandidate(cookieHeader: manualHeader, sourceLabel: "manual cookie header")]
        }
        #if os(macOS)
        let sessions = try OllamaCookieImporter.importSessions(
            browserDetection: self.browserDetection,
            preferredBrowsers: OllamaCookieImporter.defaultPreferredBrowsers,
            allowFallbackBrowsers: OllamaCookieImporter.defaultAllowFallbackBrowsers,
            logger: logger)
        return sessions.map { session in
            CookieCandidate(cookieHeader: session.cookieHeader, sourceLabel: session.sourceLabel)
        }
        #else
        throw OllamaUsageError.noSessionCookie
        #endif
    }

    public func debugRawProbe(
        cookieHeaderOverride: String? = nil,
        manualCookieMode: Bool = false) async -> String
    {
        let stamp = ISO8601DateFormatter().string(from: Date())
        var lines: [String] = []
        lines.append("=== Ollama Debug Probe @ \(stamp) ===")
        lines.append("")

        do {
            let cookieHeader = try await self.resolveCookieHeader(
                override: cookieHeaderOverride,
                manualCookieMode: manualCookieMode,
                logger: { msg in lines.append("[cookie] \(msg)") })
            let diagnostics = RedirectDiagnostics(cookieHeader: cookieHeader, logger: nil)
            let cookieNames = CookieHeaderNormalizer.pairs(from: cookieHeader).map(\.name)
            lines.append("Cookie names: \(cookieNames.joined(separator: ", "))")

            let (snapshot, responseInfo) = try await self.fetchWithDiagnostics(
                cookieHeader: cookieHeader,
                diagnostics: diagnostics)

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
            lines.append("Plan: \(snapshot.planName ?? "unknown")")
            lines.append("Session: \(snapshot.sessionUsedPercent?.description ?? "nil")%")
            lines.append("Weekly: \(snapshot.weeklyUsedPercent?.description ?? "nil")%")
            lines.append("Session resetsAt: \(snapshot.sessionResetsAt?.description ?? "nil")")
            lines.append("Weekly resetsAt: \(snapshot.weeklyResetsAt?.description ?? "nil")")

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
            return result.isEmpty ? "No Ollama probe dumps captured yet." : result
        }
    }

    private func resolveCookieHeader(
        override: String?,
        manualCookieMode: Bool,
        logger: ((String) -> Void)?) async throws -> String
    {
        if let manualHeader = try Self.resolveManualCookieHeader(
            override: override,
            manualCookieMode: manualCookieMode,
            logger: logger)
        {
            return manualHeader
        }
        #if os(macOS)
        let session = try OllamaCookieImporter.importSession(
            browserDetection: self.browserDetection,
            preferredBrowsers: OllamaCookieImporter.defaultPreferredBrowsers,
            allowFallbackBrowsers: OllamaCookieImporter.defaultAllowFallbackBrowsers,
            logger: logger)
        logger?("[ollama] Using cookies from \(session.sourceLabel)")
        return session.cookieHeader
        #else
        throw OllamaUsageError.noSessionCookie
        #endif
    }

    static func resolveManualCookieHeader(
        override: String?,
        manualCookieMode: Bool,
        logger: ((String) -> Void)? = nil) throws -> String?
    {
        if let override = CookieHeaderNormalizer.normalize(override) {
            guard hasRecognizedOllamaSessionCookie(in: override) else {
                logger?("[ollama] Manual cookie header missing recognized session cookie")
                throw OllamaUsageError.noSessionCookie
            }
            logger?("[ollama] Using manual cookie header")
            return override
        }
        if manualCookieMode {
            throw OllamaUsageError.noSessionCookie
        }
        return nil
    }

    private func fetchWithDiagnostics(
        cookieHeader: String,
        diagnostics: RedirectDiagnostics,
        now: Date = Date()) async throws -> (OllamaUsageSnapshot, ResponseInfo)
    {
        let (html, responseInfo) = try await self.fetchHTMLWithDiagnostics(
            cookieHeader: cookieHeader,
            diagnostics: diagnostics)
        let snapshot = try OllamaUsageParser.parse(html: html, now: now)
        return (snapshot, responseInfo)
    }

    private func fetchHTMLWithDiagnostics(
        cookieHeader: String,
        diagnostics: RedirectDiagnostics) async throws -> (String, ResponseInfo)
    {
        var request = URLRequest(url: Self.settingsURL)
        request.httpMethod = "GET"
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue(
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            forHTTPHeaderField: "accept")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
                "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36",
            forHTTPHeaderField: "user-agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "accept-language")
        request.setValue("https://ollama.com", forHTTPHeaderField: "origin")
        request.setValue(Self.settingsURL.absoluteString, forHTTPHeaderField: "referer")

        let session = self.makeURLSession(diagnostics)
        defer { self.finishURLSession(session) }
        let httpResponse = try await session.response(for: request)
        let responseInfo = ResponseInfo(
            statusCode: httpResponse.statusCode,
            url: httpResponse.response.url?.absoluteString ?? "unknown")

        if httpResponse.statusCode == 200, Self.isSignInRedirect(httpResponse.response.url) {
            throw OllamaUsageError.invalidCredentials
        }

        guard httpResponse.statusCode == 200 else {
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw OllamaUsageError.invalidCredentials
            }
            throw OllamaUsageError.networkError("HTTP \(httpResponse.statusCode)")
        }

        let html = String(data: httpResponse.data, encoding: .utf8) ?? ""
        return (html, responseInfo)
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

        init(cookieHeader: String, logger: ((String) -> Void)?) {
            self.cookieHeader = cookieHeader
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
            self.redirects.append("\(response.statusCode) \(from) -> \(to)")
            var updated = request
            if OllamaUsageFetcher.shouldAttachCookie(to: request.url), !self.cookieHeader.isEmpty {
                updated.setValue(self.cookieHeader, forHTTPHeaderField: "Cookie")
            } else {
                updated.setValue(nil, forHTTPHeaderField: "Cookie")
            }
            if let referer = response.url?.absoluteString {
                updated.setValue(referer, forHTTPHeaderField: "referer")
            }
            if let logger {
                logger("[ollama] Redirect \(response.statusCode) \(from) -> \(to)")
            }
            completionHandler(updated)
        }
    }

    private struct ResponseInfo {
        let statusCode: Int
        let url: String
    }

    private func logDiagnostics(
        responseInfo: ResponseInfo?,
        diagnostics: RedirectDiagnostics,
        logger: (String) -> Void)
    {
        if let responseInfo {
            logger("[ollama] Response: \(responseInfo.statusCode) \(responseInfo.url)")
        }
        if !diagnostics.redirects.isEmpty {
            logger("[ollama] Redirects:")
            for entry in diagnostics.redirects {
                logger("[ollama]   \(entry)")
            }
        }
    }

    private func logHTMLHints(html: String, logger: (String) -> Void) {
        logger("[ollama] HTML length: \(html.utf8.count) bytes")
        logger("[ollama] Contains Cloud Usage: \(html.contains("Cloud Usage"))")
        logger("[ollama] Contains Session usage: \(html.contains("Session usage"))")
        logger("[ollama] Contains Hourly usage: \(html.contains("Hourly usage"))")
        logger("[ollama] Contains Weekly usage: \(html.contains("Weekly usage"))")
    }

    private func cookieNames(from header: String) -> [String] {
        header.split(separator: ";", omittingEmptySubsequences: false).compactMap { part in
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            guard let idx = trimmed.firstIndex(of: "=") else { return nil }
            let name = trimmed[..<idx]
            return name.isEmpty ? nil : String(name)
        }
    }

    static func shouldAttachCookie(to url: URL?) -> Bool {
        guard url?.scheme?.lowercased() == "https" else { return false }
        guard let host = url?.host?.lowercased() else { return false }
        if host == "ollama.com" || host == "www.ollama.com" {
            return true
        }
        return host.hasSuffix(".ollama.com")
    }

    static func isSignInRedirect(_ url: URL?) -> Bool {
        guard url?.scheme?.lowercased() == "https" else { return false }
        guard let url, let host = url.host?.lowercased() else { return false }
        let path = url.path.lowercased()
        if host == "ollama.com" || host == "www.ollama.com" {
            return path == "/signin"
        }
        // WorkOS AuthKit ultimately bounces unauthenticated requests to a hosted
        // Ollama sign-in page on the `signin.ollama.com` subdomain; any landing
        // there means the session is expired and the user must sign in again.
        if host == "signin.ollama.com" {
            return true
        }
        // WorkOS AuthKit serves the hosted authorization flow from auth.workos.com
        // (and historically api.workos.com); match any WorkOS host carrying the
        // authorize path so the detection survives host changes or CNAMEs.
        return host.hasSuffix(".workos.com") && path.hasPrefix("/user_management/authorize")
    }
}

public struct OllamaAPISettingsReader: Sendable {
    public static let apiKeyEnvironmentKeys = [
        "OLLAMA_API_KEY",
        "OLLAMA_KEY",
    ]

    public static func apiKey(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        for key in self.apiKeyEnvironmentKeys {
            guard let value = self.cleaned(environment[key]), !value.isEmpty else { continue }
            return value
        }
        return nil
    }

    private static func cleaned(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else {
            return nil
        }
        if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
            (value.hasPrefix("'") && value.hasSuffix("'"))
        {
            value = String(value.dropFirst().dropLast())
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct OllamaAPIUsageSnapshot: Sendable {
    public let modelCount: Int
    public let updatedAt: Date

    public init(modelCount: Int, updatedAt: Date) {
        self.modelCount = modelCount
        self.updatedAt = updatedAt
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        UsageSnapshot(
            primary: nil,
            secondary: nil,
            tertiary: nil,
            providerCost: nil,
            updatedAt: self.updatedAt,
            identity: ProviderIdentitySnapshot(
                providerID: .ollama,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: "API key"))
    }
}

public enum OllamaAPIUsageFetcher {
    public static let tagsURL = URL(string: "https://ollama.com/api/tags")!
    public static let validationURL = URL(string: "https://ollama.com/api/web_search")!
    private static let timeoutSeconds: TimeInterval = 20

    public static func fetchUsage(
        apiKey: String,
        tagsURL: URL = Self.tagsURL,
        validationURL: URL? = nil,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        now: Date = Date()) async throws -> OllamaAPIUsageSnapshot
    {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw OllamaUsageError.missingAPIKey
        }

        let resolvedValidationURL = try self.resolveValidationURL(tagsURL: tagsURL, override: validationURL)
        try await self.validateAPIKey(trimmed, validationURL: resolvedValidationURL, transport: transport)

        var request = URLRequest(url: tagsURL)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.timeoutSeconds
        request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CodexBar/1.0", forHTTPHeaderField: "User-Agent")

        let response: ProviderHTTPResponse
        do {
            response = try await transport.response(for: request)
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled {
                throw CancellationError()
            }
            throw OllamaUsageError.networkError(error.localizedDescription)
        }

        switch response.statusCode {
        case 200:
            return try Self.parseTags(data: response.data, now: now)
        case 401, 403:
            throw OllamaUsageError.apiUnauthorized
        default:
            throw OllamaUsageError.networkError("HTTP \(response.statusCode)")
        }
    }

    private static func validateAPIKey(
        _ apiKey: String,
        validationURL: URL,
        transport: any ProviderHTTPTransport) async throws
    {
        var request = URLRequest(url: validationURL)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.timeoutSeconds
        request.httpBody = Data(#"{"query":""}"#.utf8)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("CodexBar/1.0", forHTTPHeaderField: "User-Agent")

        let response: ProviderHTTPResponse
        do {
            response = try await transport.response(for: request)
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled {
                throw CancellationError()
            }
            throw OllamaUsageError.networkError(error.localizedDescription)
        }

        switch response.statusCode {
        case 200, 400:
            return
        case 401, 403:
            throw OllamaUsageError.apiUnauthorized
        default:
            throw OllamaUsageError.networkError("HTTP \(response.statusCode)")
        }
    }

    private static func resolveValidationURL(tagsURL: URL, override: URL?) throws -> URL {
        let validationURL = override
            ?? (tagsURL == Self.tagsURL
                ? Self.validationURL
                : tagsURL.deletingLastPathComponent().appendingPathComponent("web_search"))
        let endpointValidator = ProviderEndpointOverrideValidator()
        guard endpointValidator.validatedURLAllowingLoopbackHTTP(tagsURL.absoluteString) != nil,
              endpointValidator.validatedURLAllowingLoopbackHTTP(validationURL.absoluteString) != nil
        else {
            throw OllamaUsageError.networkError(
                "Ollama API endpoints must use HTTPS or loopback HTTP.")
        }
        guard self.sameOrigin(tagsURL, validationURL) else {
            throw OllamaUsageError.networkError(
                "Ollama key validation and model catalog endpoints must share an origin.")
        }
        return validationURL
    }

    private static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && self.effectivePort(lhs) == self.effectivePort(rhs)
    }

    private static func effectivePort(_ url: URL) -> Int? {
        if let port = url.port {
            return port
        }
        switch url.scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }

    static func _parseTagsForTesting(_ data: Data, now: Date = Date()) throws -> OllamaAPIUsageSnapshot {
        try self.parseTags(data: data, now: now)
    }

    private static func parseTags(data: Data, now: Date) throws -> OllamaAPIUsageSnapshot {
        do {
            let response = try JSONDecoder().decode(TagsResponse.self, from: data)
            return OllamaAPIUsageSnapshot(modelCount: response.models.count, updatedAt: now)
        } catch {
            throw OllamaUsageError.parseFailed(error.localizedDescription)
        }
    }

    private struct TagsResponse: Decodable {
        let models: [Model]
    }

    private struct Model: Decodable {}
}
