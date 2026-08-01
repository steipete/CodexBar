import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if os(macOS)
import SweetCookieKit
#endif

#if os(macOS)
private let notionCookieImportOrder: BrowserCookieImportOrder =
    ProviderDefaults.metadata[.notion]?.browserCookieOrder ?? Browser.defaultImportOrder

public enum NotionCookieImporter {
    private static let cookieClient = BrowserCookieClient()
    /// The app moved to `app.notion.com`; `notion.so` is kept for sessions that predate the move.
    private static let cookieDomains = [
        "app.notion.com",
        "www.notion.com",
        "notion.com",
        "www.notion.so",
        "notion.so",
    ]

    public struct SessionInfo: Sendable {
        public let cookieHeader: String
        public let sourceLabel: String

        public init(cookieHeader: String, sourceLabel: String) {
            self.cookieHeader = cookieHeader
            self.sourceLabel = sourceLabel
        }
    }

    public static func importSession(
        browserDetection: BrowserDetection,
        logger: ((String) -> Void)? = nil) throws -> SessionInfo
    {
        let log: (String) -> Void = { msg in logger?("[notion-cookie] \(msg)") }
        let installed = notionCookieImportOrder.cookieImportCandidates(using: browserDetection)

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
                    // `token_v2` is the session cookie; without it the API answers 401 for every call.
                    guard cookies.contains(where: { $0.name == NotionUsageFetcher.sessionCookieName }) else {
                        log("\(source.label) has Notion cookies but no session cookie")
                        continue
                    }
                    let names = cookies.map(\.name).joined(separator: ", ")
                    log("\(source.label) cookies: \(names)")
                    let header = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
                    return SessionInfo(cookieHeader: header, sourceLabel: source.label)
                }
            } catch {
                BrowserCookieAccessGate.recordIfNeeded(error)
                log("\(browserSource.displayName) cookie import failed: \(error.localizedDescription)")
            }
        }

        throw NotionUsageError.noSessionCookie
    }
}
#endif

public struct NotionUsageFetcher: Sendable {
    private static let log = CodexBarLog.logger(LogCategories.notion)
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
        "x-notion-space-id": "x-notion-space-id",
    ]

    public struct RequestContext: Sendable {
        public let cookieHeader: String
        public let headers: [String: String]

        public init(cookieHeader: String, headers: [String: String] = [:]) {
            self.cookieHeader = cookieHeader
            self.headers = headers
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
        let context = try self.resolveRequestContext(override: cookieHeaderOverride, logger: log)
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
            log("Using workspace \(workspace.name ?? workspace.id) (\(workspace.id))")
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
        guard let normalized = CookieHeaderNormalizer.normalize(cookieHeader) else {
            throw NotionUsageError.noSessionCookie
        }
        return try await self.fetchUsage(
            context: RequestContext(cookieHeader: normalized),
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
        guard CookieHeaderNormalizer.normalize(context.cookieHeader) != nil else {
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
        guard let normalizedCookieHeader = CookieHeaderNormalizer.normalize(context.cookieHeader) else {
            throw NotionUsageError.noSessionCookie
        }
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
        request.setValue(normalizedCookieHeader, forHTTPHeaderField: "Cookie")

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

    private func resolveRequestContext(
        override: String?,
        logger: ((String) -> Void)?) throws -> RequestContext
    {
        if let override = Self.requestContext(from: override) {
            let source = override.headers.isEmpty ? "manual cookie header" : "manual cURL capture"
            logger?("[notion] Using \(source)")
            return override
        }

        #if os(macOS)
        let session = try NotionCookieImporter.importSession(
            browserDetection: self.browserDetection,
            logger: logger)
        logger?("[notion] Using cookies from \(session.sourceLabel)")
        return RequestContext(cookieHeader: session.cookieHeader)
        #else
        throw NotionUsageError.noSessionCookie
        #endif
    }

    static func requestContext(from raw: String?) -> RequestContext? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let headerFields = CurlCaptureParser.headerFields(from: raw)
        guard let cookieHeader = Self.cookieHeader(from: headerFields) ?? CookieHeaderNormalizer.normalize(raw) else {
            return nil
        }
        let headers = CurlCaptureParser.forwardedHeaders(from: headerFields, allowlist: self.forwardedManualHeaders)
        return RequestContext(cookieHeader: cookieHeader, headers: headers)
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

    private static func cookieHeader(from fields: [String]) -> String? {
        guard let raw = CurlCaptureParser.headerValue(named: "Cookie", in: fields) else { return nil }
        return CookieHeaderNormalizer.normalize(raw)
    }
}
