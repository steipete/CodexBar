import Foundation
import Testing
@testable import CodexBarCore

struct ClaudeWebUsageExtraWindowTests {
    @Test
    func `parses claude web API sonnet usage response`() throws {
        let json = """
        {
          "five_hour": { "utilization": 9, "resets_at": "2025-12-23T16:00:00.000Z" },
          "seven_day_sonnet": { "utilization": 6, "resets_at": "2025-12-30T23:00:00.000Z" }
        }
        """
        let data = Data(json.utf8)
        let parsed = try ClaudeWebAPIFetcher._parseUsageResponseForTesting(data)
        #expect(parsed.opusPercentUsed == 6)
    }

    @Test
    func `parses Claude prepaid credits in minor units`() throws {
        let data = Data(#"{"amount":10000,"currency":"usd"}"#.utf8)
        let cost = try #require(ClaudeWebAPIFetcher._parsePrepaidCreditsForTesting(data))

        #expect(cost.balance == 100)
        #expect(cost.currencyCode == "USD")
        #expect(cost.used == 0)
        #expect(cost.limit == 0)
    }

    @Test
    func `rejects invalid Claude prepaid credit balances`() {
        let negative = Data(#"{"amount":-1,"currency":"USD"}"#.utf8)
        let missingCurrency = Data(#"{"amount":10000}"#.utf8)
        let booleanAmount = Data(#"{"amount":true,"currency":"USD"}"#.utf8)

        #expect(ClaudeWebAPIFetcher._parsePrepaidCreditsForTesting(negative) == nil)
        #expect(ClaudeWebAPIFetcher._parsePrepaidCreditsForTesting(missingCurrency) == nil)
        #expect(ClaudeWebAPIFetcher._parsePrepaidCreditsForTesting(booleanAmount) == nil)
    }

    @Test
    func `merges Claude prepaid balance into primary O auth cost`() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let primary = ProviderCostSnapshot(
            used: 5,
            limit: 20,
            currencyCode: "USD",
            period: "Monthly cap",
            updatedAt: now)
        let web = ProviderCostSnapshot(
            used: 0,
            limit: 0,
            currencyCode: "usd",
            period: "Extra usage",
            balance: 100,
            updatedAt: now.addingTimeInterval(1))

        let merged = try #require(ClaudeUsageFetcher._mergeProviderCostForTesting(
            primary: primary,
            web: web))

        #expect(merged.used == 5)
        #expect(merged.limit == 20)
        #expect(merged.period == "Monthly cap")
        #expect(merged.balance == 100)
        #expect(merged.updatedAt == now)
    }

    @Test
    func `does not merge Claude prepaid balance with a different currency`() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let primary = ProviderCostSnapshot(
            used: 5,
            limit: 20,
            currencyCode: "USD",
            period: "Monthly cap",
            updatedAt: now)
        let web = ProviderCostSnapshot(
            used: 0,
            limit: 0,
            currencyCode: "EUR",
            period: "Extra usage",
            balance: 100,
            updatedAt: now)

        let merged = try #require(ClaudeUsageFetcher._mergeProviderCostForTesting(
            primary: primary,
            web: web))

        #expect(merged == primary)
    }

    @Test
    func `web extras preserve OAuth credential ownership evidence`() {
        let primaryCost = ProviderCostSnapshot(
            used: 5,
            limit: 20,
            currencyCode: "USD",
            period: "Monthly cap",
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let snapshot = ClaudeUsageSnapshot(
            primary: RateWindow(usedPercent: 7, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            opus: nil,
            providerCost: primaryCost,
            updatedAt: Date(timeIntervalSince1970: 1_800_000_001),
            accountEmail: "user@example.com",
            accountOrganization: "org-123",
            loginMethod: "Pro",
            rawText: nil,
            oauthKeychainPersistentRefHash: "persistent-ref",
            oauthHistoryOwnerIdentifier: "history-owner",
            oauthCredentialOwner: .claudeCLI,
            oauthKeychainCredentialUnavailable: true)
        let webCost = ProviderCostSnapshot(
            used: 0,
            limit: 0,
            currencyCode: "USD",
            period: "Extra usage",
            balance: 100,
            updatedAt: Date(timeIntervalSince1970: 1_800_000_002))

        let enriched = snapshot.replacingWebExtras(
            extraRateWindows: [],
            providerCost: webCost)

        #expect(enriched.providerCost == webCost)
        #expect(enriched.oauthCredentialOwner == .claudeCLI)
        #expect(enriched.oauthKeychainPersistentRefHash == "persistent-ref")
        #expect(enriched.oauthHistoryOwnerIdentifier == "history-owner")
        #expect(enriched.oauthKeychainCredentialUnavailable)
    }

    @Test
    func `web extras require the same Claude account and organization`() {
        let snapshot = ClaudeUsageSnapshot(
            primary: RateWindow(usedPercent: 7, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            opus: nil,
            providerCost: nil,
            updatedAt: Date(),
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: "Pro",
            rawText: nil)
        let webData = ClaudeWebAPIFetcher.WebUsageData(
            sessionPercentUsed: 7,
            sessionResetsAt: nil,
            weeklyPercentUsed: nil,
            weeklyResetsAt: nil,
            opusPercentUsed: nil,
            extraRateWindows: [],
            extraUsageCost: nil,
            accountOrganization: "Test Org",
            accountOrganizationID: "org-123",
            accountEmail: "user@example.com",
            loginMethod: "Pro")

        #expect(ClaudeUsageFetcher.webExtrasAccountMatches(
            snapshot: snapshot,
            webData: webData,
            oauthProfile: OAuthProfileResponse(
                emailAddress: "user@example.com",
                organizationUuid: "org-123")))
        #expect(!ClaudeUsageFetcher.webExtrasAccountMatches(
            snapshot: snapshot,
            webData: webData,
            oauthProfile: OAuthProfileResponse(
                emailAddress: "other@example.com",
                organizationUuid: "org-123")))
        #expect(!ClaudeUsageFetcher.webExtrasAccountMatches(
            snapshot: snapshot,
            webData: webData,
            oauthProfile: OAuthProfileResponse(
                emailAddress: "user@example.com",
                organizationUuid: "org-other")))
    }

    @Test
    func `ignores merged claude web API omelette usage window`() throws {
        let json = """
        {
          "five_hour": { "utilization": 9, "resets_at": "2025-12-23T16:00:00.000Z" },
          "seven_day_omelette": { "utilization": 26, "resets_at": "2025-12-30T23:00:00.000Z" },
          "seven_day_cowork": { "utilization": 11, "resets_at": "2025-12-31T23:00:00.000Z" }
        }
        """
        let data = Data(json.utf8)
        let parsed = try ClaudeWebAPIFetcher._parseUsageResponseForTesting(data)
        #expect(parsed.extraRateWindows.count == 1)
        #expect(parsed.extraRateWindows.contains { $0.id == "claude-design" } == false)
        #expect(parsed.extraRateWindows.first(where: { $0.id == "claude-routines" })?.window.usedPercent == 11)
    }

    @Test
    func `omits routines window when claude web API cowork is null`() throws {
        let json = """
        {
          "five_hour": { "utilization": 9, "resets_at": "2025-12-23T16:00:00.000Z" },
          "seven_day_omelette": { "utilization": 26, "resets_at": "2025-12-30T23:00:00.000Z" },
          "seven_day_cowork": null
        }
        """
        let data = Data(json.utf8)
        let parsed = try ClaudeWebAPIFetcher._parseUsageResponseForTesting(data)
        #expect(parsed.extraRateWindows.contains { $0.id == "claude-routines" } == false)
        #expect(parsed.extraRateWindows.contains { $0.id == "claude-design" } == false)
    }

    @Test
    func `surfaces Fable scoped weekly limit from claude web API limits array`() throws {
        // Real shape observed 2026-07-03 from claude.ai/api/organizations/{org}/usage during
        // Anthropic's Fable 5 promotional access window (up to 50% of the weekly limit).
        let json = """
        {
          "five_hour": { "utilization": 16, "resets_at": "2026-07-03T00:30:00.440902+00:00" },
          "seven_day": { "utilization": 10, "resets_at": "2026-07-08T09:00:00.440924+00:00" },
          "limits": [
            {
              "kind": "session", "group": "session", "percent": 16,
              "resets_at": "2026-07-03T00:30:00.440902+00:00", "scope": null, "is_active": true
            },
            {
              "kind": "weekly_all", "group": "weekly", "percent": 10,
              "resets_at": "2026-07-08T09:00:00.440924+00:00", "scope": null, "is_active": false
            },
            {
              "kind": "weekly_scoped", "group": "weekly", "percent": 5,
              "resets_at": "2026-07-08T09:00:00.441154+00:00",
              "scope": { "model": { "id": null, "display_name": "Fable" }, "surface": null },
              "is_active": false
            }
          ]
        }
        """
        let data = Data(json.utf8)
        let parsed = try ClaudeWebAPIFetcher._parseUsageResponseForTesting(data)
        let fable = parsed.extraRateWindows.first(where: { $0.id == "claude-weekly-scoped-fable" })
        #expect(fable?.title == "Fable only")
        #expect(fable?.window.usedPercent == 5)
        #expect(fable?.window.resetsAt != nil)
    }

    @Test
    func `orders scoped weekly windows before daily routines`() throws {
        let json = """
        {
          "five_hour": { "utilization": 9, "resets_at": "2026-07-03T00:30:00.440902+00:00" },
          "seven_day": { "utilization": 20, "resets_at": "2026-07-08T09:00:00.440924+00:00" },
          "seven_day_cowork": { "utilization": 11, "resets_at": "2026-07-08T09:00:00.440924+00:00" },
          "limits": [
            {
              "kind": "weekly_scoped", "group": "weekly", "percent": 29,
              "resets_at": "2026-07-08T09:00:00.441154+00:00",
              "scope": { "model": { "id": null, "display_name": "Fable" }, "surface": null },
              "is_active": false
            }
          ]
        }
        """
        let data = Data(json.utf8)
        let parsed = try ClaudeWebAPIFetcher._parseUsageResponseForTesting(data)
        #expect(parsed.extraRateWindows.map(\.title) == ["Fable only", "Daily Routines"])
    }

    @Test
    func `keeps multiple scoped weekly windows in payload order before routines`() throws {
        let json = """
        {
          "five_hour": { "utilization": 9, "resets_at": "2026-07-03T00:30:00.440902+00:00" },
          "seven_day": { "utilization": 20, "resets_at": "2026-07-08T09:00:00.440924+00:00" },
          "seven_day_cowork": { "utilization": 11, "resets_at": "2026-07-08T09:00:00.440924+00:00" },
          "limits": [
            {
              "kind": "weekly_scoped", "group": "weekly", "percent": 12,
              "resets_at": "2026-07-08T09:00:00.441154+00:00",
              "scope": { "model": { "id": null, "display_name": "Opus" }, "surface": null },
              "is_active": false
            },
            {
              "kind": "weekly_scoped", "group": "weekly", "percent": 29,
              "resets_at": "2026-07-08T09:00:00.441154+00:00",
              "scope": { "model": { "id": null, "display_name": "Fable" }, "surface": null },
              "is_active": false
            }
          ]
        }
        """
        let data = Data(json.utf8)
        let parsed = try ClaudeWebAPIFetcher._parseUsageResponseForTesting(data)
        #expect(parsed.extraRateWindows.map(\.title) == ["Opus only", "Fable only", "Daily Routines"])
    }
}
