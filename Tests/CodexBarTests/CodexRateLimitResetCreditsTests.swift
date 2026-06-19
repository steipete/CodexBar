import Foundation
import Testing
@testable import CodexBarCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct CodexRateLimitResetCreditsTests {
    @Test
    func `resolves URL from chat GPT config`() {
        let config = "chatgpt_base_url = \"https://chatgpt.com/backend-api/\"\n"
        let url = CodexOAuthUsageFetcher._resolveRateLimitResetCreditsURLForTesting(configContents: config)
        #expect(url.absoluteString == "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")
    }

    @Test
    func `request scopes auth and account with bounded timeout`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            #expect(request.url?.absoluteString == "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")
            #expect(request.httpMethod == "GET")
            #expect(request.timeoutInterval == 4)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
            #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-ID") == "account-123")
            #expect(request.value(forHTTPHeaderField: "OpenAI-Beta") == "codex-1")
            #expect(request.value(forHTTPHeaderField: "originator") == "Codex Desktop")
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil))
            return (Data(#"{"credits":[],"available_count":0}"#.utf8), response)
        }

        let snapshot = try await CodexOAuthUsageFetcher.fetchRateLimitResetCredits(
            accessToken: "test-token",
            accountId: "account-123",
            env: ["CODEX_HOME": "/tmp/codexbar-reset-credit-request-test"],
            session: transport)

        #expect(snapshot.availableCount == 0)
        #expect(await transport.requests().count == 1)
    }

    @Test
    func `rejects negative available count`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil))
            return (Data(#"{"credits":[],"available_count":-1}"#.utf8), response)
        }

        do {
            _ = try await CodexOAuthUsageFetcher.fetchRateLimitResetCredits(
                accessToken: "test-token",
                accountId: nil,
                env: ["CODEX_HOME": "/tmp/codexbar-negative-reset-credit-test"],
                session: transport)
            Issue.record("Expected invalid response")
        } catch CodexOAuthFetchError.invalidResponse {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func `decodes credits and skips stale available expiry`() throws {
        let json = """
        {
          "credits": [
            {
              "id": "RateLimitResetCredit_expired_available",
              "reset_type": "codex_rate_limits",
              "status": "available",
              "granted_at": "2026-05-18T00:39:53Z",
              "expires_at": "2026-06-17T00:39:53Z"
            },
            {
              "id": "RateLimitResetCredit_later",
              "reset_type": "codex_rate_limits",
              "status": "available",
              "granted_at": "2026-06-18T00:39:53.731630Z",
              "expires_at": "2026-07-18T00:39:53.731630Z",
              "redeem_started_at": null,
              "redeemed_at": null,
              "profile_image_url": "https://example.com/codex.png",
              "profile_user_id": "Codex Team",
              "title": "One free rate limit reset",
              "description": "Thanks for using Codex!"
            },
            {
              "id": "RateLimitResetCredit_earlier",
              "reset_type": "codex_rate_limits",
              "status": "available",
              "granted_at": "2026-06-12T04:03:43.263391Z",
              "expires_at": "2026-07-12T04:03:43.263391Z",
              "redeem_started_at": null,
              "redeemed_at": null,
              "title": "One free rate limit reset",
              "description": "Thanks for using Codex!"
            },
            {
              "id": "RateLimitResetCredit_future_status",
              "reset_type": "codex_rate_limits",
              "status": "future_status",
              "granted_at": "2026-06-12T04:03:43Z",
              "expires_at": "2026-07-10T04:03:43Z",
              "redeem_started_at": null,
              "redeemed_at": null,
              "title": "One free rate limit reset",
              "description": "Thanks for using Codex!"
            }
          ],
          "available_count": 2
        }
        """

        let snapshot = try CodexOAuthUsageFetcher._decodeRateLimitResetCreditsForTesting(Data(json.utf8))

        #expect(snapshot.availableCount == 2)
        #expect(snapshot.credits.count == 4)
        #expect(snapshot.credits[0].resetType == "codex_rate_limits")
        #expect(snapshot.credits[3].status == .unknown("future_status"))
        #expect(snapshot.nextExpiringAvailableCredit?.id == "RateLimitResetCredit_earlier")
    }
}
