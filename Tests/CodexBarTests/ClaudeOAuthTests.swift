import Foundation
import Testing
@testable import CodexBarCore

struct ClaudeOAuthTests {
    @Test
    func `parses O auth credentials`() throws {
        let json = """
        {
          "claudeAiOauth": {
            "accessToken": "test-token",
            "refreshToken": "test-refresh",
            "expiresAt": 4102444800000,
            "scopes": ["usage:read"],
            "rateLimitTier": "default_claude_max_20x",
            "subscriptionType": "pro"
          }
        }
        """
        let creds = try ClaudeOAuthCredentials.parse(data: Data(json.utf8))
        #expect(creds.accessToken == "test-token")
        #expect(creds.refreshToken == "test-refresh")
        #expect(creds.scopes == ["usage:read"])
        #expect(creds.rateLimitTier == "default_claude_max_20x")
        #expect(creds.subscriptionType == "pro")
        #expect(creds.isExpired == false)
    }

    @Test
    func `missing access token throws`() {
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
    func `missing O auth block throws`() {
        let json = """
        { "other": { "accessToken": "nope" } }
        """
        #expect(throws: ClaudeOAuthCredentialsError.self) {
            _ = try ClaudeOAuthCredentials.parse(data: Data(json.utf8))
        }
    }

    @Test
    func `treats missing expiry as expired`() {
        let creds = ClaudeOAuthCredentials(
            accessToken: "token",
            refreshToken: nil,
            expiresAt: nil,
            scopes: [],
            rateLimitTier: nil)
        #expect(creds.isExpired == true)
    }

    @Test
    func `maps O auth usage to snapshot`() throws {
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
    func `maps O auth subscription type when rate limit tier is generic`() throws {
        let json = """
        {
          "five_hour": { "utilization": 12.5, "resets_at": "2025-12-25T12:00:00.000Z" }
        }
        """
        let snap = try ClaudeUsageFetcher._mapOAuthUsageForTesting(
            Data(json.utf8),
            rateLimitTier: "default_claude_ai",
            subscriptionType: "pro")
        #expect(snap.loginMethod == "Claude Pro")
    }

    @Test
    func `maps O auth design and routines usage windows`() throws {
        let json = """
        {
          "five_hour": { "utilization": 12.5, "resets_at": "2025-12-25T12:00:00.000Z" },
          "seven_day_design": { "utilization": 44, "resets_at": "2025-12-31T00:00:00.000Z" },
          "seven_day_routines": { "utilization": 18, "resets_at": "2026-01-01T00:00:00.000Z" }
        }
        """
        let snap = try ClaudeUsageFetcher._mapOAuthUsageForTesting(Data(json.utf8))
        #expect(snap.extraRateWindows.count == 2)
        #expect(snap.extraRateWindows.first(where: { $0.id == "claude-design" })?.title == "Designs")
        #expect(snap.extraRateWindows.first(where: { $0.id == "claude-design" })?.window.usedPercent == 44)
        #expect(snap.extraRateWindows.first(where: { $0.id == "claude-routines" })?.title == "Daily Routines")
        #expect(snap.extraRateWindows.first(where: { $0.id == "claude-routines" })?.window.usedPercent == 18)
    }

    @Test
    func `maps O auth omelette and cowork usage windows`() throws {
        let json = """
        {
          "five_hour": { "utilization": 12.5, "resets_at": "2025-12-25T12:00:00.000Z" },
          "seven_day_omelette": { "utilization": 29, "resets_at": "2025-12-31T00:00:00.000Z" },
          "seven_day_cowork": { "utilization": 9, "resets_at": "2026-01-01T00:00:00.000Z" }
        }
        """
        let snap = try ClaudeUsageFetcher._mapOAuthUsageForTesting(Data(json.utf8))
        #expect(snap.extraRateWindows.count == 2)
        #expect(snap.extraRateWindows.first(where: { $0.id == "claude-design" })?.window.usedPercent == 29)
        #expect(snap.extraRateWindows.first(where: { $0.id == "claude-routines" })?.window.usedPercent == 9)
    }

    @Test
    func `maps O auth null cowork as zero routines window`() throws {
        let json = """
        {
          "five_hour": { "utilization": 12.5, "resets_at": "2025-12-25T12:00:00.000Z" },
          "seven_day_omelette": { "utilization": 29, "resets_at": "2025-12-31T00:00:00.000Z" },
          "seven_day_cowork": null
        }
        """
        let snap = try ClaudeUsageFetcher._mapOAuthUsageForTesting(Data(json.utf8))
        #expect(snap.extraRateWindows.first(where: { $0.id == "claude-routines" })?.window.usedPercent == 0)
    }

    @Test
    func `prefers populated alias over null alias in mixed payload`() throws {
        let json = """
        {
          "five_hour": { "utilization": 12.5, "resets_at": "2025-12-25T12:00:00.000Z" },
          "seven_day_design": null,
          "seven_day_omelette": { "utilization": 37, "resets_at": "2025-12-31T00:00:00.000Z" },
          "seven_day_routines": null,
          "seven_day_cowork": { "utilization": 14, "resets_at": "2026-01-01T00:00:00.000Z" }
        }
        """
        let snap = try ClaudeUsageFetcher._mapOAuthUsageForTesting(Data(json.utf8))
        #expect(snap.extraRateWindows.first(where: { $0.id == "claude-design" })?.window.usedPercent == 37)
        #expect(snap.extraRateWindows.first(where: { $0.id == "claude-routines" })?.window.usedPercent == 14)
    }

    @Test
    func `maps O auth extra usage`() throws {
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
    func `maps O auth extra usage minor units as major units`() throws {
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
    func `normalizes high limit O auth extra usage`() throws {
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
        #expect(snap.providerCost?.limit == 2000)
        #expect(snap.providerCost?.used == 222)
    }

    @Test
    func `normalizes O auth extra usage cents to major units`() throws {
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
        #expect(snap.providerCost?.limit == 2000)
        #expect(snap.providerCost?.used == 222)
    }

    @Test
    func `prefers opus when sonnet missing`() throws {
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
    func `includes body in O auth403 error`() {
        let err = ClaudeOAuthFetchError.serverError(
            403,
            "HTTP 403: OAuth token does not meet scope requirement user:profile")
        #expect(err.localizedDescription.contains("user:profile"))
        #expect(err.localizedDescription.contains("HTTP 403"))
    }

    @Test
    func `oauth usage user agent uses claude code version`() {
        #expect(
            ClaudeOAuthUsageFetcher._userAgentForTesting(versionString: "2.1.70 (Claude Code)")
                == "claude-code/2.1.70")
        #expect(ClaudeOAuthUsageFetcher._userAgentForTesting(versionString: nil) == "claude-code/2.1.0")
    }

    @Test
    func `skips extra usage when disabled`() throws {
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
    func `prefers O auth when available`() {
        let strategy = ClaudeProviderDescriptor.resolveUsageStrategy(
            selectedDataSource: .auto,
            webExtrasEnabled: false,
            hasWebSession: true,
            hasCLI: true,
            hasOAuthCredentials: true)
        #expect(strategy.dataSource == .oauth)
    }

    @Test
    func `falls back to CLI when O auth missing and CLI available`() {
        let strategy = ClaudeProviderDescriptor.resolveUsageStrategy(
            selectedDataSource: .auto,
            webExtrasEnabled: false,
            hasWebSession: true,
            hasCLI: true,
            hasOAuthCredentials: false)
        #expect(strategy.dataSource == .cli)
    }

    @Test
    func `falls back to web when O auth missing and CLI missing`() {
        let strategy = ClaudeProviderDescriptor.resolveUsageStrategy(
            selectedDataSource: .auto,
            webExtrasEnabled: false,
            hasWebSession: true,
            hasCLI: false,
            hasOAuthCredentials: false)
        #expect(strategy.dataSource == .web)
    }

    @Test
    func `falls back to CLI when O auth missing and web missing`() {
        let strategy = ClaudeProviderDescriptor.resolveUsageStrategy(
            selectedDataSource: .auto,
            webExtrasEnabled: false,
            hasWebSession: false,
            hasCLI: true,
            hasOAuthCredentials: false)
        #expect(strategy.dataSource == .cli)
    }
}
