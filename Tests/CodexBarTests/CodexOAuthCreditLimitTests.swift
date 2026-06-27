import Foundation
import Testing
@testable import CodexBarCore

struct CodexOAuthCreditLimitTests {
    private struct StubFetchStrategy: ProviderFetchStrategy {
        let id = "stub.cli"
        let kind: ProviderFetchKind = .cli
        let available: Bool
        let result: ProviderFetchResult?

        func isAvailable(_: ProviderFetchContext) async -> Bool {
            self.available
        }

        func fetch(_: ProviderFetchContext) async throws -> ProviderFetchResult {
            guard let result else { throw UsageError.noRateLimitsFound }
            return result
        }

        func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
            false
        }
    }

    private func makeContext(
        sourceMode: ProviderSourceMode = .auto,
        includeCredits: Bool = true) -> ProviderFetchContext
    {
        let browserDetection = BrowserDetection(cacheTTL: 0)
        return ProviderFetchContext(
            runtime: .app,
            sourceMode: sourceMode,
            includeCredits: includeCredits,
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

    private func makeCLIResult(
        credits: CreditsSnapshot?,
        email: String? = nil) -> ProviderFetchResult
    {
        ProviderFetchResult(
            usage: UsageSnapshot(
                primary: nil,
                secondary: nil,
                updatedAt: Date(),
                identity: email.map {
                    ProviderIdentitySnapshot(
                        providerID: .codex,
                        accountEmail: $0,
                        accountOrganization: nil,
                        loginMethod: "enterprise")
                }),
            credits: credits,
            dashboard: nil,
            sourceLabel: "codex-cli",
            strategyID: "stub.cli",
            strategyKind: .cli)
    }

    private func replacingIdentity(
        _ result: ProviderFetchResult,
        email: String) -> ProviderFetchResult
    {
        ProviderFetchResult(
            usage: result.usage.withIdentity(ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: email,
                accountOrganization: nil,
                loginMethod: "enterprise")),
            credits: result.credits,
            dashboard: result.dashboard,
            sourceLabel: result.sourceLabel,
            strategyID: result.strategyID,
            strategyKind: result.strategyKind)
    }

    private func makeMonthlyLimitCredits() -> CreditsSnapshot {
        let now = Date()
        let limit = CodexCreditLimitSnapshot(
            used: 250,
            limit: 1000,
            remainingPercent: 75,
            resetsAt: nil,
            updatedAt: now)
        return CreditsSnapshot(
            remaining: limit.remaining,
            events: [],
            updatedAt: now,
            codexCreditLimit: limit)
    }

    private func oauthZeroCreditRateWindowJSON() -> String {
        """
        {
          "rate_limit": {
            "primary_window": {
              "used_percent": 12,
              "reset_at": 1766948068,
              "limit_window_seconds": 18000
            },
            "secondary_window": null
          },
          "credits": {
            "has_credits": true,
            "unlimited": false,
            "balance": "0"
          }
        }
        """
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
    func `auto O auth zero credits preserves O auth usage while adding CLI monthly limit`() async throws {
        let mappedOAuth = try CodexOAuthFetchStrategy._mapResultForTesting(
            Data(self.oauthZeroCreditRateWindowJSON().utf8),
            credentials: self.makeCredentials(),
            sourceMode: .auto)
        let oauthResult = self.replacingIdentity(mappedOAuth, email: "owner@example.com")
        let cliResult = self.makeCLIResult(
            credits: self.makeMonthlyLimitCredits(),
            email: "owner@example.com")

        let result = try await CodexOAuthFetchStrategy._replaceWithCLIMonthlyLimitForTesting(
            oauthResult: oauthResult,
            context: self.makeContext(sourceMode: .auto),
            cliStrategy: StubFetchStrategy(available: true, result: cliResult))

        #expect(oauthResult.usage.primary != nil)
        #expect(CodexOAuthFetchStrategy._shouldTryCLIForMonthlyLimitForTesting(oauthResult))
        #expect(result.sourceLabel == "oauth")
        #expect(result.strategyKind == .oauth)
        #expect(result.usage.primary == oauthResult.usage.primary)
        #expect(result.credits?.remaining == oauthResult.credits?.remaining)
        #expect(result.credits?.codexCreditLimit?.remaining == 750)
    }

    @Test
    func `usage-only O auth refresh does not launch CLI monthly limit enrichment`() async throws {
        let mappedOAuth = try CodexOAuthFetchStrategy._mapResultForTesting(
            Data(self.oauthZeroCreditRateWindowJSON().utf8),
            credentials: self.makeCredentials(),
            sourceMode: .auto)
        let oauthResult = self.replacingIdentity(mappedOAuth, email: "owner@example.com")
        let cliResult = self.makeCLIResult(
            credits: self.makeMonthlyLimitCredits(),
            email: "owner@example.com")

        let result = try await CodexOAuthFetchStrategy._replaceWithCLIMonthlyLimitForTesting(
            oauthResult: oauthResult,
            context: self.makeContext(sourceMode: .auto, includeCredits: false),
            cliStrategy: StubFetchStrategy(available: true, result: cliResult))

        #expect(result.sourceLabel == "oauth")
        #expect(result.usage.primary == oauthResult.usage.primary)
        #expect(result.credits?.codexCreditLimit == nil)
    }

    @Test
    func `auto O auth zero credits rejects CLI monthly limit without verified identity`() async throws {
        let mappedOAuth = try CodexOAuthFetchStrategy._mapResultForTesting(
            Data(self.oauthZeroCreditRateWindowJSON().utf8),
            credentials: self.makeCredentials(),
            sourceMode: .auto)
        let oauthResult = self.replacingIdentity(mappedOAuth, email: "owner@example.com")
        let cliResult = self.makeCLIResult(credits: self.makeMonthlyLimitCredits())

        let result = try await CodexOAuthFetchStrategy._replaceWithCLIMonthlyLimitForTesting(
            oauthResult: oauthResult,
            context: self.makeContext(sourceMode: .auto),
            cliStrategy: StubFetchStrategy(available: true, result: cliResult))

        #expect(result.sourceLabel == "oauth")
        #expect(result.usage.identity?.accountEmail == "owner@example.com")
        #expect(result.credits?.codexCreditLimit == nil)
    }

    @Test
    func `auto O auth zero credits rejects CLI monthly limit from another account`() async throws {
        let mappedOAuth = try CodexOAuthFetchStrategy._mapResultForTesting(
            Data(self.oauthZeroCreditRateWindowJSON().utf8),
            credentials: self.makeCredentials(),
            sourceMode: .auto)
        let oauthResult = self.replacingIdentity(mappedOAuth, email: "owner@example.com")
        let cliResult = self.makeCLIResult(
            credits: self.makeMonthlyLimitCredits(),
            email: "other@example.com")

        let result = try await CodexOAuthFetchStrategy._replaceWithCLIMonthlyLimitForTesting(
            oauthResult: oauthResult,
            context: self.makeContext(sourceMode: .auto),
            cliStrategy: StubFetchStrategy(available: true, result: cliResult))

        #expect(result.sourceLabel == "oauth")
        #expect(result.usage.identity?.accountEmail == "owner@example.com")
        #expect(result.credits?.codexCreditLimit == nil)
    }

    @Test
    func `auto O auth zero credits accepts matching CLI account case insensitively`() async throws {
        let mappedOAuth = try CodexOAuthFetchStrategy._mapResultForTesting(
            Data(self.oauthZeroCreditRateWindowJSON().utf8),
            credentials: self.makeCredentials(),
            sourceMode: .auto)
        let oauthResult = self.replacingIdentity(mappedOAuth, email: "Owner@Example.com")
        let cliResult = self.makeCLIResult(
            credits: self.makeMonthlyLimitCredits(),
            email: " owner@example.COM ")

        let result = try await CodexOAuthFetchStrategy._replaceWithCLIMonthlyLimitForTesting(
            oauthResult: oauthResult,
            context: self.makeContext(sourceMode: .auto),
            cliStrategy: StubFetchStrategy(available: true, result: cliResult))

        #expect(result.sourceLabel == "oauth")
        #expect(result.usage.identity?.accountEmail == "Owner@Example.com")
        #expect(result.credits?.codexCreditLimit?.remaining == 750)
    }

    @Test
    func `auto O auth zero credits keeps partial result when CLI is unavailable`() async throws {
        let oauthResult = try CodexOAuthFetchStrategy._mapResultForTesting(
            Data(self.oauthZeroCreditRateWindowJSON().utf8),
            credentials: self.makeCredentials(),
            sourceMode: .auto)

        let result = try await CodexOAuthFetchStrategy._replaceWithCLIMonthlyLimitForTesting(
            oauthResult: oauthResult,
            context: self.makeContext(sourceMode: .auto),
            cliStrategy: StubFetchStrategy(available: false, result: nil))

        #expect(result.sourceLabel == "oauth")
        #expect(result.credits?.remaining == 0)
        #expect(result.usage.primary != nil)
    }

    @Test
    func `auto O auth zero credits keeps partial result when CLI lacks monthly limit`() async throws {
        let oauthResult = try CodexOAuthFetchStrategy._mapResultForTesting(
            Data(self.oauthZeroCreditRateWindowJSON().utf8),
            credentials: self.makeCredentials(),
            sourceMode: .auto)
        let cliResult = self.makeCLIResult(credits: CreditsSnapshot(
            remaining: 0,
            events: [],
            updatedAt: Date()))

        let result = try await CodexOAuthFetchStrategy._replaceWithCLIMonthlyLimitForTesting(
            oauthResult: oauthResult,
            context: self.makeContext(sourceMode: .auto),
            cliStrategy: StubFetchStrategy(available: true, result: cliResult))

        #expect(result.sourceLabel == "oauth")
        #expect(result.credits?.codexCreditLimit == nil)
    }
}
