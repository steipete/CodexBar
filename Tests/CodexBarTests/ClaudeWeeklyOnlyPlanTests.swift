import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct ClaudeWeeklyOnlyPlanTests {
    @Test
    func `parse claude status weekly only plan has no session`() throws {
        // When /usage omits "Current session", the weekly percentage must not be
        // promoted into the session slot by the order-based fallback.
        let sample = """
        Settings:  Status   Config   Usage
        Account: session@example.test
        Current week (all models)
        █████                                              10% used
        Resets Nov 9 at 9am (America/New_York)
        Current week (Sonnet only)
        ▌                                                  1% used
        Resets Nov 9 at 9am (America/New_York)
        """
        let snap = try ClaudeStatusProbe.parse(text: sample)
        #expect(snap.sessionPercentLeft == nil)
        #expect(snap.primaryResetDescription == nil)
        #expect(snap.weeklyPercentLeft == 90)
        #expect(snap.opusPercentLeft == 99)
    }

    @Test
    func `weekly only claude plan shows weekly row without a session row`() throws {
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        let metadata = try #require(ProviderDefaults.metadata[.claude])
        let weekly = RateWindow(
            usedPercent: 12,
            windowMinutes: 7 * 24 * 60,
            resetsAt: now.addingTimeInterval(3 * 24 * 60 * 60),
            resetDescription: nil)

        let model = UsageMenuCardView.Model.make(.init(
            provider: .claude,
            metadata: metadata,
            snapshot: UsageSnapshot(primary: nil, secondary: weekly, updatedAt: now),
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        #expect(model.metrics.map(\.id) == ["secondary"])
        #expect(model.metrics.first?.title == metadata.weeklyLabel)
    }

    @Test(arguments: ["Sonnet only", "Fable only"])
    func `model only CLI quotas remain usable without a session or all-model weekly row`(label: String) throws {
        let parsed = try ClaudeStatusProbe.parse(text: """
        Settings: Status Config Usage
        Current week (\(label))
        █████ 17% used
        Resets Nov 9 at 9am (America/New_York)
        """)
        let usage = try ClaudeUsageFetcher.makeSnapshot(from: parsed)
        #expect(usage.primary == nil)
        #expect(usage.secondary == nil)
        let window = label == "Sonnet only" ? usage.opus : usage.extraRateWindows.first?.window
        #expect(window?.usedPercent == 17)
        #expect(window?.windowMinutes == 10080)
    }

    @Test
    func `legacy JSON preserves a model weekly quota without inventing a session`() throws {
        let usage = try #require(ClaudeUsageFetcher.parse(json: Data(
            #"{"week_sonnet":{"pct_used":17}}"#.utf8)))
        #expect(usage.primary == nil)
        #expect(usage.secondary == nil)
        #expect(usage.opus?.usedPercent == 17)
    }

    @Test(arguments: ["seven_day_sonnet", "seven_day_opus", "limits"])
    func `OAuth model only quotas remain visible in the menu bar`(key: String) throws {
        var response: [String: Any] = [
            "five_hour": NSNull(), "seven_day": NSNull(),
            "extra_usage": ["is_enabled": true, "monthly_limit": 10000, "used_credits": 2000],
        ]
        if key == "limits" {
            response[key] = [[
                "kind": "weekly_scoped", "group": "weekly", "percent": 17,
                "resets_at": "2026-11-09T16:59:59Z",
                "scope": ["model": ["display_name": "Fable"]], "is_active": true,
            ]]
        } else {
            response[key] = ["utilization": 17, "resets_at": "2026-11-09T16:59:59Z"]
            if key == "seven_day_opus" {
                response["seven_day_sonnet"] = ["resets_at": "2026-11-09T16:59:59Z"]
            }
        }
        let usage = try ClaudeUsageFetcher._mapOAuthUsageForTesting(JSONSerialization.data(withJSONObject: response))
        let snapshot = ClaudeOAuthFetchStrategy._snapshotForTesting(from: usage)
        #expect(snapshot.primary == nil)
        #expect(snapshot.secondary == nil)
        #expect(snapshot.providerCost?.period == "Monthly cap")
        #expect(IconRemainingResolver.resolvedWindows(snapshot: snapshot, style: .claude).primary?.usedPercent == 17)
        for preference in [MenuBarMetricPreference.automatic, .primaryAndSecondary] {
            #expect(MenuBarMetricWindowResolver.rateWindow(
                preference: preference, provider: .claude, snapshot: snapshot, supportsAverage: false)?
                .usedPercent == 17)
        }
    }
}
