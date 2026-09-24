import Foundation
import Testing
@testable import CodexBarCore

struct ManusProviderTests {
    private static let now = Date(timeIntervalSince1970: 1_744_000_000)

    @Test
    func `settings reader accepts full cookie header from environment`() {
        let env = ["MANUS_COOKIE": "foo=bar; session_id=env-cookie-token; baz=qux"]
        #expect(ManusSettingsReader.sessionToken(environment: env) == "env-cookie-token")
    }

    @Test
    func `parse response tolerates sparse live payload`() async throws {
        let data = Data("""
        {
          "totalCredits": 2869,
          "freeCredits": 1500,
          "periodicCredits": 1369,
          "proMonthlyCredits": 4000,
          "maxRefreshCredits": 300,
          "nextRefreshTime": "2026-04-13T00:00:00Z",
          "refreshInterval": "daily",
          "userFlag": { "drc16": true }
        }
        """.utf8)

        let response = try await CookiePluginFixtures.manus(data)
        #expect(response.totalCredits == 2869)
        #expect(response.periodicCredits == 1369)
        #expect(response.proMonthlyCredits == 4000)
        #expect(response.refreshCredits == 0)
        #expect(response.addonCredits == 0)
        #expect(response.maxRefreshCredits == 300)
        #expect(response.nextRefreshTime != nil)

        let snapshot = response.toUsageSnapshot(now: Self.now)
        #expect(snapshot.providerCost == nil)
        #expect(snapshot.primary?.usedPercent ?? 0 > 65)
        #expect(snapshot.primary?.resetDescription == "Total 2,869 • Free 1,500")
        #expect(snapshot.secondary?.usedPercent == 100)
        #expect(snapshot.secondary?.resetDescription == "Daily: 0 / 300")
    }

    @Test(arguments: ["", "data", "result", "response", "availableCredits"], [
        "{}",
        #"{"error":"unauthorized","message":"session expired"}"#,
        #"{"nextRefreshTime":"2026-04-13T00:00:00Z","refreshInterval":"daily"}"#,
    ])
    func `parse response rejects payload without credits fields`(envelope: String, payload: String) async {
        let json = envelope.isEmpty ? payload : "{\"\(envelope)\":\(payload)}"
        let data = Data(json.utf8)

        await #expect(throws: ManusAPIError.parseFailed("response missing expected credits fields")) {
            try await CookiePluginFixtures.manus(data)
        }
    }

    @Test(arguments: ["", "data", "result", "response", "availableCredits"], [
        "totalCredits", "freeCredits", "periodicCredits", "addonCredits",
        "refreshCredits", "maxRefreshCredits", "proMonthlyCredits", "eventCredits",
    ])
    func `parse response preserves sparse zero credit payloads`(envelope: String, creditKey: String) async throws {
        let payload = "{\"\(creditKey)\":0}"
        let json = envelope.isEmpty ? payload : "{\"\(envelope)\":\(payload)}"
        let response = try await CookiePluginFixtures.manus(Data(json.utf8))
        #expect(response.totalCredits == 0)
        #expect(response.toUsageSnapshot(now: Self.now).identity?.loginMethod == "Balance: 0 credits")
    }

    @Test(arguments: [
        #"{"data":{},"result":{"totalCredits":5}}"#,
        #"{"data":{},"totalCredits":5}"#,
    ])
    func `parse response rejects the selected invalid envelope`(body: String) async {
        await #expect(throws: ManusAPIError.parseFailed("response missing expected credits fields")) {
            try await CookiePluginFixtures.manus(Data(body.utf8))
        }
    }

    @Test
    func `parse response accepts wrapped envelope`() async throws {
        let data = Data("""
        {
          "data": {
            "totalCredits": 100,
            "proMonthlyCredits": 200,
            "periodicCredits": 50,
            "maxRefreshCredits": 10,
            "refreshCredits": 5
          }
        }
        """.utf8)

        let response = try await CookiePluginFixtures.manus(data)
        #expect(response.totalCredits == 100)
        #expect(response.periodicCredits == 50)
    }
}
