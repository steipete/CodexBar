import Foundation
import Testing
@testable import CodexBarCore

struct CopilotUsageFetcherTests {
    @Test
    func `fetchGitHubIdentity uses shared client`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            guard request.value(forHTTPHeaderField: "Authorization") == "token abc123" else {
                throw URLError(.userAuthenticationRequired)
            }
            let response = try HTTPURLResponse(
                url: #require(request.url),
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!
            return (Data(#"{"login":"testuser","id":123}"#.utf8), response)
        }

        let identity = try await CopilotUsageFetcher.fetchGitHubIdentity(token: "abc123", transport: transport)

        #expect(identity.login == "testuser")
        #expect(identity.id == 123)
        let requests = await transport.requests()
        #expect(requests.count == 1)
        #expect(requests.first?.url?.host == "api.github.com")
    }

    @Test
    func `fetch returns unavailable snapshot for business token billing placeholders`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "token gh-token")
            let response = try HTTPURLResponse(
                url: #require(request.url),
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!
            let data = Data(
                """
                {
                  "copilot_plan": "business",
                  "token_based_billing": true,
                  "quota_snapshots": {
                    "premium_interactions": {
                      "entitlement": 0,
                      "remaining": 0,
                      "percent_remaining": 100,
                      "quota_id": "premium_interactions"
                    },
                    "chat": {
                      "entitlement": 0,
                      "remaining": 0,
                      "percent_remaining": 100,
                      "quota_id": "chat"
                    }
                  }
                }
                """.utf8)
            return (data, response)
        }
        let fetcher = CopilotUsageFetcher(token: "gh-token", transport: transport)

        let snapshot = try await fetcher.fetch()

        #expect(snapshot.primary == nil)
        #expect(snapshot.secondary == nil)
        #expect(snapshot.identity?.loginMethod == "Business")
    }

    @Test
    func `fetch keeps explicitly unlimited chat quota`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "token gh-token")
            let response = try HTTPURLResponse(
                url: #require(request.url),
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!
            let data = Data(
                """
                {
                  "copilot_plan": "individual",
                  "quota_reset_date": "2026-07-01",
                  "quota_snapshots": {
                    "chat_messages": {
                      "entitlement": 0,
                      "remaining": 0,
                      "quota_id": "chat_messages",
                      "unlimited": true
                    }
                  }
                }
                """.utf8)
            return (data, response)
        }
        let fetcher = CopilotUsageFetcher(token: "gh-token", transport: transport)

        let snapshot = try await fetcher.fetch()

        #expect(snapshot.primary == nil)
        #expect(snapshot.secondary?.usedPercent == 0)
        #expect(snapshot.secondary?.resetsAt == nil)
        #expect(snapshot.identity?.loginMethod == "Individual")
    }

    @Test
    func `fetch attaches quota reset date to copilot windows`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "token gh-token")
            let response = try HTTPURLResponse(
                url: #require(request.url),
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!
            let data = Data(
                """
                {
                  "copilot_plan": "individual",
                  "quota_reset_date": "2026-07-01",
                  "quota_snapshots": {
                    "premium_interactions": {
                      "entitlement": 500,
                      "remaining": 125,
                      "percent_remaining": 25,
                      "quota_id": "premium_interactions"
                    },
                    "chat": {
                      "entitlement": 300,
                      "remaining": 240,
                      "percent_remaining": 80,
                      "quota_id": "chat"
                    }
                  }
                }
                """.utf8)
            return (data, response)
        }
        let fetcher = CopilotUsageFetcher(token: "gh-token", transport: transport)
        let expectedReset = try #require(CopilotUsageFetcher.parseQuotaResetDate("2026-07-01"))

        let snapshot = try await fetcher.fetch()

        #expect(snapshot.primary?.usedPercent == 75)
        #expect(snapshot.primary?.resetsAt == expectedReset)
        #expect(snapshot.secondary?.usedPercent == 20)
        #expect(snapshot.secondary?.resetsAt == expectedReset)
    }

    @Test
    func `makeRateWindow drops business token billing placeholder quota`() {
        // entitlement=0/remaining=0/percent_remaining=100 must not become a "0% used"
        // rate window for Copilot Business token-based billing accounts. (#1258)
        let placeholder = CopilotUsageResponse.QuotaSnapshot(
            entitlement: 0,
            remaining: 0,
            percentRemaining: 100,
            quotaId: "premium_interactions")
        #expect(CopilotUsageFetcher.makeRateWindow(from: placeholder) == nil)
    }

    @Test
    func `makeRateWindow keeps real quota window`() {
        let real = CopilotUsageResponse.QuotaSnapshot(
            entitlement: 500,
            remaining: 125,
            percentRemaining: 25,
            quotaId: "premium_interactions")
        let window = CopilotUsageFetcher.makeRateWindow(from: real)
        #expect(window?.usedPercent == 75)
    }

    @Test
    func `makeRateWindow carries reset date`() {
        let resetDate = Date(timeIntervalSince1970: 1_783_468_800)
        let real = CopilotUsageResponse.QuotaSnapshot(
            entitlement: 500,
            remaining: 125,
            percentRemaining: 25,
            quotaId: "premium_interactions")

        let window = CopilotUsageFetcher.makeRateWindow(from: real, resetsAt: resetDate)

        #expect(window?.usedPercent == 75)
        #expect(window?.resetsAt == resetDate)
    }

    @Test
    func `parseQuotaResetDate supports date only and ISO timestamps`() throws {
        let dateOnly = try #require(ISO8601DateFormatter().date(from: "2026-07-01T00:00:00Z"))
        let iso = try #require(ISO8601DateFormatter().date(from: "2026-07-01T08:30:45Z"))
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fractionalISO = try #require(fractionalFormatter.date(from: "2026-07-01T08:30:45.123Z"))

        #expect(CopilotUsageFetcher.parseQuotaResetDate("2026-07-01") == dateOnly)
        #expect(CopilotUsageFetcher.parseQuotaResetDate("2026-07-01T08:30:45Z") == iso)
        #expect(CopilotUsageFetcher.parseQuotaResetDate("2026-07-01T08:30:45.123Z") == fractionalISO)
        #expect(CopilotUsageFetcher.parseQuotaResetDate(" ") == nil)
    }
}
