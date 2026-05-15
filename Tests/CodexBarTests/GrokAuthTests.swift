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
