import Foundation
import Testing
@testable import CodexBarCore

struct CodexOAuthCreditLimitTests {
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

    private func makeCredentials() -> CodexOAuthCredentials {
        CodexOAuthCredentials(
            accessToken: "access",
            refreshToken: "refresh",
            idToken: nil,
            accountId: nil,
            lastRefresh: Date())
    }

    @Test
    func `decodes monthly credit limit from rate limit payload`() throws {
        let json = """
        {
          "plan_type": "enterprise",
          "rate_limit": {
            "primary_window": null,
            "secondary_window": null,
            "individual_limit": {
              "limit": 100000,
              "used": "7761",
              "remaining_percent": 92.239,
              "resets_at": 1782864000
            }
          },
          "credits": {
            "has_credits": true,
            "unlimited": false,
            "balance": "0"
          }
        }
        """
        let response = try CodexOAuthUsageFetcher._decodeUsageResponseForTesting(Data(json.utf8))
        #expect(response.rateLimit?.individualLimit?.limit == 100_000)
        #expect(response.rateLimit?.individualLimit?.used == 7761)
        #expect(response.rateLimit?.individualLimit?.remainingPercent == 92.239)
        #expect(response.rateLimit?.individualLimit?.resetsAt == 1_782_864_000)
    }

    @Test
    func `monthly credit limit O auth payload displays limit when balance is zero`() throws {
        let json = """
        {
          "rate_limit": {
            "primary_window": null,
            "secondary_window": null,
            "individual_limit": {
              "limit": 100000,
              "used": 7761,
              "remaining_percent": 92.239,
              "resets_at": 1782864000
            }
          },
          "credits": {
            "has_credits": true,
            "unlimited": false,
            "balance": "0"
          }
        }
        """
        let creds = self.makeCredentials()

        let result = try CodexOAuthFetchStrategy._mapResultForTesting(Data(json.utf8), credentials: creds)

        #expect(result.credits?.remaining == 0)
        #expect(result.credits?.codexCreditLimit?.remaining == 92239)
        #expect(result.credits?.codexCreditLimit?.remainingPercent == 92.239)
        #expect(result.sourceLabel == "oauth")
    }

    @Test
    func `explicit O auth zero credits without monthly limit keeps partial result`() throws {
        let json = """
        {
          "rate_limit": {
            "primary_window": null,
            "secondary_window": null
          },
          "credits": {
            "has_credits": true,
            "unlimited": false,
            "balance": "0"
          }
        }
        """
        let result = try CodexOAuthFetchStrategy._mapResultForTesting(
            Data(json.utf8),
            credentials: self.makeCredentials(),
            sourceMode: .oauth)

        #expect(result.credits?.remaining == 0)
        #expect(result.credits?.codexCreditLimit == nil)
        #expect(result.sourceLabel == "oauth")
    }

    @Test
    func `auto O auth zero credits without monthly limit falls back to CLI`() throws {
        let json = """
        {
          "rate_limit": {
            "primary_window": null,
            "secondary_window": null
          },
          "credits": {
            "has_credits": true,
            "unlimited": false,
            "balance": "0"
          }
        }
        """
        do {
            _ = try CodexOAuthFetchStrategy._mapResultForTesting(
                Data(json.utf8),
                credentials: self.makeCredentials(),
                sourceMode: .auto)
            Issue.record("Expected auto OAuth zero-credit payload to request CLI fallback")
        } catch {
            let strategy = CodexOAuthFetchStrategy()
            let context = self.makeContext(sourceMode: .auto)
            #expect(strategy.shouldFallback(on: error, context: context))
        }
    }
}
