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
    func `fetch surfaces invalid session from optional quota envelopes`() async {
        let transport = LongCatScriptedTransport(results: [
            .body(#"{"code":0,"data":{"name":"Leo"}}"#),
            .body(#"{"code":401,"message":"unauthorized"}"#),
        ])

        await #expect(throws: LongCatAPIError.invalidSession) {
            _ = try await LongCatUsageFetcher.fetchUsage(cookieHeader: "session=x", transport: transport)
        }
    }

    @Test
    func `fetch keeps optional non auth quota failures contained`() async throws {
        let transport = LongCatScriptedTransport(results: [
            .body(#"{"code":0,"data":{"name":"Leo"}}"#),
            .body(#"{"code":500,"message":"temporarily unavailable"}"#),
            .body(#"{"code":0,"data":{"totalQuota":1000,"list":[{"availableToken":600}]}}"#),
        ])

        let snapshot = try await LongCatUsageFetcher.fetchUsage(cookieHeader: "session=x", transport: transport)
        #expect(snapshot.accountName == "Leo")
        #expect(snapshot.totalQuota == nil)
        #expect(snapshot.fuelPackTotal == 1000)
        #expect(snapshot.fuelPackRemaining == 600)
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
