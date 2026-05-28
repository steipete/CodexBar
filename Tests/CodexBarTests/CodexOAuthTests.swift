import Foundation
import Testing
@testable import CodexBarCore

struct CodexOAuthTests {
    private func makeContext(sourceMode: ProviderSourceMode = .auto) -> ProviderFetchContext {
        let browserDetection = BrowserDetection(cacheTTL: 0)
        return ProviderFetchContext(
            runtime: .app,
            sourceMode: sourceMode,
            includeCredits: true,
            webTimeout: 60,
            webDebugDumpHTML: false,
            verbose: false,
            env: [:],
            settings: nil,
            fetcher: UsageFetcher(),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
            browserDetection: browserDetection)
    }

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
    func `decodes prolite plan type without failing usage mapping`() throws {
        let json = """
        {
          "plan_type": "prolite",
          "rate_limit": {
            "primary_window": {
              "used_percent": 12,
              "reset_at": 1766948068,
              "limit_window_seconds": 18000
            }
          }
        }
        """
        let response = try CodexOAuthUsageFetcher._decodeUsageResponseForTesting(Data(json.utf8))
        #expect(response.planType?.rawValue == "prolite")

        let creds = CodexOAuthCredentials(
            accessToken: "access",
            refreshToken: "refresh",
            idToken: nil,
            accountId: nil,
            lastRefresh: Date())
        let mapped = try CodexOAuthFetchStrategy._mapUsageForTesting(Data(json.utf8), credentials: creds)
        #expect(mapped?.primary?.usedPercent == 12)
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
        let mapped = try CodexOAuthFetchStrategy._mapUsageForTesting(Data(json.utf8), credentials: creds)
        let snapshot = try #require(mapped)
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
        let mapped = try CodexOAuthFetchStrategy._mapUsageForTesting(Data(json.utf8), credentials: creds)
        let snapshot = try #require(mapped)
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
        let mapped = try CodexOAuthFetchStrategy._mapUsageForTesting(Data(json.utf8), credentials: creds)
        let snapshot = try #require(mapped)
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
        let mapped = try CodexOAuthFetchStrategy._mapUsageForTesting(Data(json.utf8), credentials: creds)
        let snapshot = try #require(mapped)
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
        let mapped = try CodexOAuthFetchStrategy._mapUsageForTesting(Data(json.utf8), credentials: creds)
        let snapshot = try #require(mapped)
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
        let mapped = try CodexOAuthFetchStrategy._mapUsageForTesting(Data(json.utf8), credentials: creds)
        let snapshot = try #require(mapped)
        #expect(snapshot.primary?.usedPercent == 17)
        #expect(snapshot.primary?.windowMinutes == 540)
        #expect(snapshot.secondary?.usedPercent == 43)
        #expect(snapshot.secondary?.windowMinutes == 10080)
    }

    @Test
    func `returns nil when O auth usage has no windows`() throws {
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
        #expect(snapshot == nil)
    }

    @Test
    func `keeps valid window when secondary window is malformed`() throws {
        let json = """
        {
          "rate_limit": {
            "primary_window": {
              "used_percent": 18,
              "reset_at": 1766948068,
              "limit_window_seconds": 18000
            },
            "secondary_window": {
              "used_percent": "bad",
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
        #expect(snapshot?.primary?.usedPercent == 18)
        #expect(snapshot?.secondary == nil)
    }

    @Test
    func `auto mode keeps weekly window when primary window is malformed`() throws {
        let json = """
        {
          "rate_limit": {
            "primary_window": {
              "used_percent": "bad",
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

        let result = try CodexOAuthFetchStrategy._mapResultForTesting(
            Data(json.utf8),
            credentials: creds,
            sourceMode: .auto)

        #expect(result.usage.primary == nil)
        #expect(result.usage.secondary?.usedPercent == 43)
        #expect(result.usage.secondary?.windowMinutes == 10080)
    }

    @Test
    func `explicit oauth keeps weekly window when primary window is malformed`() throws {
        let json = """
        {
          "rate_limit": {
            "primary_window": {
              "used_percent": "bad",
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

        let result = try CodexOAuthFetchStrategy._mapResultForTesting(
            Data(json.utf8),
            credentials: creds,
            sourceMode: .oauth)

        #expect(result.usage.primary == nil)
        #expect(result.usage.secondary?.usedPercent == 43)
        #expect(result.usage.secondary?.windowMinutes == 10080)
    }

    @Test
    func `auto mode preserves reversed session window when primary window is malformed`() throws {
        let json = """
        {
          "rate_limit": {
            "primary_window": {
              "used_percent": "bad",
              "reset_at": 1767407914,
              "limit_window_seconds": 604800
            },
            "secondary_window": {
              "used_percent": 18,
              "reset_at": 1766948068,
              "limit_window_seconds": 18000
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

        let result = try CodexOAuthFetchStrategy._mapResultForTesting(
            Data(json.utf8),
            credentials: creds,
            sourceMode: .auto)

        #expect(result.usage.primary?.usedPercent == 18)
        #expect(result.usage.primary?.windowMinutes == 300)
        #expect(result.usage.secondary == nil)
    }

    @Test
    func `auto mode keeps weekly window when reversed session window is malformed`() throws {
        let json = """
        {
          "rate_limit": {
            "primary_window": {
              "used_percent": 43,
              "reset_at": 1767407914,
              "limit_window_seconds": 604800
            },
            "secondary_window": {
              "used_percent": "bad",
              "reset_at": 1766948068,
              "limit_window_seconds": 18000
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

        let result = try CodexOAuthFetchStrategy._mapResultForTesting(
            Data(json.utf8),
            credentials: creds,
            sourceMode: .auto)

        #expect(result.usage.primary == nil)
        #expect(result.usage.secondary?.usedPercent == 43)
        #expect(result.usage.secondary?.windowMinutes == 10080)
    }

    @Test
    func `explicit oauth keeps weekly window when reversed session window is malformed`() throws {
        let json = """
        {
          "rate_limit": {
            "primary_window": {
              "used_percent": 43,
              "reset_at": 1767407914,
              "limit_window_seconds": 604800
            },
            "secondary_window": {
              "used_percent": "bad",
              "reset_at": 1766948068,
              "limit_window_seconds": 18000
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

        let result = try CodexOAuthFetchStrategy._mapResultForTesting(
            Data(json.utf8),
            credentials: creds,
            sourceMode: .oauth)

        #expect(result.usage.primary == nil)
        #expect(result.usage.secondary?.usedPercent == 43)
        #expect(result.usage.secondary?.windowMinutes == 10080)
    }

    @Test
    func `ignores malformed credits payload while keeping usage`() throws {
        let json = """
        {
          "rate_limit": {
            "primary_window": {
              "used_percent": 22,
              "reset_at": 1766948068,
              "limit_window_seconds": 18000
            }
          },
          "credits": {
            "has_credits": false,
            "unlimited": false,
            "balance": []
          }
        }
        """
        let response = try CodexOAuthUsageFetcher._decodeUsageResponseForTesting(Data(json.utf8))
        #expect(response.credits?.hasCredits == false)
        #expect(response.credits?.unlimited == false)
        #expect(response.credits?.balance == nil)

        let creds = CodexOAuthCredentials(
            accessToken: "access",
            refreshToken: "refresh",
            idToken: nil,
            accountId: nil,
            lastRefresh: Date())
        let snapshot = try CodexOAuthFetchStrategy._mapUsageForTesting(Data(json.utf8), credentials: creds)
        #expect(snapshot?.primary?.usedPercent == 22)
    }

    @Test
    func `credits only O auth payload still returns credits result`() throws {
        let json = """
        {
          "rate_limit": {
            "primary_window": null,
            "secondary_window": null
          },
          "credits": {
            "has_credits": true,
            "unlimited": false,
            "balance": "14.5"
          }
        }
        """
        let creds = CodexOAuthCredentials(
            accessToken: "access",
            refreshToken: "refresh",
            idToken: nil,
            accountId: nil,
            lastRefresh: Date())

        let result = try CodexOAuthFetchStrategy._mapResultForTesting(Data(json.utf8), credentials: creds)

        #expect(result.usage.primary == nil)
        #expect(result.usage.secondary == nil)
        #expect(result.credits?.remaining == 14.5)
        #expect(result.sourceLabel == "oauth")
    }

    @Test
    func `credits only O auth payload returns credits in auto mode`() throws {
        let json = """
        {
          "rate_limit": {
            "primary_window": null,
            "secondary_window": null
          },
          "credits": {
            "has_credits": true,
            "unlimited": false,
            "balance": "14.5"
          }
        }
        """
        let creds = CodexOAuthCredentials(
            accessToken: "access",
            refreshToken: "refresh",
            idToken: nil,
            accountId: nil,
            lastRefresh: Date())

        let result = try CodexOAuthFetchStrategy._mapResultForTesting(
            Data(json.utf8),
            credentials: creds,
            sourceMode: .auto)

        #expect(result.usage.primary == nil)
        #expect(result.usage.secondary == nil)
        #expect(result.credits?.remaining == 14.5)
        #expect(result.sourceLabel == "oauth")
    }

    @Test
    func `auto mode only falls back from O auth on auth failures`() {
        let strategy = CodexOAuthFetchStrategy()
        let context = self.makeContext(sourceMode: .auto)

        #expect(strategy.shouldFallback(on: CodexOAuthFetchError.unauthorized, context: context))
        #expect(strategy.shouldFallback(on: CodexOAuthCredentialsError.notFound, context: context))
        #expect(strategy.shouldFallback(on: CodexOAuthCredentialsError.missingTokens, context: context))
        #expect(strategy.shouldFallback(on: CodexTokenRefresher.RefreshError.expired, context: context))
        #expect(strategy.shouldFallback(on: CodexTokenRefresher.RefreshError.revoked, context: context))
        #expect(strategy.shouldFallback(on: CodexTokenRefresher.RefreshError.reused, context: context))

        #expect(!strategy.shouldFallback(on: UsageError.noRateLimitsFound, context: context))
        #expect(!strategy.shouldFallback(on: CodexOAuthCredentialsError.decodeFailed("bad json"), context: context))
        #expect(!strategy.shouldFallback(on: CodexOAuthFetchError.invalidResponse, context: context))
        #expect(!strategy.shouldFallback(on: CodexOAuthFetchError.serverError(500, "offline"), context: context))
        #expect(!strategy.shouldFallback(
            on: CodexOAuthFetchError.networkError(URLError(.notConnectedToInternet)),
            context: context))
        #expect(!strategy.shouldFallback(
            on: CodexTokenRefresher.RefreshError.networkError(URLError(.timedOut)),
            context: context))
    }

    @Test
    func `non 401 invalid grant refresh failure is treated as revoked`() {
        let data = Data(#"{"error":"invalid_grant"}"#.utf8)
        let error = CodexTokenRefresher._refreshFailureErrorForTesting(statusCode: 400, data: data)

        switch error {
        case .revoked:
            break
        default:
            Issue.record("Expected invalid_grant to be treated as revoked")
        }
    }

    @Test
    func `non auth refresh failure remains invalid response`() {
        let data = Data(#"{"error":"invalid_request"}"#.utf8)
        let error = CodexTokenRefresher._refreshFailureErrorForTesting(statusCode: 400, data: data)

        switch error {
        case let .invalidResponse(message):
            #expect(message == "Status 400")
        default:
            Issue.record("Expected invalid_request to remain an invalid response")
        }
    }

    @Test
    func `explicit O auth mode never falls back to CLI`() {
        let strategy = CodexOAuthFetchStrategy()
        let context = self.makeContext(sourceMode: .oauth)

        #expect(!strategy.shouldFallback(on: CodexOAuthFetchError.unauthorized, context: context))
        #expect(!strategy.shouldFallback(on: CodexTokenRefresher.RefreshError.expired, context: context))
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
