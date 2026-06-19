import CodexBarCore
import Foundation
import Testing

struct CodexBankedResetsModelsTests {
    @Test
    func `decodes endpoint payload into banked resets snapshot`() throws {
        let json = """
        {
          "credits": [
            {
              "id": "RateLimitResetCredit_available",
              "reset_type": "codex_rate_limits",
              "status": "available",
              "granted_at": "2026-06-12T01:29:41.346025Z",
              "expires_at": "2026-07-12T01:29:41.346025Z",
              "title": "One free rate limit reset",
              "description": "Thanks for using Codex!"
            },
            {
              "id": "RateLimitResetCredit_redeemed",
              "reset_type": "codex_rate_limits",
              "status": "redeemed",
              "granted_at": "2026-06-01T00:00:00Z",
              "expires_at": "2026-07-01T00:00:00Z"
            }
          ],
          "available_count": 1
        }
        """
        let updatedAt = try #require(Self.date("2026-06-18T10:00:00Z"))

        let response = try CodexBankedResetsResponse.decodeEndpointPayload(Data(json.utf8))
        let snapshot = response.snapshot(updatedAt: updatedAt)

        #expect(snapshot.availableCount == 1)
        #expect(snapshot.resets.map(\.id) == [
            "RateLimitResetCredit_available",
            "RateLimitResetCredit_redeemed",
        ])
        #expect(snapshot.resets[0].status == .available)
        #expect(snapshot.resets[1].status == .redeemed)
        #expect(snapshot.availableResets.map(\.id) == ["RateLimitResetCredit_available"])
        #expect(snapshot.nextExpiry == Self.date("2026-07-12T01:29:41.346025Z"))
        #expect(snapshot.updatedAt == updatedAt)
    }

    @Test
    func `falls back to local available reset count when endpoint omits available count`() throws {
        let json = """
        {
          "credits": [
            {
              "id": "RateLimitResetCredit_available",
              "status": "available",
              "granted_at": "2026-06-12T01:29:41Z",
              "expires_at": "2026-07-12T01:29:41Z"
            },
            {
              "id": "RateLimitResetCredit_expired_by_status",
              "status": "expired",
              "granted_at": "2026-06-12T01:29:41Z",
              "expires_at": "2026-07-12T01:29:41Z"
            },
            {
              "id": "RateLimitResetCredit_expired_by_date",
              "status": "available",
              "granted_at": "2026-05-12T01:29:41Z",
              "expires_at": "2026-06-12T01:29:41Z"
            },
            {
              "id": "RateLimitResetCredit_unknown",
              "status": "future_server_status",
              "granted_at": "2026-06-12T01:29:41Z",
              "expires_at": "2026-07-13T01:29:41Z"
            },
            {
              "id": "RateLimitResetCredit_redeemed",
              "status": "redeemed",
              "granted_at": "2026-06-12T01:29:41Z",
              "expires_at": "2026-07-14T01:29:41Z"
            }
          ]
        }
        """
        let updatedAt = try #require(Self.date("2026-06-18T10:00:00Z"))

        let response = try CodexBankedResetsResponse.decodeEndpointPayload(Data(json.utf8))
        let snapshot = response.snapshot(updatedAt: updatedAt)

        #expect(snapshot.availableCount == 1)
        #expect(snapshot.availableResets.map(\.id) == [
            "RateLimitResetCredit_available",
        ])
    }

    @Test
    func `keeps unknown reset status without counting it as available`() throws {
        let json = """
        {
          "credits": [
            {
              "id": "RateLimitResetCredit_pending",
              "status": "pending_review",
              "granted_at": "2026-06-12T01:29:41Z",
              "expires_at": "2026-07-12T01:29:41Z"
            }
          ],
          "available_count": 0
        }
        """

        let response = try CodexBankedResetsResponse.decodeEndpointPayload(Data(json.utf8))
        let updatedAt = try #require(Self.date("2026-06-18T10:00:00Z"))
        let snapshot = response.snapshot(updatedAt: updatedAt)

        #expect(response.resets.first?.status == .unknown("pending_review"))
        #expect(snapshot.availableCount == 0)
        #expect(snapshot.availableResets.isEmpty)
    }

    @Test
    func `skips malformed reset entries without dropping the whole response`() throws {
        let json = """
        {
          "credits": [
            {
              "id": "RateLimitResetCredit_available",
              "status": "available",
              "expires_at": "2026-07-12T01:29:41Z"
            },
            {
              "status": "available",
              "expires_at": "2026-07-13T01:29:41Z"
            },
            {
              "id": "RateLimitResetCredit_redeemed",
              "status": "redeemed",
              "expires_at": "2026-07-14T01:29:41Z"
            }
          ],
          "available_count": 1
        }
        """
        let updatedAt = try #require(Self.date("2026-06-18T10:00:00Z"))

        let response = try CodexBankedResetsResponse.decodeEndpointPayload(Data(json.utf8))
        let snapshot = response.snapshot(updatedAt: updatedAt)

        #expect(snapshot.resets.map(\.id) == [
            "RateLimitResetCredit_available",
            "RateLimitResetCredit_redeemed",
        ])
        #expect(snapshot.availableResets.map(\.id) == ["RateLimitResetCredit_available"])
    }

    private static func date(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
