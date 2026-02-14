import CodexBarCore
import Foundation
import Testing

@Suite
struct ClaudeOAuthTests {
    @Test
    func parsesOAuthCredentials() throws {
        let json = """
        {
          "claudeAiOauth": {
            "accessToken": "test-token",
            "refreshToken": "test-refresh",
            "expiresAt": 4102444800000,
            "scopes": ["usage:read"],
            "rateLimitTier": "default_claude_max_20x"
          }
        }
        """
        let creds = try ClaudeOAuthCredentials.parse(data: Data(json.utf8))
        #expect(creds.accessToken == "test-token")
        #expect(creds.refreshToken == "test-refresh")
        #expect(creds.scopes == ["usage:read"])
        #expect(creds.rateLimitTier == "default_claude_max_20x")
        #expect(creds.isExpired == false)
    }

    @Test
    func missingAccessTokenThrows() {
        let json = """
        {
          "claudeAiOauth": {
            "accessToken": "",
            "refreshToken": "test-refresh",
            "expiresAt": 1735689600000
          }
        }
        """
        #expect(throws: ClaudeOAuthCredentialsError.self) {
            _ = try ClaudeOAuthCredentials.parse(data: Data(json.utf8))
        }
    }

    @Test
    func missingOAuthBlockThrows() {
        let json = """
        { "other": { "accessToken": "nope" } }
        """
        #expect(throws: ClaudeOAuthCredentialsError.self) {
            _ = try ClaudeOAuthCredentials.parse(data: Data(json.utf8))
        }
    }

    @Test
    func treatsMissingExpiryAsExpired() {
        let creds = ClaudeOAuthCredentials(
            accessToken: "token",
            refreshToken: nil,
            expiresAt: nil,
            scopes: [],
            rateLimitTier: nil)
        #expect(creds.isExpired == true)
    }

    @Test
    func mapsOAuthUsageToSnapshot() throws {
        let json = """
        {
          "five_hour": { "utilization": 12.5, "resets_at": "2025-12-25T12:00:00.000Z" },
          "seven_day": { "utilization": 30, "resets_at": "2025-12-31T00:00:00.000Z" },
          "seven_day_sonnet": { "utilization": 5 }
        }
        """
        let snap = try ClaudeUsageFetcher._mapOAuthUsageForTesting(
            Data(json.utf8),
            rateLimitTier: "claude_pro")
        #expect(snap.primary.usedPercent == 12.5)
        #expect(snap.primary.windowMinutes == 300)
        #expect(snap.secondary?.usedPercent == 30)
        #expect(snap.opus?.usedPercent == 5)
        #expect(snap.primary.resetsAt != nil)
        #expect(snap.loginMethod == "Claude Pro")
    }

    @Test
    func mapsOAuthExtraUsage() throws {
        // OAuth API returns values in cents (minor units), same as Web API.
        // The normalization always converts to dollars (major units).
        let json = """
        {
          "five_hour": { "utilization": 1, "resets_at": "2025-12-25T12:00:00.000Z" },
          "extra_usage": {
            "is_enabled": true,
            "monthly_limit": 2050,
            "used_credits": 325
          }
        }
        """
        let snap = try ClaudeUsageFetcher._mapOAuthUsageForTesting(Data(json.utf8))
        #expect(snap.providerCost?.currencyCode == "USD")
        #expect(snap.providerCost?.limit == 20.5)
        #expect(snap.providerCost?.used == 3.25)
    }

    @Test
    func mapsOAuthExtraUsageMinorUnitsAsMajorUnits() throws {
        let json = """
        {
          "five_hour": { "utilization": 1, "resets_at": "2025-12-25T12:00:00.000Z" },
          "extra_usage": {
            "is_enabled": true,
            "monthly_limit": 2000,
            "used_credits": 520,
            "currency": "USD"
          }
        }
        """
        let snap = try ClaudeUsageFetcher._mapOAuthUsageForTesting(Data(json.utf8))
        #expect(snap.providerCost?.currencyCode == "USD")
        #expect(snap.providerCost?.limit == 20)
        #expect(snap.providerCost?.used == 5.2)
    }

    @Test
    func rescalesOAuthExtraUsageWhenLimitIsImplausiblyHigh() throws {
        let json = """
        {
          "five_hour": { "utilization": 1, "resets_at": "2025-12-25T12:00:00.000Z" },
          "extra_usage": {
            "is_enabled": true,
            "monthly_limit": 200000,
            "used_credits": 22200,
            "currency": "USD"
          }
        }
        """
        let snap = try ClaudeUsageFetcher._mapOAuthUsageForTesting(
            Data(json.utf8),
            rateLimitTier: "claude_pro")
        #expect(snap.providerCost?.currencyCode == "USD")
        #expect(snap.providerCost?.limit == 20)
        #expect(snap.providerCost?.used == 2.22)
    }

    @Test
    func rescalesOAuthExtraUsageWhenPlanMissing() throws {
        let json = """
        {
          "five_hour": { "utilization": 1, "resets_at": "2025-12-25T12:00:00.000Z" },
          "extra_usage": {
            "is_enabled": true,
            "monthly_limit": 200000,
            "used_credits": 22200,
            "currency": "USD"
          }
        }
        """
        let snap = try ClaudeUsageFetcher._mapOAuthUsageForTesting(Data(json.utf8))
        #expect(snap.providerCost?.currencyCode == "USD")
        #expect(snap.providerCost?.limit == 20)
        #expect(snap.providerCost?.used == 2.22)
    }

    @Test
    func doesNotRescaleOAuthExtraUsageForEnterprisePlans() throws {
        let json = """
        {
          "five_hour": { "utilization": 1, "resets_at": "2025-12-25T12:00:00.000Z" },
          "extra_usage": {
            "is_enabled": true,
            "monthly_limit": 200000,
            "used_credits": 22200,
            "currency": "USD"
          }
        }
        """
        let snap = try ClaudeUsageFetcher._mapOAuthUsageForTesting(
            Data(json.utf8),
            rateLimitTier: "claude_enterprise")
        #expect(snap.providerCost?.currencyCode == "USD")
        #expect(snap.providerCost?.limit == 2000)
        #expect(snap.providerCost?.used == 222)
    }

    @Test
    func rescalesWebExtraUsageWhenSnapshotPlanMissing() {
        let cost = ProviderCostSnapshot(
            used: 222,
            limit: 2000,
            currencyCode: "USD",
            period: "Monthly",
            resetsAt: nil,
            updatedAt: Date())
        let rescaled = ClaudeUsageFetcher._rescaleExtraUsageForTesting(
            cost,
            snapshotLoginMethod: nil,
            webLoginMethod: "Claude Pro")
        #expect(rescaled?.limit == 20)
        #expect(rescaled?.used == 2.22)
    }

    @Test
    func prefersOpusWhenSonnetMissing() throws {
        let json = """
        {
          "five_hour": { "utilization": 10, "resets_at": "2025-12-25T12:00:00.000Z" },
          "seven_day_opus": { "utilization": 42 }
        }
        """
        let snap = try ClaudeUsageFetcher._mapOAuthUsageForTesting(Data(json.utf8))
        #expect(snap.opus?.usedPercent == 42)
    }

    @Test
    func includesBodyInOAuth403Error() {
        let err = ClaudeOAuthFetchError.serverError(
            403,
            "HTTP 403: OAuth token does not meet scope requirement user:profile")
        #expect(err.localizedDescription.contains("user:profile"))
        #expect(err.localizedDescription.contains("HTTP 403"))
    }

    @Test
    func skipsExtraUsageWhenDisabled() throws {
        let json = """
        {
          "five_hour": { "utilization": 1, "resets_at": "2025-12-25T12:00:00.000Z" },
          "extra_usage": {
            "is_enabled": false,
            "monthly_limit": 100,
            "used_credits": 10
          }
        }
        """
        let snap = try ClaudeUsageFetcher._mapOAuthUsageForTesting(Data(json.utf8))
        #expect(snap.providerCost == nil)
    }

    // MARK: - Scope-based strategy resolution

    @Test
    func prefersOAuthWhenAvailable() {
        let strategy = ClaudeProviderDescriptor.resolveUsageStrategy(
            selectedDataSource: .auto,
            webExtrasEnabled: false,
            hasWebSession: true,
            hasCLI: true,
            hasOAuthCredentials: true)
        #expect(strategy.dataSource == .oauth)
    }

    @Test
    func fallsBackToCLIWhenOAuthMissingAndCLIAvailable() {
        let strategy = ClaudeProviderDescriptor.resolveUsageStrategy(
            selectedDataSource: .auto,
            webExtrasEnabled: false,
            hasWebSession: true,
            hasCLI: true,
            hasOAuthCredentials: false)
        #expect(strategy.dataSource == .cli)
    }

    @Test
    func fallsBackToWebWhenOAuthMissingAndCLIMissing() {
        let strategy = ClaudeProviderDescriptor.resolveUsageStrategy(
            selectedDataSource: .auto,
            webExtrasEnabled: false,
            hasWebSession: true,
            hasCLI: false,
            hasOAuthCredentials: false)
        #expect(strategy.dataSource == .web)
    }

    @Test
    func fallsBackToCLIWhenOAuthMissingAndWebMissing() {
        let strategy = ClaudeProviderDescriptor.resolveUsageStrategy(
            selectedDataSource: .auto,
            webExtrasEnabled: false,
            hasWebSession: false,
            hasCLI: true,
            hasOAuthCredentials: false)
        #expect(strategy.dataSource == .cli)
    }
}
