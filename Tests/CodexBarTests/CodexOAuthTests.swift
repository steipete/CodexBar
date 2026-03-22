import Foundation
import Testing
@testable import CodexBarCore

@Suite
struct CodexOAuthTests {
    @Test
    func parsesOAuthCredentials() throws {
        let json = """
        {
          "OPENAI_API_KEY": null,
          "tokens": {
            "access_token": "access-token",
            "refresh_token": "refresh-token",
            "id_token": "id-token",
            "account_id": "account-123"
          },
          "last_refresh": "2025-12-20T12:34:56Z"
        }
        """
        let creds = try CodexOAuthCredentialsStore.parse(data: Data(json.utf8))
        #expect(creds.accessToken == "access-token")
        #expect(creds.refreshToken == "refresh-token")
        #expect(creds.idToken == "id-token")
        #expect(creds.accountId == "account-123")
        #expect(creds.lastRefresh != nil)
    }

    @Test
    func loadsOAuthCredentialsFromRawJSONString() throws {
        let json = """
        {
          "tokens": {
            "access_token": "override-access",
            "refresh_token": "override-refresh",
            "id_token": "override-id-token",
            "account_id": "override-account"
          },
          "last_refresh": "2026-03-01T10:00:00Z"
        }
        """

        let creds = try CodexOAuthCredentialsStore.load(rawSource: json)
        #expect(creds.accessToken == "override-access")
        #expect(creds.refreshToken == "override-refresh")
        #expect(creds.idToken == "override-id-token")
        #expect(creds.accountId == "override-account")
    }

    @Test
    func loadsOAuthCredentialsFromAuthFilePath() throws {
        let tmp = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: URL(fileURLWithPath: NSTemporaryDirectory()),
            create: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let json = """
        {
          "tokens": {
            "access_token": "file-access",
            "refresh_token": "file-refresh"
          }
        }
        """
        let authURL = tmp.appendingPathComponent("auth.json")
        try Data(json.utf8).write(to: authURL)

        let creds = try CodexOAuthCredentialsStore.load(rawSource: authURL.path)
        #expect(creds.accessToken == "file-access")
        #expect(creds.refreshToken == "file-refresh")
    }

    @Test
    func parsesAPIKeyCredentials() throws {
        let json = """
        {
          "OPENAI_API_KEY": "sk-test"
        }
        """
        let creds = try CodexOAuthCredentialsStore.parse(data: Data(json.utf8))
        #expect(creds.accessToken == "sk-test")
        #expect(creds.refreshToken.isEmpty)
        #expect(creds.idToken == nil)
        #expect(creds.accountId == nil)
    }

    @Test
    func decodesCreditsBalanceString() throws {
        let json = """
        {
          "plan_type": "pro",
          "rate_limit": {
            "primary_window": {
              "used_percent": 12,
              "reset_at": 1766948068,
              "limit_window_seconds": 18000
            }
          },
          "credits": {
            "has_credits": false,
            "unlimited": false,
            "balance": "0"
          }
        }
        """
        let response = try CodexOAuthUsageFetcher._decodeUsageResponseForTesting(Data(json.utf8))
        #expect(response.planType?.rawValue == "pro")
        #expect(response.credits?.balance == 0)
        #expect(response.credits?.hasCredits == false)
        #expect(response.credits?.unlimited == false)
    }

    @Test
    func mapsUsageWindowsFromOAuth() throws {
        let json = """
        {
          "rate_limit": {
            "primary_window": {
              "used_percent": 22,
              "reset_at": 1766948068,
              "limit_window_seconds": 18000
            },
            "secondary_window": {
              "used_percent": 43,
              "reset_at": 1767407914,
              "limit_window_seconds": 604800
            }
          }
        }
        """
        let creds = CodexOAuthCredentials(
            accessToken: "access",
            refreshToken: "refresh",
            idToken: nil,
            accountId: nil,
            lastRefresh: Date())
        let snapshot = try CodexOAuthFetchStrategy._mapUsageForTesting(Data(json.utf8), credentials: creds)
        #expect(snapshot.primary?.usedPercent == 22)
        #expect(snapshot.primary?.windowMinutes == 300)
        #expect(snapshot.secondary?.usedPercent == 43)
        #expect(snapshot.secondary?.windowMinutes == 10080)
        #expect(snapshot.primary?.resetsAt != nil)
        #expect(snapshot.secondary?.resetsAt != nil)
    }

    @Test
    func resolvesOAuthClaimsFromJWTs() {
        let access = Self.fakeJWT([
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "account-xyz",
                "chatgpt_plan_type": "plus",
            ],
        ])
        let id = Self.fakeJWT([
            "https://api.openai.com/profile": [
                "email": "oauth@example.com",
            ],
        ])

        #expect(CodexOAuthClaimResolver.accountID(accessToken: access, idToken: id) == "account-xyz")
        #expect(CodexOAuthClaimResolver.email(accessToken: access, idToken: id) == "oauth@example.com")
        #expect(CodexOAuthClaimResolver.plan(accessToken: access, idToken: id) == "plus")
    }

    @Test
    func resolvesChatGPTUsageURLFromConfig() {
        let config = "chatgpt_base_url = \"https://chatgpt.com/backend-api/\"\n"
        let url = CodexOAuthUsageFetcher._resolveUsageURLForTesting(configContents: config)
        #expect(url.absoluteString == "https://chatgpt.com/backend-api/wham/usage")
    }

    @Test
    func resolvesCodexUsageURLFromConfig() {
        let config = "chatgpt_base_url = \"https://api.openai.com\"\n"
        let url = CodexOAuthUsageFetcher._resolveUsageURLForTesting(configContents: config)
        #expect(url.absoluteString == "https://api.openai.com/api/codex/usage")
    }

    @Test
    func normalizesChatGPTBaseURLWithoutBackendAPI() {
        let config = "chatgpt_base_url = \"https://chat.openai.com\"\n"
        let url = CodexOAuthUsageFetcher._resolveUsageURLForTesting(configContents: config)
        #expect(url.absoluteString == "https://chat.openai.com/backend-api/wham/usage")
    }

    private static func fakeJWT(_ payloadObject: [String: Any]) -> String {
        let header = (try? JSONSerialization.data(withJSONObject: ["alg": "none"])) ?? Data()
        let payload = (try? JSONSerialization.data(withJSONObject: payloadObject)) ?? Data()
        func b64(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "=", with: "")
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
        }
        return "\(b64(header)).\(b64(payload))."
    }
}
