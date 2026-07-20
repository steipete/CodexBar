import Foundation
import Testing
@testable import CodexBarCore

struct LongCatProviderTests {
    // MARK: - Settings reader

    @Test
    func `reads LONGCAT_MANUAL_COOKIE`() {
        let env = ["LONGCAT_MANUAL_COOKIE": "passport_token=abc; uid=42"]
        #expect(LongCatSettingsReader.cookieHeader(environment: env) == "passport_token=abc; uid=42")
    }

    @Test
    func `reads LONGCAT_API_KEY and trims quotes`() {
        #expect(LongCatSettingsReader.apiKey(environment: ["LONGCAT_API_KEY": "  \"ak_x\"  "]) == "ak_x")
    }

    @Test
    func `missing env returns nil`() {
        #expect(LongCatSettingsReader.cookieHeader(environment: [:]) == nil)
        #expect(LongCatSettingsReader.apiKey(environment: [:]) == nil)
    }

    @Test
    func `cookieHeader reads lowercase alias and trims quotes`() {
        // The env path routes through this reader, so the lower-case alias and
        // quote-trimming must apply (regression for the env-bypass fix).
        #expect(LongCatSettingsReader.cookieHeader(environment: ["longcat_manual_cookie": "'a=b; c=d'"]) == "a=b; c=d")
    }

    // MARK: - Cookie header override

    @Test
    func `override accepts bare cookie pair string`() {
        let override = LongCatCookieHeader.override(from: "passport_token=abc; uid=42")
        #expect(override?.cookieHeader == "passport_token=abc; uid=42")
    }

    @Test
    func `override extracts from a curl Cookie header`() {
        let raw = "curl 'https://longcat.chat/api/v1/user-current' -H 'Cookie: passport_token=abc; uid=42'"
        let override = LongCatCookieHeader.override(from: raw)
        #expect(override?.cookieHeader == "passport_token=abc; uid=42")
    }

    @Test
    func `override rejects a token-less string`() {
        #expect(LongCatCookieHeader.override(from: "not a cookie") == nil)
        #expect(LongCatCookieHeader.override(from: "   ") == nil)
    }

    @Test
    func `imported cookies honor request host path secure and expiry scope`() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let cookies = try [
            self.cookie(name: "root", value: "1", domain: "longcat.chat", path: "/"),
            self.cookie(name: "scoped", value: "2", domain: ".longcat.chat", path: "/api/v1"),
            self.cookie(name: "www", value: "3", domain: "www.longcat.chat", path: "/"),
            self.cookie(name: "other", value: "4", domain: "longcat.chat", path: "/platform"),
            self.cookie(name: "expired", value: "5", domain: "longcat.chat", path: "/", expires: now - 1),
            self.cookie(name: "secure", value: "6", domain: "longcat.chat", path: "/", secure: true),
        ]
        let secureURL = try #require(URL(string: "https://longcat.chat/api/v1/user-current"))
        let insecureURL = try #require(URL(string: "http://longcat.chat/api/v1/user-current"))

        #expect(LongCatCookieHeader.header(from: cookies, for: secureURL, now: now) == "scoped=2; root=1; secure=6")
        #expect(LongCatCookieHeader.header(from: cookies, for: insecureURL, now: now) == "scoped=2; root=1")
    }

    // MARK: - Snapshot mapping

    @Test
    func `total quota maps to primary used percent`() {
        let snapshot = LongCatUsageSnapshot(totalQuota: 1000, usedQuota: 250)
        let usage = snapshot.toUsageSnapshot()
        #expect(usage.identity?.providerID == .longcat)
        #expect(abs((usage.primary?.usedPercent ?? 0) - 25) < 0.001)
    }

    @Test
    func `remaining quota infers used when used is absent`() {
        let snapshot = LongCatUsageSnapshot(totalQuota: 1000, remainingQuota: 400)
        #expect(abs((snapshot.toUsageSnapshot().primary?.usedPercent ?? 0) - 60) < 0.001)
    }

    @Test
    func `missing quota data omits primary window`() {
        let usage = LongCatUsageSnapshot(fuelPackTotal: 500, fuelPackRemaining: 200).toUsageSnapshot()
        #expect(usage.primary == nil)
        #expect(usage.secondary != nil)
    }

    @Test
    func `fuel pack populates secondary window`() {
        let snapshot = LongCatUsageSnapshot(fuelPackTotal: 500, fuelPackRemaining: 200)
        let usage = snapshot.toUsageSnapshot()
        #expect(usage.secondary != nil)
        #expect(abs((usage.secondary?.usedPercent ?? 0) - 60) < 0.001)
    }

    // MARK: - buildSnapshot against captured live response shapes

    private func object(_ json: String) throws -> [String: Any] {
        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8))
        return try #require(parsed as? [String: Any])
    }

    @Test
    func `buildSnapshot maps live tokenUsage and account fields`() throws {
        // Shapes captured from longcat.chat console (values neutralised).
        let account = try self.object(#"{"userId":1,"name":"LongCat User","phone":"x","token":"secret"}"#)
        let tokenUsage = try self.object(#"""
        {"usage":{"totalToken":500000,"usedToken":120000,"availableToken":380000,"freeAvailableToken":380000},
         "extData":{"LongCat-Flash-Lite":{"totalToken":50000000,"usedToken":0}}}
        """#)
        let fuel = try self.object(#"{"totalQuota":0,"list":[]}"#)

        let snapshot = LongCatUsageFetcher.buildSnapshot(account: account, tokenUsage: tokenUsage, pendingFuel: fuel)
        #expect(snapshot.accountName == "LongCat User")
        #expect(snapshot.totalQuota == 500_000)
        #expect(snapshot.usedQuota == 120_000)
        #expect(snapshot.remainingQuota == 380_000)
        #expect(snapshot.fuelPackTotal == nil) // empty fuel list

        let usage = snapshot.toUsageSnapshot()
        #expect(abs((usage.primary?.usedPercent ?? 0) - 24) < 0.001)
        #expect(usage.secondary == nil)
    }

    @Test
    func `buildSnapshot sums active fuel packages`() throws {
        let fuel = try self.object(#"""
        {"totalQuota":1000,"list":[{"availableToken":600,"expireTime":1750000000000},
                                   {"availableToken":150,"expireTime":1760000000000}]}
        """#)
        let snapshot = LongCatUsageFetcher.buildSnapshot(account: nil, tokenUsage: nil, pendingFuel: fuel)
        #expect(snapshot.fuelPackTotal == 1000)
        #expect(snapshot.fuelPackRemaining == 750)
        #expect(snapshot.nearestFuelExpiry != nil)
        #expect(snapshot.toUsageSnapshot().primary == nil)
    }

    // MARK: - Envelope

    @Test
    func `envelope surfaces invalid session on auth code`() {
        #expect(throws: LongCatAPIError.invalidSession) {
            try LongCatEnvelope.unwrap(["code": 401, "message": "unauthorized"])
        }
    }

    @Test
    func `envelope unwraps data on success`() throws {
        let data = try LongCatEnvelope.unwrap(["code": 0, "data": ["x": 1]]) as? [String: Any]
        #expect(data?["x"] as? Int == 1)
    }

    // MARK: - Cookie source semantics

    private func context(
        env: [String: String],
        cookieSource: ProviderCookieSource,
        runtime: ProviderRuntime = .app) -> ProviderFetchContext
    {
        let browserDetection = BrowserDetection(cacheTTL: 0)
        return ProviderFetchContext(
            runtime: runtime,
            sourceMode: .web,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: env,
            settings: ProviderSettingsSnapshot.make(
                longcat: .init(cookieSource: cookieSource, manualCookieHeader: nil)),
            fetcher: UsageFetcher(environment: [:]),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
            browserDetection: browserDetection)
    }

    @Test
    func `off source disables env cookie override`() {
        let ctx = self.context(env: ["LONGCAT_MANUAL_COOKIE": "a=b"], cookieSource: .off)
        #expect(LongCatCookieHeader.resolveCookieOverride(context: ctx) == nil)
    }

    @Test
    func `auto source allows env cookie override`() {
        let ctx = self.context(env: ["LONGCAT_MANUAL_COOKIE": "a=b"], cookieSource: .auto)
        #expect(LongCatCookieHeader.resolveCookieOverride(context: ctx)?.cookieHeader == "a=b")
    }

    @Test
    func `browser import is user initiated app auto only`() {
        let appAuto = self.context(env: [:], cookieSource: .auto)
        let cliAuto = self.context(env: [:], cookieSource: .auto, runtime: .cli)
        let appManual = self.context(env: [:], cookieSource: .manual)
        let appOff = self.context(env: [:], cookieSource: .off)

        #expect(LongCatWebFetchStrategy.allowsBrowserImport(context: appAuto) == false)
        #expect(LongCatWebFetchStrategy.allowsBrowserImport(context: cliAuto) == false)

        ProviderInteractionContext.$current.withValue(.userInitiated) {
            #expect(LongCatWebFetchStrategy.allowsBrowserImport(context: appAuto))
            #expect(LongCatWebFetchStrategy.allowsBrowserImport(context: cliAuto) == false)
            #expect(LongCatWebFetchStrategy.allowsBrowserImport(context: appManual) == false)
            #expect(LongCatWebFetchStrategy.allowsBrowserImport(context: appOff) == false)
        }
    }

    #if os(macOS)
    @Test
    func `browser import tries later profiles after credential failure`() async throws {
        let cookie = try self.cookie(name: "session", value: "x", domain: "longcat.chat", path: "/")
        let sessions = [
            LongCatCookieImporter.SessionInfo(cookies: [cookie], sourceLabel: "Chrome Profile 1"),
            LongCatCookieImporter.SessionInfo(cookies: [cookie], sourceLabel: "Chrome Profile 2"),
        ]
        var attempts: [String] = []

        let snapshot = try await LongCatWebFetchStrategy.fetchImportedSessions(sessions) { session in
            attempts.append(session.sourceLabel)
            if session.sourceLabel == "Chrome Profile 1" {
                throw LongCatAPIError.invalidSession
            }
            return LongCatUsageSnapshot(totalQuota: 100, usedQuota: 10)
        }

        #expect(attempts == ["Chrome Profile 1", "Chrome Profile 2"])
        #expect(snapshot.totalQuota == 100)
    }

    @Test
    func `browser import stops on non-credential failure`() async throws {
        let cookie = try self.cookie(name: "session", value: "x", domain: "longcat.chat", path: "/")
        let sessions = [
            LongCatCookieImporter.SessionInfo(cookies: [cookie], sourceLabel: "Chrome Profile 1"),
            LongCatCookieImporter.SessionInfo(cookies: [cookie], sourceLabel: "Chrome Profile 2"),
        ]
        var attempts = 0

        await #expect(throws: LongCatAPIError.apiError("HTTP 500")) {
            _ = try await LongCatWebFetchStrategy.fetchImportedSessions(sessions) { _ in
                attempts += 1
                throw LongCatAPIError.apiError("HTTP 500")
            }
        }
        #expect(attempts == 1)
    }
    #endif

    // MARK: - HTTP status handling (fetchUsage over an injected transport)

    @Test
    func `fetch surfaces invalid session on 401`() async {
        let transport = LongCatScriptedTransport(results: [.status(401)])
        await #expect(throws: LongCatAPIError.invalidSession) {
            _ = try await LongCatUsageFetcher.fetchUsage(cookieHeader: "session=x", transport: transport)
        }
    }

    @Test
    func `fetch surfaces invalid session on 403`() async {
        let transport = LongCatScriptedTransport(results: [.status(403)])
        await #expect(throws: LongCatAPIError.invalidSession) {
            _ = try await LongCatUsageFetcher.fetchUsage(cookieHeader: "session=x", transport: transport)
        }
    }

    @Test
    func `fetch treats a blocked login redirect as invalid session`() async {
        // The shared transport's redirect guard drops the cross-origin login hop, so an
        // expired cookie surfaces here as a raw 3xx; it must still read as invalid-session.
        let transport = LongCatScriptedTransport(results: [.status(302)])
        await #expect(throws: LongCatAPIError.invalidSession) {
            _ = try await LongCatUsageFetcher.fetchUsage(cookieHeader: "session=x", transport: transport)
        }
    }

    @Test
    func `fetch maps a full live response over the transport`() async throws {
        let transport = LongCatScriptedTransport(results: [
            .body(#"{"code":0,"data":{"name":"Leo"}}"#),
            .body(#"{"code":0,"data":{"usage":{"totalToken":500000,"usedToken":120000,"availableToken":380000}}}"#),
            .body(#"{"code":0,"data":{"totalQuota":1000,"list":[{"availableToken":600,"expireTime":1750000000000}]}}"#),
        ])
        let snapshot = try await LongCatUsageFetcher.fetchUsage(cookieHeader: "session=x", transport: transport)
        #expect(snapshot.accountName == "Leo")
        #expect(snapshot.totalQuota == 500_000)
        #expect(snapshot.usedQuota == 120_000)
        #expect(snapshot.fuelPackTotal == 1000)
        #expect(snapshot.fuelPackRemaining == 600)
    }

    @Test
    func `fetch requires the canonical token usage response`() async {
        let transport = LongCatScriptedTransport(results: [
            .body(#"{"code":0,"data":{"name":"Leo"}}"#),
            .status(500),
        ])
        await #expect(throws: LongCatAPIError.apiError("HTTP 500 for /api/lc-platform/v1/tokenUsage")) {
            _ = try await LongCatUsageFetcher.fetchUsage(cookieHeader: "session=x", transport: transport)
        }
    }

    @Test
    func `fetch rejects malformed canonical token usage data`() async {
        let transport = LongCatScriptedTransport(results: [
            .body(#"{"code":0,"data":{"name":"Leo"}}"#),
            .body(#"{"code":0,"data":[]}"#),
        ])
        await #expect(throws: LongCatAPIError.parseFailed("tokenUsage data was not an object")) {
            _ = try await LongCatUsageFetcher.fetchUsage(cookieHeader: "session=x", transport: transport)
        }
    }

    @Test
    func `fetch rejects canonical token usage without quota fields`() async {
        let transport = LongCatScriptedTransport(results: [
            .body(#"{"code":0,"data":{"name":"Leo"}}"#),
            .body(#"{"code":0,"data":{"usage":{"usedToken":120000}}}"#),
        ])
        await #expect(throws: LongCatAPIError.parseFailed("tokenUsage data was missing totalToken")) {
            _ = try await LongCatUsageFetcher.fetchUsage(cookieHeader: "session=x", transport: transport)
        }
    }

    @Test
    func `supplemental fuel failures do not erase primary quota`() async throws {
        let transport = LongCatScriptedTransport(results: [
            .body(#"{"code":0,"data":{"name":"Leo"}}"#),
            .body(#"{"code":0,"data":{"usage":{"totalToken":500000,"usedToken":120000}}}"#),
            .status(500),
        ])
        let snapshot = try await LongCatUsageFetcher.fetchUsage(cookieHeader: "session=x", transport: transport)
        #expect(snapshot.totalQuota == 500_000)
        #expect(snapshot.usedQuota == 120_000)
        #expect(snapshot.fuelPackTotal == nil)
    }

    @Test
    func `supplemental fuel auth failure does not erase primary quota`() async throws {
        let transport = LongCatScriptedTransport(results: [
            .body(#"{"code":0,"data":{"name":"Leo"}}"#),
            .body(#"{"code":0,"data":{"usage":{"totalToken":500000,"usedToken":120000}}}"#),
            .status(401),
        ])
        let snapshot = try await LongCatUsageFetcher.fetchUsage(cookieHeader: "session=x", transport: transport)
        #expect(snapshot.totalQuota == 500_000)
        #expect(snapshot.usedQuota == 120_000)
        #expect(snapshot.fuelPackTotal == nil)
    }

    private func cookie(
        name: String,
        value: String,
        domain: String,
        path: String,
        expires: Date? = nil,
        secure: Bool = false) throws -> HTTPCookie
    {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: domain,
            .path: path,
        ]
        if let expires {
            properties[.expires] = expires
        }
        if secure {
            properties[.secure] = "TRUE"
        }
        return try #require(HTTPCookie(properties: properties))
    }
}

/// Scripted transport for exercising `LongCatUsageFetcher.fetchUsage` HTTP paths
/// without a network. Returns the given results in order; an exhausted script
/// yields an empty 200 so best-effort follow-up probes decode to nil.
private actor LongCatScriptedTransport: ProviderHTTPTransport {
    enum Result {
        case status(Int)
        case body(String)
    }

    private var results: [Result]

    init(results: [Result]) {
        self.results = results
    }

    func data(for request: URLRequest) throws -> (Data, URLResponse) {
        let result = self.results.isEmpty ? .status(200) : self.results.removeFirst()
        let statusCode: Int
        let body: String
        switch result {
        case let .status(code):
            statusCode = code
            body = ""
        case let .body(text):
            statusCode = 200
            body = text
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil)!
        return (Data(body.utf8), response)
    }
}
