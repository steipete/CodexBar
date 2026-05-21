import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if os(macOS)
import SweetCookieKit
#endif

#if os(macOS)
private let t3ChatCookieImportOrder: BrowserCookieImportOrder =
    ProviderDefaults.metadata[.t3chat]?.browserCookieOrder ?? Browser.defaultImportOrder

public enum T3ChatCookieImporter {
    private static let cookieClient = BrowserCookieClient()
    private static let cookieDomains = ["t3.chat", "www.t3.chat"]

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
        let log: (String) -> Void = { msg in logger?("[t3chat-cookie] \(msg)") }
        let installed = t3ChatCookieImportOrder.cookieImportCandidates(using: browserDetection)

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

        throw T3ChatUsageError.noSessionCookie
    }
}
#endif

public struct T3ChatUsageFetcher: Sendable {
    private static let log = CodexBarLog.logger(LogCategories.t3chat)
    private static let baseURL = URL(string: "https://t3.chat")!
    private static let refererURL = URL(string: "https://t3.chat/settings/customization")!
    /// Browser fingerprint defaults are only fallbacks; full cURL captures override these forwarded headers.
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
        "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"
    /// Captured from T3 Chat's getCustomerData tRPC request shape in May 2026.
    private static let input = #"{"0":{"json":{"sessionId":null},"meta":{"values":{"sessionId":["undefined"]}}}}"#
    private static let forwardedManualHeaders = [
        "accept": "Accept",
        "accept-language": "Accept-Language",
        "cache-control": "Cache-Control",
        "pragma": "Pragma",
        "priority": "Priority",
        "referer": "Referer",
        "sec-fetch-dest": "Sec-Fetch-Dest",
        "sec-fetch-mode": "Sec-Fetch-Mode",
        "sec-fetch-site": "Sec-Fetch-Site",
        "trpc-accept": "trpc-accept",
        "user-agent": "User-Agent",
        "x-client-context": "x-client-context",
        "x-deployment-id": "X-Deployment-Id",
        "x-trpc-batch": "x-trpc-batch",
        "x-trpc-source": "x-trpc-source",
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
        timeout: TimeInterval = 15,
        logger: ((String) -> Void)? = nil,
        now: Date = Date(),
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared) async throws -> T3ChatUsageSnapshot
    {
        let log: (String) -> Void = { msg in logger?("[t3chat] \(msg)") }
        let context = try await self.resolveRequestContext(override: cookieHeaderOverride, logger: log)
        if let logger {
            let names = CookieHeaderNormalizer.pairs(from: context.cookieHeader).map(\.name)
            if !names.isEmpty {
                logger("[t3chat] Cookie names: \(names.joined(separator: ", "))")
            }
            if !context.headers.isEmpty {
                let headerNames = context.headers.keys.sorted().joined(separator: ", ")
                logger("[t3chat] Forwarding captured headers: \(headerNames)")
            }
        }
        return try await Self.fetchCustomerData(
            context: context,
            timeout: timeout,
            now: now,
            transport: transport)
    }

    public func debugRawProbe(cookieHeaderOverride: String? = nil) async -> String {
        let stamp = ISO8601DateFormatter().string(from: Date())
        var lines: [String] = []
        lines.append("=== T3 Chat Debug Probe @ \(stamp) ===")
        lines.append("")

        do {
            let snapshot = try await self.fetch(
                cookieHeaderOverride: cookieHeaderOverride,
                logger: { msg in lines.append(msg) })
            lines.append("")
            lines.append("Fetch Success")
            lines.append("subTier=\(snapshot.customerData.subTier ?? "nil")")
            lines.append("usageBand=\(snapshot.customerData.usageBand ?? "nil")")
            lines
                .append(
                    "usageFourHourPercentage=\(snapshot.customerData.usageFourHourPercentage?.description ?? "nil")")
            lines.append("usageMonthPercentage=\(snapshot.customerData.usageMonthPercentage?.description ?? "nil")")
            lines.append("usagePeriodPercentage=\(snapshot.customerData.usagePeriodPercentage?.description ?? "nil")")
            lines
                .append(
                    "usageFourHourNextResetAt=\(snapshot.customerData.usageFourHourNextResetAt?.description ?? "nil")")
            lines.append("billingNextResetAt=\(snapshot.customerData.billingNextResetAt?.description ?? "nil")")
        } catch {
            lines.append("")
            lines.append("Probe Failed: \(error.localizedDescription)")
        }

        return lines.joined(separator: "\n")
    }

    public static func fetchCustomerData(
        cookieHeader: String,
        timeout: TimeInterval = 15,
        now: Date = Date(),
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared) async throws -> T3ChatUsageSnapshot
    {
        guard let normalizedCookieHeader = CookieHeaderNormalizer.normalize(cookieHeader) else {
            throw T3ChatUsageError.noSessionCookie
        }
        return try await self.fetchCustomerData(
            context: RequestContext(cookieHeader: normalizedCookieHeader),
            timeout: timeout,
            now: now,
            transport: transport)
    }

    public static func fetchCustomerData(
        context: RequestContext,
        timeout: TimeInterval = 15,
        now: Date = Date(),
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared) async throws -> T3ChatUsageSnapshot
    {
        guard let normalizedCookieHeader = CookieHeaderNormalizer.normalize(context.cookieHeader) else {
            throw T3ChatUsageError.noSessionCookie
        }

        let url = try self.customerDataURL()
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        self.applyDefaultHeaders(to: &request)
        for (name, value) in context.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue(self.baseURL.absoluteString, forHTTPHeaderField: "Origin")
        request.setValue(normalizedCookieHeader, forHTTPHeaderField: "Cookie")

        let response = try await transport.response(for: request)
        let data = response.data
        guard response.statusCode == 200 else {
            let body = String(data: data.prefix(200), encoding: .utf8) ?? "<binary>"
            Self.log.error("T3 Chat API returned \(response.statusCode): \(body)")
            if response.statusCode == 401 || response.statusCode == 403 {
                throw T3ChatUsageError.invalidCredentials
            }
            if response.statusCode == 429,
               response.response.value(forHTTPHeaderField: "x-vercel-mitigated") == "challenge"
            {
                throw T3ChatUsageError.vercelChallenge
            }
            throw T3ChatUsageError.apiError("HTTP \(response.statusCode)")
        }

        do {
            return try T3ChatUsageParser.parseJSONLines(data, now: now)
        } catch {
            let preview = String(data: data.prefix(500), encoding: .utf8) ?? "<binary>"
            Self.log.error("T3 Chat parse failed: \(error.localizedDescription) response=\(preview)")
            throw error
        }
    }

    private func resolveRequestContext(
        override: String?,
        logger: ((String) -> Void)?) async throws -> RequestContext
    {
        if let override = self.requestContext(from: override) {
            let source = override.headers.isEmpty ? "manual cookie header" : "manual cURL capture"
            logger?("[t3chat] Using \(source)")
            return override
        }

        #if os(macOS)
        let session = try T3ChatCookieImporter.importSession(
            browserDetection: self.browserDetection,
            logger: logger)
        logger?("[t3chat] Using cookies from \(session.sourceLabel)")
        return RequestContext(cookieHeader: session.cookieHeader)
        #else
        throw T3ChatUsageError.noSessionCookie
        #endif
    }

    private func requestContext(from raw: String?) -> RequestContext? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let headerFields = Self.headerFields(from: raw)
        guard let cookieHeader = Self.cookieHeader(from: headerFields) ?? CookieHeaderNormalizer.normalize(raw) else {
            return nil
        }
        let headers = Self.forwardedHeaders(from: headerFields)
        return RequestContext(cookieHeader: cookieHeader, headers: headers)
    }

    private static func applyDefaultHeaders(to request: inout URLRequest) {
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("application/jsonl", forHTTPHeaderField: "trpc-accept")
        request.setValue("web-client", forHTTPHeaderField: "x-trpc-source")
        request.setValue("true", forHTTPHeaderField: "x-trpc-batch")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue(self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(self.refererURL.absoluteString, forHTTPHeaderField: "Referer")
        request.setValue("empty", forHTTPHeaderField: "Sec-Fetch-Dest")
        request.setValue("cors", forHTTPHeaderField: "Sec-Fetch-Mode")
        request.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
        request.setValue("u=4", forHTTPHeaderField: "Priority")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
    }

    private static func forwardedHeaders(from fields: [String]) -> [String: String] {
        var headers: [String: String] = [:]
        for field in fields {
            guard let colon = field.firstIndex(of: ":") else { continue }
            let rawName = field[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = field[field.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawName.isEmpty, !value.isEmpty else { continue }
            guard let canonical = self.forwardedManualHeaders[rawName.lowercased()] else { continue }
            headers[canonical] = value
        }
        return headers
    }

    private static func cookieHeader(from fields: [String]) -> String? {
        for field in fields {
            guard let colon = field.firstIndex(of: ":") else { continue }
            let rawName = field[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
            guard rawName.caseInsensitiveCompare("Cookie") == .orderedSame else { continue }
            let value = field[field.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if let normalized = CookieHeaderNormalizer.normalize(String(value)) {
                return normalized
            }
        }
        return nil
    }

    private static func headerFields(from raw: String) -> [String] {
        var fields: [String] = []
        let pattern =
            #"(?s)(?:^|\s)(?:-H|--header)(?:\s+|=|(?=['"$]))"# +
            #"(?:\$'((?:\\.|[^'])*)'|'([^']*)'|"((?:\\.|[^"])*)"|(\S+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return fields }
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        for match in regex.matches(in: raw, options: [], range: range) {
            if let ansi = self.capture(1, in: match, raw: raw) {
                fields.append(self.unescapeShellSegment(ansi, ansi: true))
            } else if let single = self.capture(2, in: match, raw: raw) {
                fields.append(single)
            } else if let double = self.capture(3, in: match, raw: raw) {
                fields.append(self.unescapeShellSegment(double, ansi: false))
            } else if let bare = self.capture(4, in: match, raw: raw) {
                fields.append(self.unescapeShellSegment(bare, ansi: false))
            }
        }
        return fields
    }

    private static func capture(_ index: Int, in match: NSTextCheckingResult, raw: String) -> String? {
        guard match.numberOfRanges > index,
              let range = Range(match.range(at: index), in: raw)
        else {
            return nil
        }
        return String(raw[range])
    }

    private static func unescapeShellSegment(_ raw: String, ansi: Bool) -> String {
        var output = ""
        var index = raw.startIndex
        while index < raw.endIndex {
            guard raw[index] == "\\" else {
                output.append(raw[index])
                index = raw.index(after: index)
                continue
            }
            let next = raw.index(after: index)
            guard next < raw.endIndex else { return output }
            switch raw[next] {
            case "n" where ansi:
                output.append("\n")
            case "r" where ansi:
                output.append("\r")
            case "t" where ansi:
                output.append("\t")
            case "\n":
                break
            default:
                output.append(raw[next])
            }
            index = raw.index(after: next)
        }
        return output
    }

    private static func customerDataURL() throws -> URL {
        var components = URLComponents(string: "https://t3.chat/api/trpc/getCustomerData")!
        components.queryItems = [
            URLQueryItem(name: "batch", value: "1"),
            URLQueryItem(name: "input", value: self.input),
        ]
        guard let url = components.url else {
            throw T3ChatUsageError.apiError("Failed to build customer data URL.")
        }
        return url
    }
}
