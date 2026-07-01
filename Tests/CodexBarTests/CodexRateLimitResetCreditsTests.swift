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

        let now = try #require(ISO8601DateFormatter().date(from: "2026-07-01T00:00:00Z"))
        let snapshot = try CodexOAuthUsageFetcher._decodeRateLimitResetCreditsForTesting(
            Data(json.utf8),
            now: now)

        #expect(snapshot.availableCount == 2)
        #expect(snapshot.credits.count == 4)
        #expect(snapshot.credits[0].resetType == "codex_rate_limits")
        #expect(snapshot.credits[3].status == .unknown("future_status"))
        #expect(snapshot.nextExpiringAvailableCredit?.id == CodexRateLimitResetCredit.stableID(
            forProviderID: "RateLimitResetCredit_earlier"))
        #expect(snapshot.credits.allSatisfy { !$0.id.contains("RateLimitResetCredit_") })

        let usage = UsageSnapshot(
            primary: nil,
            secondary: nil,
            codexResetCredits: snapshot,
            updatedAt: now)
        let encoded = try JSONEncoder().encode(usage)
        let encodedText = try #require(String(data: encoded, encoding: .utf8))
        #expect(!encodedText.contains("RateLimitResetCredit_earlier"))
        #expect(!String(reflecting: usage).contains("RateLimitResetCredit_earlier"))

        let roundTripped = try JSONDecoder().decode(UsageSnapshot.self, from: encoded)
        #expect(roundTripped.codexResetCredits?.credits.map(\.id) == snapshot.credits.map(\.id))
    }

    @Test
    func `available inventory keeps no-expiry credits and sorts deterministically`() {
        let now = Date(timeIntervalSince1970: 1_788_134_400)
        let tiedExpiry = now.addingTimeInterval(3600)
        let snapshot = CodexRateLimitResetCreditsSnapshot(
            credits: [
                Self.credit(id: "nil-b", status: .available, expiresAt: nil),
                Self.credit(id: "expired", status: .available, expiresAt: now),
                Self.credit(id: "finite-b", status: .available, expiresAt: tiedExpiry),
                Self.credit(id: "redeemed", status: .redeemed, expiresAt: now.addingTimeInterval(7200)),
                Self.credit(id: "nil-a", status: .available, expiresAt: nil),
                Self.credit(id: "finite-a", status: .available, expiresAt: tiedExpiry),
            ],
            availableCount: 99,
            updatedAt: now)

        let inventory = snapshot.availableInventory(at: now)

        #expect(inventory.count == 4)
        let expectedFiniteIDs = ["finite-a", "finite-b"]
            .map(CodexRateLimitResetCredit.stableID(forProviderID:))
            .sorted()
        let expectedNoExpiryIDs = ["nil-a", "nil-b"]
            .map(CodexRateLimitResetCredit.stableID(forProviderID:))
            .sorted()
        #expect(inventory.credits.map(\.id) == expectedFiniteIDs + expectedNoExpiryIDs)
        #expect(inventory.nextExpiringCredit?.id == expectedFiniteIDs.first)
    }

    @Test
    func `provider IDs always hash even when shaped like persisted stable IDs`() throws {
        let canonicalLookingRawID = "codex-reset-credit-v1-" + String(repeating: "a", count: 64)
        let json = """
        {
          "credits": [{
            "id": "\(canonicalLookingRawID)",
            "reset_type": "codex_rate_limits",
            "status": "available",
            "granted_at": "2026-06-18T00:39:53Z",
            "expires_at": null
          }],
          "available_count": 1
        }
        """
        let now = Date(timeIntervalSince1970: 1_788_134_400)

        let decoded = try CodexOAuthUsageFetcher._decodeRateLimitResetCreditsForTesting(
            Data(json.utf8),
            now: now)
        let decodedID = try #require(decoded.credits.first?.id)
        let expectedID = CodexRateLimitResetCredit.stableID(forProviderID: canonicalLookingRawID)

        #expect(decodedID == expectedID)
        #expect(decodedID != canonicalLookingRawID)

        let publicModel = Self.credit(id: canonicalLookingRawID, status: .available, expiresAt: nil)
        #expect(publicModel.id == expectedID)
        #expect(publicModel.id != canonicalLookingRawID)

        let encoded = try JSONEncoder().encode(publicModel)
        let roundTripped = try JSONDecoder().decode(CodexRateLimitResetCredit.self, from: encoded)
        #expect(roundTripped.id == expectedID)

        let ordinaryFirst = Self.credit(id: "ordinary-provider-id", status: .available, expiresAt: nil)
        let ordinarySecond = Self.credit(id: "ordinary-provider-id", status: .available, expiresAt: nil)
        #expect(ordinaryFirst.id == ordinarySecond.id)
        #expect(ordinaryFirst.id != "ordinary-provider-id")
    }

    @Test
    func `reset credit GET preserves transport cancellation`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            #expect(request.httpMethod == "GET")
            throw URLError(.cancelled)
        }

        await #expect(throws: CancellationError.self) {
            _ = try await CodexOAuthUsageFetcher.fetchRateLimitResetCredits(
                accessToken: "test-token",
                accountId: "account-123",
                env: ["CODEX_HOME": "/tmp/codexbar-reset-credit-cancellation-test"],
                session: transport)
        }
    }

    private static func credit(
        id: String,
        status: CodexRateLimitResetCreditStatus,
        expiresAt: Date?) -> CodexRateLimitResetCredit
    {
        CodexRateLimitResetCredit(
            id: id,
            resetType: "codex_rate_limits",
            status: status,
            grantedAt: Date(timeIntervalSince1970: 1_788_000_000),
            expiresAt: expiresAt,
            redeemStartedAt: nil,
            redeemedAt: nil,
            title: nil,
            description: nil)
    }
}
