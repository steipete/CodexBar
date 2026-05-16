import Foundation
import Testing
@testable import CodexBarCore

struct GrokAuthTests {
    @Test
    func `parses OIDC SuperGrok entry`() throws {
        let json = #"""
        {
          "https://auth.x.ai::b1a00492-073a-47ea-816f-4c329264a828": {
            "key": "secret-access-token-123",
            "auth_mode": "oidc",
            "create_time": "2026-05-15T13:31:33.384327Z",
            "user_id": "user-uuid",
            "email": "user@example.com",
            "first_name": "Ada",
            "last_name": "Lovelace",
            "team_id": "team-uuid",
            "refresh_token": "refresh-secret",
            "expires_at": "2026-05-22T19:31:33.384327Z",
            "oidc_issuer": "https://auth.x.ai",
            "oidc_client_id": "b1a00492-073a-47ea-816f-4c329264a828"
          }
        }
        """#
        let data = Data(json.utf8)
        let creds = try GrokCredentialsStore.parse(data: data)

        #expect(creds.accessToken == "secret-access-token-123")
        #expect(creds.refreshToken == "refresh-secret")
        #expect(creds.email == "user@example.com")
        #expect(creds.teamId == "team-uuid")
        #expect(creds.authMode == "oidc")
        #expect(creds.displayName == "Ada Lovelace")
        #expect(creds.loginMethod == "SuperGrok")
        #expect(creds.expiresAt != nil)
    }

    @Test
    func `falls back to legacy session scope when OIDC absent`() throws {
        let json = #"""
        {
          "https://accounts.x.ai/sign-in": {
            "key": "legacy-token",
            "auth_mode": "session",
            "email": "legacy@example.com"
          }
        }
        """#
        let data = Data(json.utf8)
        let creds = try GrokCredentialsStore.parse(data: data)
        #expect(creds.accessToken == "legacy-token")
        #expect(creds.email == "legacy@example.com")
        #expect(creds.loginMethod == "session")
    }

    @Test
    func `throws missingTokens when key absent`() {
        let json = #"{"https://auth.x.ai::abc": {"auth_mode": "oidc"}}"#
        let data = Data(json.utf8)
        #expect(throws: GrokCredentialsError.self) {
            _ = try GrokCredentialsStore.parse(data: data)
        }
    }

    @Test
    func `throws decodeFailed when JSON is invalid`() {
        let data = Data("not-json".utf8)
        #expect(throws: GrokCredentialsError.self) {
            _ = try GrokCredentialsStore.parse(data: data)
        }
    }

    @Test
    func `isExpired reflects past expires_at`() throws {
        // Past expiry
        let pastJson = #"""
        {
          "https://auth.x.ai::client": {
            "key": "stale-token",
            "expires_at": "2020-01-01T00:00:00Z"
          }
        }
        """#
        let past = try GrokCredentialsStore.parse(data: Data(pastJson.utf8))
        #expect(past.isExpired == true)

        // Future expiry
        let futureJson = #"""
        {
          "https://auth.x.ai::client": {
            "key": "fresh-token",
            "expires_at": "2099-01-01T00:00:00Z"
          }
        }
        """#
        let future = try GrokCredentialsStore.parse(data: Data(futureJson.utf8))
        #expect(future.isExpired == false)

        // Missing expires_at — treated as non-expired so we never spuriously lock
        // out clients whose auth.json shape predates this field.
        let noExpiryJson = #"""
        {
          "https://auth.x.ai::client": {
            "key": "ageless-token"
          }
        }
        """#
        let noExpiry = try GrokCredentialsStore.parse(data: Data(noExpiryJson.utf8))
        #expect(noExpiry.isExpired == false)
    }

    @Test
    func `expired credentials are preserved when billing succeeds`() throws {
        let pastJson = #"""
        {
          "https://auth.x.ai::client": {
            "key": "stale-token",
            "email": "grok@example.com",
            "team_id": "team_123",
            "expires_at": "2020-01-01T00:00:00Z"
          }
        }
        """#
        let expired = try GrokCredentialsStore.parse(data: Data(pastJson.utf8))
        let billing = try JSONDecoder().decode(GrokBillingResponse.self, from: Data(#"{}"#.utf8))
        let webBilling = GrokWebBillingSnapshot(
            usedPercent: 42,
            resetsAt: Date(timeIntervalSince1970: 1_800_000_000))

        #expect(GrokStatusProbe.credentialsForSnapshot(credentials: expired, billing: nil) == nil)
        #expect(GrokStatusProbe.credentialsForSnapshot(credentials: expired, billing: billing)?
            .email == "grok@example.com")
        #expect(GrokStatusProbe.credentialsForSnapshot(credentials: expired, billing: nil, webBilling: webBilling)?
            .email == "grok@example.com")
    }

    @Test
    func `remote auth failures surface even with fresh local credentials`() {
        #expect(GrokStatusProbe.shouldSurfaceRemoteAuthError(GrokWebBillingError.requestFailed(401, "unauthorized")))
        #expect(GrokStatusProbe.shouldSurfaceRemoteAuthError(GrokWebBillingError.requestFailed(403, "forbidden")))
        #expect(GrokStatusProbe.shouldSurfaceRemoteAuthError(GrokWebBillingError.rpcFailed(16, "token expired")))
        #expect(!GrokStatusProbe.shouldSurfaceRemoteAuthError(GrokWebBillingError.parseFailed))
    }

    @Test
    func `falls back to legacy when OIDC entry has no key`() throws {
        // A stale/partial OIDC record must not shadow a healthy legacy session.
        let json = #"""
        {
          "https://auth.x.ai::stale-client": {
            "auth_mode": "oidc",
            "email": "stale@example.com"
          },
          "https://accounts.x.ai/sign-in": {
            "key": "healthy-legacy-token",
            "auth_mode": "session",
            "email": "healthy@example.com"
          }
        }
        """#
        let data = Data(json.utf8)
        let creds = try GrokCredentialsStore.parse(data: data)
        #expect(creds.accessToken == "healthy-legacy-token")
        #expect(creds.email == "healthy@example.com")
    }

    @Test
    func `prefers OIDC entry over legacy session when both present`() throws {
        let json = #"""
        {
          "https://accounts.x.ai/sign-in": {
            "key": "legacy-should-not-win",
            "auth_mode": "session"
          },
          "https://auth.x.ai::client-id": {
            "key": "oidc-wins",
            "auth_mode": "oidc",
            "email": "preferred@example.com"
          }
        }
        """#
        let data = Data(json.utf8)
        let creds = try GrokCredentialsStore.parse(data: data)
        #expect(creds.accessToken == "oidc-wins")
        #expect(creds.email == "preferred@example.com")
    }
}
