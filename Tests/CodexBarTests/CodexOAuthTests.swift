import Foundation
import Testing
@testable import CodexBarCore

struct CodexOAuthTests {
    @Test
    func `parses O auth credentials`() throws {
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
    func `parses legacy camel case O auth credentials`() throws {
        let json = """
        {
          "OPENAI_API_KEY": null,
          "tokens": {
            "accessToken": "access-token",
            "refreshToken": "refresh-token",
            "idToken": "id-token",
            "accountId": "account-123"
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
    func `parses API key credentials`() throws {
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
    func `decodes credits balance string`() throws {
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
    func `maps usage windows from O auth`() throws {
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
    func `maps free weekly only window into secondary`() throws {
        let json = """
        {
          "plan_type": "free",
          "rate_limit": {
            "primary_window": {
              "used_percent": 0,
              "reset_at": 1775468693,
              "limit_window_seconds": 604800
            },
            "secondary_window": null
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
        #expect(snapshot.primary == nil)
        #expect(snapshot.secondary?.usedPercent == 0)
        #expect(snapshot.secondary?.windowMinutes == 10080)
    }

    @Test
    func `keeps single session window as primary`() throws {
        let json = """
        {
          "rate_limit": {
            "primary_window": {
              "used_percent": 9,
              "reset_at": 1766948068,
              "limit_window_seconds": 18000
            },
            "secondary_window": null
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
        #expect(snapshot.primary?.usedPercent == 9)
        #expect(snapshot.primary?.windowMinutes == 300)
        #expect(snapshot.secondary == nil)
    }

    @Test
    func `preserves unknown single window as primary`() throws {
        let json = """
        {
          "rate_limit": {
            "primary_window": {
              "used_percent": 17,
              "reset_at": 1766948068,
              "limit_window_seconds": 32400
            },
            "secondary_window": null
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
        #expect(snapshot.primary?.usedPercent == 17)
        #expect(snapshot.primary?.windowMinutes == 540)
        #expect(snapshot.secondary == nil)
    }

    @Test
    func `preserves unknown secondary only window as primary`() throws {
        let json = """
        {
          "rate_limit": {
            "primary_window": null,
            "secondary_window": {
              "used_percent": 17,
              "reset_at": 1766948068,
              "limit_window_seconds": 32400
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
        #expect(snapshot.primary?.usedPercent == 17)
        #expect(snapshot.primary?.windowMinutes == 540)
        #expect(snapshot.secondary == nil)
    }

    @Test
    func `swaps reversed weekly and unknown windows`() throws {
        let json = """
        {
          "rate_limit": {
            "primary_window": {
              "used_percent": 43,
              "reset_at": 1767407914,
              "limit_window_seconds": 604800
            },
            "secondary_window": {
              "used_percent": 17,
              "reset_at": 1766948068,
              "limit_window_seconds": 32400
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
        #expect(snapshot.primary?.usedPercent == 17)
        #expect(snapshot.primary?.windowMinutes == 540)
        #expect(snapshot.secondary?.usedPercent == 43)
        #expect(snapshot.secondary?.windowMinutes == 10080)
    }

    @Test
    func `synthesizes empty primary window when O auth usage has no windows`() throws {
        let json = """
        {
          "rate_limit": {
            "primary_window": null,
            "secondary_window": null
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
        #expect(snapshot.primary?.usedPercent == 0)
        #expect(snapshot.primary?.windowMinutes == nil)
        #expect(snapshot.primary?.resetsAt == nil)
        #expect(snapshot.primary?.resetDescription == nil)
        #expect(snapshot.secondary == nil)
    }

    @Test
    func `resolves chat GPT usage URL from config`() {
        let config = "chatgpt_base_url = \"https://chatgpt.com/backend-api/\"\n"
        let url = CodexOAuthUsageFetcher._resolveUsageURLForTesting(configContents: config)
        #expect(url.absoluteString == "https://chatgpt.com/backend-api/wham/usage")
    }

    @Test
    func `resolves codex usage URL from config`() {
        let config = "chatgpt_base_url = \"https://api.openai.com\"\n"
        let url = CodexOAuthUsageFetcher._resolveUsageURLForTesting(configContents: config)
        #expect(url.absoluteString == "https://api.openai.com/api/codex/usage")
    }

    @Test
    func `normalizes chat GPT base URL without backend API`() {
        let config = "chatgpt_base_url = \"https://chat.openai.com\"\n"
        let url = CodexOAuthUsageFetcher._resolveUsageURLForTesting(configContents: config)
        #expect(url.absoluteString == "https://chat.openai.com/backend-api/wham/usage")
    }
}
