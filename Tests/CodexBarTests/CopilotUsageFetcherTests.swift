import Foundation
import Testing
@testable import CodexBarCore

struct CopilotUsageFetcherTests {
    @Test
    func `fetchGitHubIdentity uses shared client`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            guard request.value(forHTTPHeaderField: "Authorization") == "token test-token-placeholder" else {
                throw URLError(.userAuthenticationRequired)
            }
            let response = try HTTPURLResponse(
                url: #require(request.url),
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!
            return (Data(#"{"login":"testuser","id":123}"#.utf8), response)
        }

        let identity = try await CopilotUsageFetcher.fetchGitHubIdentity(
            token: "test-token-placeholder",
            transport: transport)

        #expect(identity.login == "testuser")
        #expect(identity.id == 123)
        let requests = await transport.requests()
        #expect(requests.count == 1)
        #expect(requests.first?.url?.host == "api.github.com")
    }

    @Test
    func `fetch returns unavailable snapshot for business token billing placeholders`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "token test-token-placeholder")
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
        let fetcher = CopilotUsageFetcher(token: "test-token-placeholder", transport: transport)

        let snapshot = try await fetcher.fetch()

        #expect(snapshot.primary == nil)
        #expect(snapshot.secondary == nil)
        #expect(snapshot.identity?.loginMethod == "Business")
    }

    @Test
    func `fetch omits explicitly unlimited only chat quota without failing`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "token test-token-placeholder")
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
        let fetcher = CopilotUsageFetcher(token: "test-token-placeholder", transport: transport)

        let snapshot = try await fetcher.fetch()

        #expect(snapshot.primary == nil)
        #expect(snapshot.secondary == nil)
        #expect(snapshot.identity?.loginMethod == "Individual")
    }

    @Test
    func `fetch keeps finite premium quota and omits unlimited chat quota`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "token test-token-placeholder")
            let response = try HTTPURLResponse(
                url: #require(request.url),
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!
            let data = Data(
                """
                {
                  "copilot_plan": "individual",
                  "quota_reset_date": "2026-08-01T00:00:00Z",
                  "quota_snapshots": {
                    "premium_interactions": {
                      "entitlement": 200,
                      "remaining": 156.2,
                      "percent_remaining": 78.1,
                      "quota_id": "premium_interactions"
                    },
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
        let fetcher = CopilotUsageFetcher(token: "test-token-placeholder", transport: transport)
        let expectedReset = try #require(CopilotUsageFetcher.parseQuotaResetDate("2026-08-01T00:00:00Z"))

        let snapshot = try await fetcher.fetch()

        let usedPercent = try #require(snapshot.primary?.usedPercent)
        #expect(abs(usedPercent - 21.9) < 0.0001)
        #expect(snapshot.primary?.resetsAt == expectedReset)
        #expect(snapshot.secondary == nil)
    }

    @Test
    func `fetch uses finite monthly chat quota when direct chat quota is unlimited`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "token test-token-placeholder")
            let response = try HTTPURLResponse(
                url: #require(request.url),
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!
            let data = Data(
                """
                {
                  "copilot_plan": "individual",
                  "quota_snapshots": {
                    "chat_messages": {
                      "entitlement": 0,
                      "remaining": 0,
                      "quota_id": "chat_messages",
                      "unlimited": true
                    }
                  },
                  "monthly_quotas": {
                    "chat": 100
                  },
                  "limited_user_quotas": {
                    "chat": 60
                  }
                }
                """.utf8)
            return (data, response)
        }
        let fetcher = CopilotUsageFetcher(token: "test-token-placeholder", transport: transport)

        let snapshot = try await fetcher.fetch()

        #expect(snapshot.primary == nil)
        #expect(snapshot.secondary?.usedPercent == 40)
    }

    @Test
    func `fetch attaches quota reset date to copilot windows`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "token test-token-placeholder")
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
        let fetcher = CopilotUsageFetcher(token: "test-token-placeholder", transport: transport)
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
    func `makeRateWindow drops unlimited quota`() {
        let unlimited = CopilotUsageResponse.QuotaSnapshot(
            entitlement: 0,
            remaining: 0,
            percentRemaining: 0,
            quotaId: "chat_messages",
            unlimited: true)

        #expect(CopilotUsageFetcher.makeRateWindow(from: unlimited) == nil)
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
    func `fetch surfaces seat credits for token billing accounts`() async throws {
        let transport = ProviderHTTPTransportStub { request in
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
                  "quota_reset_date": "2026-09-01",
                  "organization_login_list": ["example-org"],
                  "quota_snapshots": {
                    "premium_interactions": {
                      "entitlement": 0, "remaining": 0, "percent_remaining": 100,
                      "quota_id": "premium_interactions", "unlimited": true, "credits_used": 31
                    }
                  }
                }
                """.utf8)
            return (data, response)
        }

        let usage = try await CopilotUsageFetcher(
            token: "test-token-placeholder",
            seatEntitlement: 3000,
            transport: transport)
            .fetch()

        #expect(usage.copilotCredits?.seat?.creditsUsed == 31)
        #expect(usage.copilotCredits?.seat?.entitlement == 3000)
        #expect(usage.copilotCredits?.orgLogin == "example-org")
        // Regression guard for #1258: credits must not resurrect a fake quota bar.
        #expect(usage.primary == nil)
        #expect(usage.secondary == nil)
    }

    @Test
    func `fetch omits credits when the payload has none`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            let response = try HTTPURLResponse(
                url: #require(request.url),
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!
            let data = Data(
                """
                {
                  "copilot_plan": "individual",
                  "quota_snapshots": {
                    "premium_interactions": {
                      "entitlement": 300, "remaining": 150, "percent_remaining": 50,
                      "quota_id": "premium_interactions"
                    }
                  }
                }
                """.utf8)
            return (data, response)
        }

        let usage = try await CopilotUsageFetcher(
            token: "test-token-placeholder",
            transport: transport)
            .fetch()

        #expect(usage.copilotCredits == nil)
        // Metered accounts keep their real bar.
        #expect(usage.primary?.usedPercent == 50)
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
