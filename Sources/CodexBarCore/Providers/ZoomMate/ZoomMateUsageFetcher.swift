import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct ZoomMateUsageFetcher: Sendable {
    private static let log = CodexBarLog.logger(LogCategories.zoommate)
    private static let refererURL = URL(string: "https://zoommate.zoom.us")!
    /// First-party API hosts, tried in order. `ai.zoom.us` and `zoommate.zoom.us` currently serve
    /// the same `/ai-computer/` API interchangeably and either may retire in the future, so every
    /// API request falls over to the next host on non-auth failures via `withAPIHostFailover`
    /// (precedent: `FactoryStatusProbe`'s base-URL candidates).
    static let apiHosts = ["ai.zoom.us", "zoommate.zoom.us"]
    static let creditsStatusPath = "/ai-computer/api/v1/credits/status"
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
        "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"

    /// Forwarded headers allowlist for the manual `.web` cURL capture. Unlike T3 Chat's, this
    /// MUST include `authorization` (design D2) because ZoomMate's credential is a bearer token,
    /// not a cookie.
    private static let forwardedManualHeaders = [
        "authorization": "Authorization",
        "cookie": "Cookie",
        "user-agent": "User-Agent",
        "accept": "Accept",
        "accept-language": "Accept-Language",
        "sec-fetch-dest": "Sec-Fetch-Dest",
        "sec-fetch-mode": "Sec-Fetch-Mode",
        "sec-fetch-site": "Sec-Fetch-Site",
    ]

    public struct RequestContext: Sendable {
        public let authorization: String
        public let headers: [String: String]
        /// Signed-in user's email, when known. Only populated by the `.auto` cookie-mint path
        /// (sourced from the login bootstrap response's `data.user_profile.email`); the manual
        /// `.web` cURL-capture path has no equivalent payload to read it from, so this stays `nil`
        /// there.
        public let accountEmail: String?
        /// Bearer-token cache key for the originating cookie session (`.auto` path only). Lets a
        /// caller evict the reused token from `ZoomMateBearerTokenCache` when a downstream request
        /// rejects it (`401/403`). `nil` for the manual `.web` path, which carries its own bearer.
        public let cacheKey: String?

        public init(
            authorization: String,
            headers: [String: String] = [:],
            accountEmail: String? = nil,
            cacheKey: String? = nil)
        {
            self.authorization = authorization
            self.headers = headers
            self.accountEmail = accountEmail
            self.cacheKey = cacheKey
        }
    }

    /// Result of `mintBearerToken`: the freshly-minted bearer JWT plus whatever identity
    /// enrichment (currently just `email`) the same login bootstrap response happened to include
    /// in its `data.user_profile` object. Modeled on the small multi-field result structs other
    /// providers return from a single fetch (e.g. `ZoomMateCookieImporter.SessionInfo`).
    public struct MintedToken: Sendable {
        public let bearerToken: String
        public let accountEmail: String?

        public init(bearerToken: String, accountEmail: String?) {
            self.bearerToken = bearerToken
            self.accountEmail = accountEmail
        }
    }

    public let browserDetection: BrowserDetection

    public init(browserDetection: BrowserDetection) {
        self.browserDetection = browserDetection
    }

    public func fetch(
        manualCaptureOverride: String? = nil,
        timeout: TimeInterval = 15,
        logger: (@Sendable (String) -> Void)? = nil,
        now: Date = Date(),
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared) async throws -> ZoomMateUsageSnapshot
    {
        let log: @Sendable (String) -> Void = { msg in logger?("[zoommate] \(msg)") }
        let context = try await self.resolveRequestContext(
            manualCaptureOverride: manualCaptureOverride,
            timeout: timeout,
            logger: log,
            transport: transport)
        if !context.headers.isEmpty {
            let headerNames = context.headers.keys.sorted().joined(separator: ", ")
            log("Forwarding captured headers: \(headerNames)")
        }
        return try await Self.fetchCreditsStatus(
            context: context,
            timeout: timeout,
            now: now,
            transport: transport)
    }

    public static func fetchCreditsStatus(
        context: RequestContext,
        timeout: TimeInterval = 15,
        now: Date = Date(),
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared) async throws -> ZoomMateUsageSnapshot
    {
        try await self.withAPIHostFailover { host in
            try await self.fetchCreditsStatus(
                context: context,
                host: host,
                timeout: timeout,
                now: now,
                transport: transport)
        }
    }

    /// Runs one API request per host in `apiHosts` order, returning the first success. Auth
    /// rejections and parse failures propagate immediately — the host answered, so retrying the
    /// interchangeable alternate cannot help; anything else (unreachable host, non-auth HTTP
    /// error) falls through to the next host so the provider keeps working if either host
    /// retires.
    static func withAPIHostFailover<T: Sendable>(
        operation: (String) async throws -> T) async throws -> T
    {
        var lastError: Error?
        for (index, host) in self.apiHosts.enumerated() {
            try Task.checkCancellation()
            do {
                return try await operation(host)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch ZoomMateUsageError.invalidCredentials {
                throw ZoomMateUsageError.invalidCredentials
            } catch let ZoomMateUsageError.parseFailed(message) {
                throw ZoomMateUsageError.parseFailed(message)
            } catch {
                if Task.isCancelled {
                    throw CancellationError()
                }
                lastError = error
                if index < self.apiHosts.count - 1 {
                    Self.log.info("ZoomMate API host unavailable; retrying on the alternate host")
                }
            }
        }
        throw lastError ?? ZoomMateUsageError.apiError("No ZoomMate API host succeeded.")
    }

    private static func fetchCreditsStatus(
        context: RequestContext,
        host: String,
        timeout: TimeInterval,
        now: Date,
        transport: any ProviderHTTPTransport) async throws -> ZoomMateUsageSnapshot
    {
        var request = URLRequest(url: URL(string: "https://\(host)\(self.creditsStatusPath)")!)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        self.applyDefaultHeaders(to: &request)
        for (name, value) in context.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        // Authorization is always sent (the required credential per design D2). Origin and Referer
        // are fixed here so captured values can never widen the first-party request boundary.
        request.setValue(context.authorization, forHTTPHeaderField: "Authorization")
        request.setValue(self.refererURL.absoluteString, forHTTPHeaderField: "Origin")
        request.setValue(self.refererURL.absoluteString, forHTTPHeaderField: "Referer")

        let response = try await transport.response(for: request)
        let data = response.data
        guard response.statusCode == 200 else {
            Self.log.error("ZoomMate API returned \(response.statusCode)")
            if response.statusCode == 401 || response.statusCode == 403 {
                throw ZoomMateUsageError.invalidCredentials
            }
            throw ZoomMateUsageError.apiError("HTTP \(response.statusCode)")
        }

        do {
            let envelope = try JSONDecoder().decode(CreditsStatusEnvelope.self, from: data)
            guard let creditStatus = envelope.data?.creditStatus else {
                throw ZoomMateUsageError.parseFailed("Missing credit_status object.")
            }
            return ZoomMateUsageSnapshot(creditStatus: creditStatus, updatedAt: now)
        } catch let error as ZoomMateUsageError {
            throw error
        } catch {
            Self.log.error("ZoomMate credits/status parse failed")
            throw ZoomMateUsageError.parseFailed(error.localizedDescription)
        }
    }

    /// Exchanges a ZoomMate/Zoom session cookie header for a fresh bearer JWT via ZoomMate's own
    /// cookie-to-token bootstrap endpoint — the same call its web frontend makes on every page
    /// load. Cookies (session/SSO-backed) live far longer than the ~hourly JWT, so minting a fresh
    /// token from cookies avoids the manual re-paste entirely as long as the underlying browser
    /// session cookies remain valid. Callers should prefer `cachedOrMintedToken`, which reuses a
    /// still-valid minted token from `ZoomMateBearerTokenCache` instead of re-minting every fetch.
    public static func mintBearerToken(
        cookieHeader: String,
        timeout: TimeInterval = 15,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared) async throws -> MintedToken
    {
        try await self.withAPIHostFailover { host in
            try await self.mintBearerToken(
                cookieHeader: cookieHeader,
                host: host,
                timeout: timeout,
                transport: transport)
        }
    }

    private static func mintBearerToken(
        cookieHeader: String,
        host: String,
        timeout: TimeInterval,
        transport: any ProviderHTTPTransport) async throws -> MintedToken
    {
        var components = URLComponents(string: "https://\(host)/ai-computer/api/v1/login/")!
        components.queryItems = [URLQueryItem(name: "continue", value: "https://zoommate.zoom.us/")]
        guard let url = components.url else {
            throw ZoomMateUsageError.apiError("Failed to build login bootstrap URL.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        self.applyDefaultHeaders(to: &request)
        request.setValue(self.refererURL.absoluteString, forHTTPHeaderField: "Origin")
        request.setValue(self.refererURL.absoluteString, forHTTPHeaderField: "Referer")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")

        let response = try await transport.response(for: request)
        let data = response.data
        guard response.statusCode == 200 else {
            Self.log.error("ZoomMate login bootstrap returned \(response.statusCode)")
            if response.statusCode == 401 || response.statusCode == 403 {
                throw ZoomMateUsageError.invalidCredentials
            }
            throw ZoomMateUsageError.apiError("HTTP \(response.statusCode)")
        }

        do {
            let envelope = try JSONDecoder().decode(LoginBootstrapEnvelope.self, from: data)
            guard let nak = envelope.data?.nak, !nak.isEmpty else {
                throw ZoomMateUsageError.parseFailed("Missing nak in login bootstrap response.")
            }
            let email = envelope.data?.userProfile?.email?.trimmingCharacters(in: .whitespacesAndNewlines)
            return MintedToken(bearerToken: nak, accountEmail: (email?.isEmpty ?? true) ? nil : email)
        } catch let error as ZoomMateUsageError {
            throw error
        } catch {
            throw ZoomMateUsageError.parseFailed(error.localizedDescription)
        }
    }

    func resolveRequestContext(
        manualCaptureOverride: String?,
        allowCachedCookieHeader: Bool = true,
        timeout: TimeInterval,
        logger: (@Sendable (String) -> Void)?,
        cache: ZoomMateBearerTokenCache = .shared,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared) async throws -> RequestContext
    {
        if let manualCaptureOverride {
            guard let override = Self.requestContext(from: manualCaptureOverride) else {
                throw ZoomMateUsageError.noCapture
            }
            logger?("[zoommate] Using manual cURL capture")
            return override
        }

        #if os(macOS)
        // Cached cookie header first (Perplexity/OpenCode precedent): Chrome's cookie decryption
        // is gated behind user-initiated contexts (`BrowserCookieAccessGate`) to avoid Keychain
        // prompts, so background refreshes and the bundled CLI must be able to run entirely from
        // the last validated session instead of rereading the browser.
        if allowCachedCookieHeader,
           let cached = CookieHeaderCache.load(provider: .zoommate),
           !cached.cookieHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            logger?("[zoommate] Using cached cookie header from \(cached.sourceLabel)")
            return try await Self.requestContext(
                forCookieHeader: cached.cookieHeader,
                persistingValidatedHeaderAs: nil,
                cache: cache,
                timeout: timeout,
                transport: transport,
                logger: logger)
        }

        let sessions = try ZoomMateCookieImporter.importSessions(
            browserDetection: self.browserDetection,
            logger: logger)
        return try await Self.requestContext(
            forCookieSessions: sessions,
            cache: cache,
            timeout: timeout,
            transport: transport,
            logger: logger)
        #else
        throw ZoomMateUsageError.noSession
        #endif
    }

    #if os(macOS)
    /// Tries browser cookie profiles in import order, advancing only when the login bootstrap
    /// explicitly rejects a candidate. Network and parse failures surface immediately rather than
    /// being hidden by another profile. Only the first successfully minted session is persisted.
    static func requestContext(
        forCookieSessions sessions: [ZoomMateCookieImporter.SessionInfo],
        cache: ZoomMateBearerTokenCache = .shared,
        timeout: TimeInterval,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        logger: (@Sendable (String) -> Void)?) async throws -> RequestContext
    {
        guard !sessions.isEmpty else { throw ZoomMateUsageError.noSession }

        for session in sessions {
            logger?("[zoommate] Trying cookies from \(session.sourceLabel)")
            do {
                return try await self.requestContext(
                    forCookieHeader: session.cookieHeader,
                    persistingValidatedHeaderAs: session.sourceLabel,
                    cache: cache,
                    timeout: timeout,
                    transport: transport,
                    logger: logger)
            } catch ZoomMateUsageError.invalidCredentials {
                logger?("[zoommate] Cookie session from \(session.sourceLabel) was rejected")
            }
        }

        throw ZoomMateUsageError.invalidCredentials
    }

    /// Builds the `.auto` request context for a cookie session: reuses or mints the bearer JWT
    /// and, when `sourceLabel` is non-nil (a fresh browser import), persists the now-validated
    /// cookie header through `CookieHeaderCache`. The successful mint is the validation —
    /// ZoomMate's login bootstrap rejects a dead session with 401/403 before anything is stored.
    /// Only the cookie header is persisted; the minted bearer stays in the in-memory
    /// `ZoomMateBearerTokenCache`.
    static func requestContext(
        forCookieHeader cookieHeader: String,
        persistingValidatedHeaderAs sourceLabel: String?,
        cache: ZoomMateBearerTokenCache = .shared,
        timeout: TimeInterval,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        logger: (@Sendable (String) -> Void)?) async throws -> RequestContext
    {
        let minted = try await Self.cachedOrMintedToken(
            cookieHeader: cookieHeader,
            cache: cache,
            timeout: timeout,
            transport: transport,
            logger: logger)
        if let sourceLabel {
            CookieHeaderCache.store(
                provider: .zoommate,
                cookieHeader: cookieHeader,
                sourceLabel: sourceLabel)
        }
        return RequestContext(
            authorization: Self.bearerHeaderValue(from: minted.bearerToken),
            headers: ["Cookie": cookieHeader],
            accountEmail: minted.accountEmail,
            cacheKey: ZoomMateBearerTokenCache.key(forCookieHeader: cookieHeader))
    }
    #endif

    /// Returns a still-valid cached bearer token for `cookieHeader`, or mints a fresh one and caches
    /// it when the minted JWT exposes an `exp` claim. A token whose expiry can't be read is returned
    /// but never cached, so `.auto` refreshes degrade to the mint-every-fetch behavior rather than
    /// risk serving an undatable (possibly expired) token.
    static func cachedOrMintedToken(
        cookieHeader: String,
        cache: ZoomMateBearerTokenCache,
        timeout: TimeInterval,
        transport: any ProviderHTTPTransport,
        logger: (@Sendable (String) -> Void)?) async throws -> MintedToken
    {
        let cacheKey = ZoomMateBearerTokenCache.key(forCookieHeader: cookieHeader)
        if let entry = await cache.validEntry(forKey: cacheKey, now: Date()) {
            logger?("[zoommate] Reusing cached bearer token")
            return MintedToken(bearerToken: entry.token, accountEmail: entry.accountEmail)
        }
        let minted = try await Self.mintBearerToken(
            cookieHeader: cookieHeader,
            timeout: timeout,
            transport: transport)
        if let expiry = Self.expiry(fromJWT: minted.bearerToken) {
            await cache.store(
                ZoomMateBearerTokenCache.Entry(
                    token: minted.bearerToken,
                    accountEmail: minted.accountEmail,
                    expiry: expiry),
                forKey: cacheKey)
            logger?("[zoommate] Minted fresh bearer token via cookie session (cached until expiry)")
        } else {
            logger?("[zoommate] Minted fresh bearer token via cookie session (not cached: no expiry claim)")
        }
        return minted
    }

    /// Reads the `exp` claim (seconds since epoch) from a bearer JWT, returning its expiry `Date`.
    /// Returns `nil` for anything that isn't a decodable JWT with a numeric `exp` — the caller then
    /// treats the token as non-cacheable. Mirrors the base64url/JSON payload decode used elsewhere
    /// (e.g. `MiniMaxLocalStorageImporter`); no signature verification (we minted it ourselves).
    static func expiry(fromJWT token: String) -> Date? {
        let raw = Self.bearerHeaderValue(from: token).dropFirst("Bearer ".count)
        let parts = raw.split(separator: ".")
        guard parts.count >= 2, let data = Self.base64URLDecode(String(parts[1])) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = (object["exp"] as? NSNumber)?.doubleValue, exp > 0
        else {
            return nil
        }
        return Date(timeIntervalSince1970: exp)
    }

    private static func base64URLDecode(_ value: String) -> Data? {
        var base64 = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - base64.count % 4) % 4
        if padding > 0 {
            base64.append(String(repeating: "=", count: padding))
        }
        return Data(base64Encoded: base64)
    }

    static func bearerHeaderValue(from rawToken: String) -> String {
        let trimmed = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("bearer ") {
            return trimmed
        }
        return "Bearer \(trimmed)"
    }

    /// Parses a manual cURL capture into a `RequestContext`. Returns `nil` when no non-empty
    /// `Authorization` header can be extracted — that's the required credential (design D2).
    static func requestContext(from raw: String?) -> RequestContext? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        guard let captureURL = CurlCaptureParser.requestURL(from: raw), self.isAllowedCaptureURL(captureURL) else {
            return nil
        }
        let headerFields = CurlCaptureParser.headerFields(from: raw)
        guard let authorization = CurlCaptureParser.headerValue(named: "Authorization", in: headerFields),
              !authorization.isEmpty
        else {
            return nil
        }
        var headers = CurlCaptureParser.forwardedHeaders(from: headerFields, allowlist: self.forwardedManualHeaders)
        headers.removeValue(forKey: "Authorization")
        return RequestContext(authorization: Self.bearerHeaderValue(from: authorization), headers: headers)
    }

    /// Captures are accepted from any host in `apiHosts` (the interchangeable first-party API
    /// hosts) — DevTools shows the credits/status request on whichever host the web client used —
    /// but only for the exact HTTPS credits/status path with no port, userinfo, query, or fragment.
    private static func isAllowedCaptureURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return url.scheme?.lowercased() == "https" &&
            self.apiHosts.contains(host) &&
            url.port == nil &&
            url.user == nil &&
            url.password == nil &&
            url.path == self.creditsStatusPath &&
            url.query == nil &&
            url.fragment == nil
    }

    private static func applyDefaultHeaders(to request: inout URLRequest) {
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue(self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("empty", forHTTPHeaderField: "Sec-Fetch-Dest")
        request.setValue("cors", forHTTPHeaderField: "Sec-Fetch-Mode")
        request.setValue("same-site", forHTTPHeaderField: "Sec-Fetch-Site")
    }

    private struct CreditsStatusEnvelope: Decodable {
        struct DataBox: Decodable {
            let creditStatus: ZoomMateCreditStatus?

            private enum CodingKeys: String, CodingKey {
                case creditStatus = "credit_status"
            }
        }

        let data: DataBox?
        let statusCode: Int?
        let errorMessage: String?

        private enum CodingKeys: String, CodingKey {
            case data
            case statusCode = "status_code"
            case errorMessage = "error_message"
        }
    }

    /// Shape of ZoomMate's cookie-to-token bootstrap response (`GET .../login/?continue=...`).
    /// `data.nak` (the freshly-minted bearer JWT) is required; `data.user_profile.email` is
    /// decoded as an optional identity-enrichment nice-to-have (never required — a missing/absent
    /// `user_profile` or `email` must never fail the mint). The rest of the payload (permissions,
    /// cluster config, etc.) is ignored.
    private struct LoginBootstrapEnvelope: Decodable {
        struct UserProfile: Decodable {
            let email: String?
        }

        struct DataBox: Decodable {
            let nak: String?
            let userProfile: UserProfile?

            private enum CodingKeys: String, CodingKey {
                case nak
                case userProfile = "user_profile"
            }
        }

        let success: Bool?
        let data: DataBox?
    }
}
