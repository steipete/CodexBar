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

        let snapshot = try CodexOAuthUsageFetcher._decodeRateLimitResetCreditsForTesting(
            Data(json.utf8),
            now: #require(ISO8601DateFormatter().date(from: "2026-07-01T00:00:00Z")))

        #expect(snapshot.availableCount == 2)
        #expect(snapshot.credits.count == 4)
        #expect(snapshot.credits[0].resetType == "codex_rate_limits")
        #expect(snapshot.credits[3].status == .unknown("future_status"))
        #expect(snapshot.nextExpiringAvailableCredit?.id == "RateLimitResetCredit_earlier")
        let later = try #require(ISO8601DateFormatter().date(from: "2026-07-19T00:00:01Z"))
        #expect(snapshot.availableCredits(at: later).isEmpty)
        #expect(snapshot.nextExpiringAvailableCredit(at: later) == nil)
    }

    @Test
    func `consume request scopes auth account and body`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            #expect(request.url?
                .absoluteString == "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits/consume")
            #expect(request.httpMethod == "POST")
            #expect(request.timeoutInterval == 10)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
            #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-ID") == "account-123")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            let body = try #require(request.httpBody)
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
            #expect(json["credit_id"] == "reset-123")
            #expect(json["redeem_request_id"] == "request-123")

            let payload = """
            {
              "code": "reset",
              "windows_reset": 1,
              "credit": {
                "id": "reset-123",
                "reset_type": "codex_rate_limits",
                "status": "redeemed",
                "granted_at": "2026-06-12T04:03:43Z",
                "expires_at": "2026-07-12T04:03:43Z",
                "redeem_started_at": "2026-06-20T04:03:43Z",
                "redeemed_at": "2026-06-20T04:03:44Z",
                "title": "One free rate limit reset",
                "description": null
              }
            }
            """
            return (Data(payload.utf8), HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil)!)
        }

        let result = try await CodexOAuthUsageFetcher.consumeRateLimitResetCredit(
            id: "reset-123",
            accessToken: "test-token",
            accountId: "account-123",
            redeemRequestID: "request-123",
            session: transport)

        #expect(result.code == "reset")
        #expect(result.windowsReset == 1)
        #expect(result.credit?.status == .redeemed)
    }

    @Test
    func `available credits keeps no expiry credits`() throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-07-01T00:00:00Z"))
        let expired = try #require(ISO8601DateFormatter().date(from: "2026-06-17T00:39:53Z"))
        let snapshot = CodexRateLimitResetCreditsSnapshot(
            credits: [
                CodexRateLimitResetCredit(
                    id: "expired",
                    resetType: "codex_rate_limits",
                    status: .available,
                    grantedAt: now,
                    expiresAt: expired,
                    redeemStartedAt: nil,
                    redeemedAt: nil,
                    title: nil,
                    description: nil),
                CodexRateLimitResetCredit(
                    id: "no-expiry",
                    resetType: "codex_rate_limits",
                    status: .available,
                    grantedAt: now,
                    expiresAt: nil,
                    redeemStartedAt: nil,
                    redeemedAt: nil,
                    title: nil,
                    description: nil),
                CodexRateLimitResetCredit(
                    id: "redeemed-no-expiry",
                    resetType: "codex_rate_limits",
                    status: .redeemed,
                    grantedAt: now,
                    expiresAt: nil,
                    redeemStartedAt: nil,
                    redeemedAt: now,
                    title: nil,
                    description: nil),
            ],
            availableCount: 1,
            updatedAt: now)

        #expect(snapshot.availableCredits(at: now).map(\.id) == ["no-expiry"])
        #expect(snapshot.nextExpiringAvailableCredit(at: now)?.id == "no-expiry")
    }
}
