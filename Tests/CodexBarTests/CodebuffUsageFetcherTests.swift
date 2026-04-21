import Foundation
import Testing
@testable import CodexBarCore

struct CodebuffUsageFetcherTests {
    @Test
    func `usage URL composes the correct endpoint`() {
        let base = URL(string: "https://www.codebuff.com")!
        let url = CodebuffUsageFetcher.usageURL(baseURL: base)
        #expect(url.absoluteString == "https://www.codebuff.com/api/v1/usage")
    }

    @Test
    func `subscription URL composes the correct endpoint`() {
        let base = URL(string: "https://www.codebuff.com")!
        let url = CodebuffUsageFetcher.subscriptionURL(baseURL: base)
        #expect(url.absoluteString == "https://www.codebuff.com/api/user/subscription")
    }

    @Test
    func `status 401 maps to unauthorized`() {
        #expect(CodebuffUsageFetcher._statusErrorForTesting(401) == .unauthorized)
        #expect(CodebuffUsageFetcher._statusErrorForTesting(403) == .unauthorized)
    }

    @Test
    func `status 404 maps to endpoint not found`() {
        #expect(CodebuffUsageFetcher._statusErrorForTesting(404) == .endpointNotFound)
    }

    @Test
    func `status 500 maps to service unavailable`() {
        guard case .serviceUnavailable(503) = CodebuffUsageFetcher._statusErrorForTesting(503)
        else {
            Issue.record("Expected .serviceUnavailable(503)")
            return
        }
    }

    @Test
    func `status 200 returns nil`() {
        #expect(CodebuffUsageFetcher._statusErrorForTesting(200) == nil)
    }

    @Test
    func `usage payload parses numeric credit fields`() throws {
        let json = """
        {
          "usage": 1250,
          "quota": 5000,
          "remainingBalance": 3750,
          "autoTopupEnabled": true,
          "next_quota_reset": "2026-05-01T00:00:00Z"
        }
        """

        let payload = try CodebuffUsageFetcher._parseUsagePayloadForTesting(Data(json.utf8))
        #expect(payload.used == 1250)
        #expect(payload.total == 5000)
        #expect(payload.remaining == 3750)
        #expect(payload.autoTopupEnabled == true)
        #expect(payload.nextQuotaReset != nil)
    }

    @Test
    func `usage payload accepts string-encoded numbers`() throws {
        let json = """
        { "usage": "12", "quota": "100", "remainingBalance": "88" }
        """
        let payload = try CodebuffUsageFetcher._parseUsagePayloadForTesting(Data(json.utf8))
        #expect(payload.used == 12)
        #expect(payload.total == 100)
        #expect(payload.remaining == 88)
    }

    @Test
    func `usage payload returns nil fields when absent`() throws {
        let payload = try CodebuffUsageFetcher._parseUsagePayloadForTesting(Data("{}".utf8))
        #expect(payload.used == nil)
        #expect(payload.total == nil)
        #expect(payload.remaining == nil)
        #expect(payload.autoTopupEnabled == nil)
    }

    @Test
    func `usage payload throws on malformed JSON`() {
        #expect {
            _ = try CodebuffUsageFetcher._parseUsagePayloadForTesting(Data("not-json".utf8))
        } throws: { error in
            guard case CodebuffUsageError.parseFailed = error else { return false }
            return true
        }
    }

    @Test
    func `subscription payload parses tier and weekly window`() throws {
        let json = """
        {
          "hasSubscription": true,
          "subscription": {
            "status": "active",
            "tier": "pro",
            "billingPeriodEnd": "2026-05-15T00:00:00Z"
          },
          "rateLimit": {
            "weeklyUsed": 2100,
            "weeklyLimit": 7000
          },
          "email": "user@example.com"
        }
        """

        let payload = try CodebuffUsageFetcher._parseSubscriptionPayloadForTesting(Data(json.utf8))
        #expect(payload.tier == "pro")
        #expect(payload.status == "active")
        #expect(payload.weeklyUsed == 2100)
        #expect(payload.weeklyLimit == 7000)
        #expect(payload.email == "user@example.com")
        #expect(payload.billingPeriodEnd != nil)
    }

    @Test
    func `subscription payload falls back to scheduled tier`() throws {
        let json = """
        { "subscription": { "scheduledTier": "team" } }
        """
        let payload = try CodebuffUsageFetcher._parseSubscriptionPayloadForTesting(Data(json.utf8))
        #expect(payload.tier == "team")
    }

    @Test
    func `subscription payload tolerates missing rate limit`() throws {
        let json = """
        { "subscription": { "status": "trialing", "tier": "free" } }
        """
        let payload = try CodebuffUsageFetcher._parseSubscriptionPayloadForTesting(Data(json.utf8))
        #expect(payload.weeklyUsed == nil)
        #expect(payload.weeklyLimit == nil)
        #expect(payload.status == "trialing")
    }

    @Test
    func `snapshot maps to rate window with credits window`() {
        let snapshot = CodebuffUsageSnapshot(
            creditsUsed: 250,
            creditsTotal: 1000,
            creditsRemaining: 750,
            weeklyUsed: 100,
            weeklyLimit: 500,
            tier: "pro",
            autoTopUpEnabled: true,
            updatedAt: Date())

        let unified = snapshot.toUsageSnapshot()
        #expect(unified.primary?.usedPercent == 25)
        #expect(unified.primary?.resetDescription == "250/1,000 credits")
        #expect(unified.secondary?.usedPercent == 20)
        #expect(unified.secondary?.windowMinutes == 7 * 24 * 60)
        #expect(unified.identity?.providerID == .codebuff)
        #expect(unified.identity?.loginMethod?.contains("Pro") == true)
        #expect(unified.identity?.loginMethod?.contains("auto top-up") == true)
    }

    @Test
    func `snapshot infers total from used plus remaining`() {
        let snapshot = CodebuffUsageSnapshot(
            creditsUsed: 40,
            creditsTotal: nil,
            creditsRemaining: 60)

        let unified = snapshot.toUsageSnapshot()
        #expect(unified.primary?.usedPercent == 40)
    }

    @Test
    func `snapshot surfaces exhausted state when quota is missing from payload`() {
        // Only `creditsUsed` is populated (no total, no remaining) — the API response is
        // degenerate but we still want the row to be visible so the user notices the
        // missing configuration instead of seeing an empty/healthy-looking bar.
        let usedOnly = CodebuffUsageSnapshot(
            creditsUsed: 42,
            creditsTotal: nil,
            creditsRemaining: nil)
        #expect(usedOnly.toUsageSnapshot().primary?.usedPercent == 100)

        // Only `creditsRemaining` is populated — same fallback should apply.
        let remainingOnly = CodebuffUsageSnapshot(
            creditsUsed: nil,
            creditsTotal: nil,
            creditsRemaining: 17)
        #expect(remainingOnly.toUsageSnapshot().primary?.usedPercent == 100)
    }

    @Test
    func `snapshot hides credit window when no credit fields are present`() {
        let empty = CodebuffUsageSnapshot()
        #expect(empty.toUsageSnapshot().primary == nil)
    }

    @Test
    func `missing credentials fetch call throws missing credentials`() async {
        do {
            _ = try await CodebuffUsageFetcher.fetchUsage(apiKey: "   ")
            Issue.record("Expected missingCredentials error")
        } catch let error as CodebuffUsageError {
            #expect(error == .missingCredentials)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
