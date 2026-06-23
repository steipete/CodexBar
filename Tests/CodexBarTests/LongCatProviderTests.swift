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
        cookieSource: ProviderCookieSource) -> ProviderFetchContext
    {
        let browserDetection = BrowserDetection(cacheTTL: 0)
        return ProviderFetchContext(
            runtime: .app,
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
}
