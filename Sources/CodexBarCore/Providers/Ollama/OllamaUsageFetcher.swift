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

    public static func importSession(
        browserDetection: BrowserDetection,
        preferredBrowsers: [Browser] = [.chrome],
        logger: ((String) -> Void)? = nil) throws -> SessionInfo
    {
        let log: (String) -> Void = { msg in logger?("[ollama-cookie] \(msg)") }
        let installed = preferredBrowsers.isEmpty
            ? ollamaCookieImportOrder.cookieImportCandidates(using: browserDetection)
            : preferredBrowsers.cookieImportCandidates(using: browserDetection)
        var candidates: [SessionInfo] = []

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
                    candidates.append(SessionInfo(cookies: cookies, sourceLabel: source.label))
                }
            } catch {
                BrowserCookieAccessGate.recordIfNeeded(error)
                log("\(browserSource.displayName) cookie import failed: \(error.localizedDescription)")
            }
        }

        return try self.selectSessionInfo(from: candidates, logger: log)
    }

    static func selectSessionInfo(
        from candidates: [SessionInfo],
        logger: ((String) -> Void)? = nil) throws -> SessionInfo
    {
        for candidate in candidates {
            let names = candidate.cookies.map(\.name).joined(separator: ", ")
            logger?("\(candidate.sourceLabel) cookies: \(names)")
            if self.containsRecognizedSessionCookie(in: candidate.cookies) {
                logger?("Found Ollama session cookie in \(candidate.sourceLabel)")
                return candidate
            }
            logger?("\(candidate.sourceLabel) cookies found, but no recognized session cookie present")
        }
        throw OllamaUsageError.noSessionCookie
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

    public let browserDetection: BrowserDetection

    public init(browserDetection: BrowserDetection) {
        self.browserDetection = browserDetection
    }

    public func fetch(
        cookieHeaderOverride: String? = nil,
        manualCookieMode: Bool = false,
        logger: ((String) -> Void)? = nil,
        now: Date = Date()) async throws -> OllamaUsageSnapshot
    {
        let log: (String) -> Void = { msg in logger?("[ollama] \(msg)") }
        let cookieHeader = try await self.resolveCookieHeader(
            override: cookieHeaderOverride,
            manualCookieMode: manualCookieMode,
            logger: log)

        if let logger {
            let names = self.cookieNames(from: cookieHeader)
            if !names.isEmpty {
                logger("[ollama] Cookie names: \(names.joined(separator: ", "))")
            }
            let diagnostics = RedirectDiagnostics(cookieHeader: cookieHeader, logger: logger)
            do {
                let (html, responseInfo) = try await self.fetchHTMLWithDiagnostics(
                    cookieHeader: cookieHeader,
                    diagnostics: diagnostics)
                self.logDiagnostics(responseInfo: responseInfo, diagnostics: diagnostics, logger: logger)
                do {
                    return try OllamaUsageParser.parse(html: html, now: now)
                } catch {
                    logger("[ollama] Parse failed: \(error.localizedDescription)")
                    self.logHTMLHints(html: html, logger: logger)
                    throw error
                }
            } catch {
                self.logDiagnostics(responseInfo: nil, diagnostics: diagnostics, logger: logger)
                throw error
            }
        }

        let diagnostics = RedirectDiagnostics(cookieHeader: cookieHeader, logger: nil)
        let (html, _) = try await self.fetchHTMLWithDiagnostics(
            cookieHeader: cookieHeader,
            diagnostics: diagnostics)
        return try OllamaUsageParser.parse(html: html, now: now)
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

        let session = URLSession(configuration: .ephemeral, delegate: diagnostics, delegateQueue: nil)
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
        let trimmed = html
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let snippet = trimmed.prefix(240)
            logger("[ollama] HTML snippet: \(snippet)")
        }
        logger("[ollama] Contains Cloud Usage: \(html.contains("Cloud Usage"))")
        logger("[ollama] Contains Session usage: \(html.contains("Session usage"))")
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
