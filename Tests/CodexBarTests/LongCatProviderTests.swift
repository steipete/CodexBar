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

    @Test
    func `today tokens populate tertiary window`() {
        let usage = LongCatUsageSnapshot(todayTokens: 12345).toUsageSnapshot()
        #expect(usage.tertiary != nil)
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
}
