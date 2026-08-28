import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if os(macOS)
import SweetCookieKit
#endif

#if os(macOS)
public enum NotionCookieImporter {
    private static let importSessionCacheTTL: TimeInterval = 5
    private static let importSessionCache = ImportSessionCache(ttl: importSessionCacheTTL)
    private static let cookieClient = BrowserCookieClient()
    private static let cookieImportOrder: BrowserCookieImportOrder =
        ProviderDefaults.metadata[.notion]?.browserCookieOrder ?? Browser.defaultImportOrder
    /// The app moved to `app.notion.com`; `notion.so` is kept for sessions that predate the move.
    private static let cookieDomains = [
        "app.notion.com",
        "www.notion.com",
        "notion.com",
        "www.notion.so",
        "notion.so",
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

        var tokenV2: String? {
            self.cookies.first(where: { $0.name == NotionUsageFetcher.sessionCookieName })?.value
        }
    }

    public static func importSession(
        browserDetection: BrowserDetection,
        browserOrder: BrowserCookieImportOrder? = nil,
        logger: ((String) -> Void)? = nil) throws -> SessionInfo
    {
        let log: (String) -> Void = { msg in logger?("[notion-cookie] \(msg)") }
        let now = Date()
        // Reading cookie stores touches browser Safe Storage; a short TTL keeps the polling refresh
        // from doing that on every tick.
        if let cached = self.importSessionCache.load(now: now) {
            return cached
        }
        let importOrder = browserOrder ?? self.cookieImportOrder
        let installed = importOrder.cookieImportCandidates(using: browserDetection)
        // `cookieImportCandidates` drops Chromium browsers on anything but a user-initiated refresh,
        // to avoid a Keychain prompt. Saying "log in" there would be wrong — the session is fine, it
        // just cannot be read yet.
        if installed.isEmpty, !importOrder.browsersWithProfileData(using: browserDetection).isEmpty {
            throw NotionUsageError.cookieImportDeferred
        }

        for browserSource in installed {
            do {
                let query = BrowserCookieQuery(domains: self.cookieDomains)
                let sources = try self.cookieClient.codexBarRecords(
                    matching: query,
                    in: browserSource,
                    logger: log)
                for source in sources where !source.records.isEmpty {
                    let cookies = BrowserCookieClient.makeHTTPCookies(source.records, origin: query.origin)
                    guard !cookies.isEmpty else { continue }
                    let deduped = self.deduplicatedByName(cookies)
                    // `token_v2` is the session cookie; without it the API answers 401 for every call.
                    guard deduped.contains(where: { $0.name == NotionUsageFetcher.sessionCookieName }) else {
                        log("\(source.label) has Notion cookies but no session cookie")
                        continue
                    }
                    let names = deduped.map(\.name).joined(separator: ", ")
                    log("\(source.label) cookies: \(names)")
                    let session = SessionInfo(cookies: deduped, sourceLabel: source.label)
                    self.importSessionCache.store(session, now: now)
                    return session
                }
            } catch {
                BrowserCookieAccessGate.recordIfNeeded(error)
                log("\(browserSource.displayName) cookie import failed: \(error.localizedDescription)")
            }
        }

        throw NotionUsageError.noSessionCookie
    }

    /// A profile can hold the same cookie on several Notion domains — most often a stale `token_v2`
    /// left on the legacy `notion.so` alongside the live one. Emitting both puts two `token_v2`
    /// pairs in one header and the server picks arbitrarily, so keep the most specific domain's.
    static func deduplicatedByName(_ cookies: [HTTPCookie]) -> [HTTPCookie] {
        var best: [String: (rank: Int, cookie: HTTPCookie)] = [:]
        for cookie in cookies {
            let host = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
            let rank = self.cookieDomains.firstIndex(of: host.lowercased()) ?? self.cookieDomains.count
            if let existing = best[cookie.name], existing.rank <= rank {
                continue
            }
            best[cookie.name] = (rank, cookie)
        }
        return best.keys.sorted().compactMap { best[$0]?.cookie }
    }

    private final class ImportSessionCache: @unchecked Sendable {
        private let ttl: TimeInterval
        private let lock = NSLock()
        private var entry: (session: SessionInfo, expiresAt: Date)?

        init(ttl: TimeInterval) {
            self.ttl = ttl
        }

        func load(now: Date) -> SessionInfo? {
            self.lock.lock()
            defer { self.lock.unlock() }
            guard let entry = self.entry, entry.expiresAt > now else {
                self.entry = nil
                return nil
            }
            return entry.session
        }

        func store(_ session: SessionInfo, now: Date) {
            self.lock.lock()
            self.entry = (session, now.addingTimeInterval(self.ttl))
            self.lock.unlock()
        }
    }
}
#endif

public struct NotionUsageFetcher: Sendable {
    private static let log = CodexBarLog.logger(LogCategories.provider(.notion))
    static let sessionCookieName = "token_v2"
    private static let baseURL = URL(string: "https://app.notion.com")!
    private static let refererURL = URL(string: "https://app.notion.com/")!
    /// Browser fingerprint defaults are only fallbacks; full cURL captures override these forwarded headers.
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
        "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"
    private static let forwardedManualHeaders = [
        "accept": "Accept",
        "accept-language": "Accept-Language",
        "notion-audit-log-platform": "notion-audit-log-platform",
        "notion-client-version": "notion-client-version",
        "referer": "Referer",
        "sec-fetch-dest": "Sec-Fetch-Dest",
        "sec-fetch-mode": "Sec-Fetch-Mode",
        "sec-fetch-site": "Sec-Fetch-Site",
        "user-agent": "User-Agent",
        "x-notion-active-user-header": "x-notion-active-user-header",
        // `x-notion-space-id` is deliberately not forwarded: a capture taken in one workspace would
        // pin that space while the request body asks for the configured one, and the mismatch would
        // surface as another workspace's usage rather than an error.
    ]

    public struct RequestContext: Sendable {
        /// Normalized at construction so each request can use it as-is. Empty means unusable.
        public let cookieHeader: String
        public let headers: [String: String]

        public init(cookieHeader: String, headers: [String: String] = [:]) {
            self.cookieHeader = CookieHeaderNormalizer.normalize(cookieHeader) ?? ""
            self.headers = headers
        }

        var isUsable: Bool {
            !self.cookieHeader.isEmpty
        }
    }

    public let browserDetection: BrowserDetection

    public init(browserDetection: BrowserDetection) {
        self.browserDetection = browserDetection
    }

    public func fetch(
        cookieHeaderOverride: String? = nil,
        preferredSpaceID: String? = nil,
        timeout: TimeInterval = 15,
        logger: ((String) -> Void)? = nil,
        now: Date = Date(),
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared) async throws -> NotionUsageSnapshot
    {
        let log: (String) -> Void = { msg in logger?("[notion] \(msg)") }
        let options = FetchOptions(
            preferredSpaceID: preferredSpaceID,
            timeout: timeout,
            logger: logger,
            now: now,
            transport: transport)

        if let override = Self.requestContext(from: cookieHeaderOverride) {
            log("Using \(override.headers.isEmpty ? "manual cookie header" : "manual cURL capture")")
            return try await self.runFetch(context: override, options: options)
        }

        #if os(macOS)
        // Chromium cookie imports only run on a user-initiated refresh, so a timer tick has no way
        // to read the browser store. Reusing the header cached by the last successful import is what
        // keeps background refreshes working instead of reporting "no cookies found".
        if let cached = CookieHeaderCache.load(provider: .notion),
           !cached.cookieHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            log("Using cached cookie header from \(cached.sourceLabel)")
            do {
                return try await self.runFetch(
                    context: RequestContext(cookieHeader: cached.cookieHeader),
                    options: options)
            } catch NotionUsageError.invalidCredentials {
                CookieHeaderCache.clear(provider: .notion)
                await NotionSessionStore.shared.clearSession()
                log("Cached session was rejected; cleared persisted copies and retrying with a fresh import")
            }
        }

        if ProviderInteractionContext.current != .userInitiated,
           let stored = await NotionSessionStore.shared.getSession()
        {
            log("Using stored session from \(stored.sourceLabel)")
            do {
                return try await self.runFetch(
                    context: RequestContext(cookieHeader: stored.cookieHeader),
                    options: options)
            } catch NotionUsageError.invalidCredentials {
                await NotionSessionStore.shared.clearSession()
                log("Stored session was rejected; cleared it and retrying with a fresh import")
            }
        }

        let session = try NotionCookieImporter.importSession(
            browserDetection: self.browserDetection,
            logger: logger)
        log("Using cookies from \(session.sourceLabel)")
        let snapshot = try await self.runFetch(
            context: RequestContext(cookieHeader: session.cookieHeader),
            options: options)
        if let tokenV2 = session.tokenV2 {
            await NotionSessionStore.shared.setSession(tokenV2: tokenV2, sourceLabel: session.sourceLabel)
        }
        CookieHeaderCache.store(
            provider: .notion,
            cookieHeader: session.cookieHeader,
            sourceLabel: session.sourceLabel)
        return snapshot
        #else
        throw NotionUsageError.noSessionCookie
        #endif
    }

    /// The per-call inputs that stay the same across every attempt a single `fetch` makes.
    private struct FetchOptions {
        let preferredSpaceID: String?
        let timeout: TimeInterval
        let logger: ((String) -> Void)?
        let now: Date
        let transport: any ProviderHTTPTransport
    }

    private func runFetch(
        context: RequestContext,
        options: FetchOptions) async throws -> NotionUsageSnapshot
    {
        let (preferredSpaceID, timeout, logger, now, transport) =
            (options.preferredSpaceID, options.timeout, options.logger, options.now, options.transport)
        if let logger {
            let names = CookieHeaderNormalizer.pairs(from: context.cookieHeader).map(\.name)
            if !names.isEmpty {
                logger("[notion] Cookie names: \(names.joined(separator: ", "))")
            }
            if !context.headers.isEmpty {
                let headerNames = context.headers.keys.sorted().joined(separator: ", ")
                logger("[notion] Forwarding captured headers: \(headerNames)")
            }
        }
        let snapshot = try await Self.fetchUsage(
            context: context,
            preferredSpaceID: preferredSpaceID,
            timeout: timeout,
            now: now,
            transport: transport)
        if let workspace = snapshot.workspace {
            logger?("[notion] Using workspace \(workspace.name ?? workspace.id) (\(workspace.id))")
        }
        return snapshot
    }

    public func debugRawProbe(
        cookieHeaderOverride: String? = nil,
        preferredSpaceID: String? = nil) async -> String
    {
        let stamp = ISO8601DateFormatter().string(from: Date())
        var lines: [String] = []
        lines.append("=== Notion Debug Probe @ \(stamp) ===")
        lines.append("")

        do {
            let snapshot = try await self.fetch(
                cookieHeaderOverride: cookieHeaderOverride,
                preferredSpaceID: preferredSpaceID,
                logger: { msg in lines.append(msg) })
            lines.append("")
            lines.append("Fetch Success")
            lines.append("workspace=\(snapshot.workspace?.name ?? "nil")")
            lines.append("tier=\(snapshot.workspace?.subscriptionTier ?? "nil")")
            lines.append("status=\(snapshot.rateLimit.status ?? "nil")")
            lines.append("enforcement=\(snapshot.rateLimit.enforcement ?? "nil")")
            lines.append("rollingWindow=\(snapshot.rateLimit.window?.window ?? "nil")")
            lines.append("rollingUsed=\(snapshot.rateLimit.window?.used?.description ?? "nil")")
            lines.append("rollingLimit=\(snapshot.rateLimit.window?.limit?.description ?? "nil")")
            lines.append("resetsInSeconds=\(snapshot.rateLimit.resetsInSeconds?.description ?? "nil")")
            lines.append("billingUsed=\(snapshot.rateLimit.billingPeriodWindow?.used?.description ?? "nil")")
            lines.append("billingLimit=\(snapshot.rateLimit.billingPeriodWindow?.limit?.description ?? "nil")")
            lines.append("periodEndMs=\(snapshot.rateLimit.billingPeriodWindow?.periodEndMs?.description ?? "nil")")
        } catch {
            lines.append("")
            lines.append("Probe Failed: \(error.localizedDescription)")
        }

        return lines.joined(separator: "\n")
    }

    public static func fetchUsage(
        cookieHeader: String,
        preferredSpaceID: String? = nil,
        timeout: TimeInterval = 15,
        now: Date = Date(),
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared) async throws -> NotionUsageSnapshot
    {
        try await self.fetchUsage(
            context: RequestContext(cookieHeader: cookieHeader),
            preferredSpaceID: preferredSpaceID,
            timeout: timeout,
            now: now,
            transport: transport)
    }

    static func fetchUsage(
        context: RequestContext,
        preferredSpaceID: String?,
        timeout: TimeInterval,
        now: Date,
        transport: any ProviderHTTPTransport) async throws -> NotionUsageSnapshot
    {
        guard context.isUsable else {
            throw NotionUsageError.noSessionCookie
        }

        let account = try await self.fetchAccount(context: context, timeout: timeout, transport: transport)
        guard let workspace = account.resolveWorkspace(preferredID: preferredSpaceID) else {
            throw NotionUsageError.noWorkspace
        }

        let data = try await self.post(
            endpoint: "getCreditRateLimitStatus",
            body: ["spaceId": workspace.id],
            context: context,
            timeout: timeout,
            transport: transport)
        let status = try NotionUsageParser.parseRateLimitStatus(data)

        guard !status.isNotApplicable else {
            throw NotionUsageError.allowanceNotApplicable(workspace: workspace.name)
        }

        return NotionUsageSnapshot(
            rateLimit: status,
            workspace: workspace,
            account: account,
            updatedAt: now)
    }

    static func fetchAccount(
        context: RequestContext,
        timeout: TimeInterval,
        transport: any ProviderHTTPTransport) async throws -> NotionAccount
    {
        let data = try await self.post(
            endpoint: "getSpaces",
            body: [:],
            context: context,
            timeout: timeout,
            transport: transport)
        return try NotionUsageParser.parseSpaces(data)
    }

    private static func post(
        endpoint: String,
        body: [String: String],
        context: RequestContext,
        timeout: TimeInterval,
        transport: any ProviderHTTPTransport) async throws -> Data
    {
        guard let url = URL(string: "/api/v3/\(endpoint)", relativeTo: self.baseURL) else {
            throw NotionUsageError.apiError("Failed to build \(endpoint) URL.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        self.applyDefaultHeaders(to: &request)
        for (name, value) in context.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue(self.baseURL.absoluteString, forHTTPHeaderField: "Origin")
        request.setValue(context.cookieHeader, forHTTPHeaderField: "Cookie")

        let response = try await transport.response(for: request)
        guard response.statusCode == 200 else {
            let preview = String(data: response.data.prefix(200), encoding: .utf8) ?? "<binary>"
            Self.log.error("Notion \(endpoint) returned \(response.statusCode): \(preview)")
            if response.statusCode == 401 {
                throw NotionUsageError.invalidCredentials
            }
            throw NotionUsageError.apiError("HTTP \(response.statusCode) from \(endpoint)")
        }
        return response.data
    }

    static func requestContext(from raw: String?) -> RequestContext? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let headerFields = CurlCaptureParser.headerFields(from: raw)
        let headers = CurlCaptureParser.forwardedHeaders(from: headerFields, allowlist: self.forwardedManualHeaders)
        guard let normalized = CookieHeaderNormalizer.normalize(
            CurlCaptureParser.headerValue(named: "Cookie", in: headerFields) ?? raw)
        else { return nil }
        let cookieHeader = CookieHeaderNormalizer.pairs(from: normalized).isEmpty
            ? "\(self.sessionCookieName)=\(normalized)"
            : normalized
        let context = RequestContext(
            cookieHeader: cookieHeader,
            headers: headers)
        return context.isUsable ? context : nil
    }

    private static func applyDefaultHeaders(to request: inout URLRequest) {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue(self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(self.refererURL.absoluteString, forHTTPHeaderField: "Referer")
        request.setValue("empty", forHTTPHeaderField: "Sec-Fetch-Dest")
        request.setValue("cors", forHTTPHeaderField: "Sec-Fetch-Mode")
        request.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
    }
}
