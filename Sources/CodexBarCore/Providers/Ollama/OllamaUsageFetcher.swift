import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if os(macOS)
import SweetCookieKit
#endif

private let ollamaSessionCookieNames: Set<String> = [
    "session",
    "ollama_session",
    "__Host-ollama_session",
    "__Secure-next-auth.session-token",
    "next-auth.session-token",
]

private func isRecognizedOllamaSessionCookieName(_ name: String) -> Bool {
    if ollamaSessionCookieNames.contains(name) { return true }
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
    case notLoggedIn
    case invalidCredentials
    case parseFailed(String)
    case networkError(String)
    case noSessionCookie

    public var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            "Not logged in to Ollama. Please log in via ollama.com/settings."
        case .invalidCredentials:
            "Ollama session cookie expired. Please log in again."
        case let .parseFailed(message):
            "Could not parse Ollama usage: \(message)"
        case let .networkError(message):
            "Ollama request failed: \(message)"
        case .noSessionCookie:
            "No Ollama session cookie found. Please log in to ollama.com in your browser."
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
        let preferredSources = preferredBrowsers.isEmpty
            ? ollamaCookieImportOrder.cookieImportCandidates(using: browserDetection)
            : preferredBrowsers.cookieImportCandidates(using: browserDetection)
        let preferredCandidates = self.collectSessionInfo(from: preferredSources, logger: log)
        return try self.selectSessionInfosWithFallback(
            preferredCandidates: preferredCandidates,
            allowFallbackBrowsers: allowFallbackBrowsers,
            loadFallbackCandidates: {
                guard !preferredBrowsers.isEmpty else { return [] }
                let fallbackSources = self.fallbackBrowserSources(
                    browserDetection: browserDetection,
                    excluding: preferredSources)
                guard !fallbackSources.isEmpty else { return [] }
                log("No recognized Ollama session in preferred browsers; trying fallback import order")
                return self.collectSessionInfo(from: fallbackSources, logger: log)
            },
            logger: log)
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

    private static func fallbackBrowserSources(
        browserDetection: BrowserDetection,
        excluding triedSources: [Browser]) -> [Browser]
    {
        let tried = Set(triedSources)
        return ollamaCookieImportOrder.cookieImportCandidates(using: browserDetection)
            .filter { !tried.contains($0) }
    }

    private static func collectSessionInfo(
        from browserSources: [Browser],
        logger: @escaping (String) -> Void) -> [SessionInfo]
    {
        var candidates: [SessionInfo] = []
        for browserSource in browserSources {
            do {
                let query = BrowserCookieQuery(domains: self.cookieDomains)
                let sources = try Self.cookieClient.records(
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

    private struct CookieCandidate: Sendable {
        let cookieHeader: String
        let sourceLabel: String
    }

    enum RetryableParseFailure: Error, Sendable {
        case missingUsageData
    }

    public let browserDetection: BrowserDetection
    private let makeURLSession: @Sendable (URLSessionTaskDelegate?) -> URLSession

    public init(browserDetection: BrowserDetection) {
        self.browserDetection = browserDetection
        self.makeURLSession = { delegate in
            URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        }
    }

    init(
        browserDetection: BrowserDetection,
        makeURLSession: @escaping @Sendable (URLSessionTaskDelegate?) -> URLSession)
    {
        self.browserDetection = browserDetection
        self.makeURLSession = makeURLSession
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
        let sessions = try OllamaCookieImporter.importSessions(browserDetection: self.browserDetection, logger: logger)
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
        let session = try OllamaCookieImporter.importSession(browserDetection: self.browserDetection, logger: logger)
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
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OllamaUsageError.networkError("Invalid response")
        }
        let responseInfo = ResponseInfo(
            statusCode: httpResponse.statusCode,
            url: httpResponse.url?.absoluteString ?? "unknown")

        guard httpResponse.statusCode == 200 else {
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw OllamaUsageError.invalidCredentials
            }
            throw OllamaUsageError.networkError("HTTP \(httpResponse.statusCode)")
        }

        let html = String(data: data, encoding: .utf8) ?? ""
        return (html, responseInfo)
    }

    @MainActor private static func recordDump(_ text: String) {
        if self.recentDumps.count >= 5 { self.recentDumps.removeFirst() }
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

    private struct ResponseInfo: Sendable {
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
        guard let host = url?.host?.lowercased() else { return false }
        if host == "ollama.com" || host == "www.ollama.com" { return true }
        return host.hasSuffix(".ollama.com")
    }
}
