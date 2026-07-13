import Foundation
import Testing
@testable import CodexBarCore

struct AmpUsageParserTests {
    @Test
    func `amp cli probe runs usage and parses balances`() async throws {
        let script = """
        [ "$1" = "usage" ] || exit 2
        cat <<'EOF'
        Signed in as cli@example.com (team)
        Amp Free: $6/$10 remaining (replenishes +$0.5/hour)
        Individual credits: $12.50 remaining
        Workspace Test Team: $7.25 remaining
        EOF
        """

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = try await AmpCLIProbe(arguments: ["-c", script, "amp", "usage"]).fetch(
            environment: ["AMP_CLI_PATH": "/bin/sh"],
            now: now)

        #expect(snapshot.freeUsed == 4)
        #expect(snapshot.individualCredits == 12.5)
        #expect(snapshot.workspaceBalances == [AmpWorkspaceBalance(name: "Test Team", remaining: 7.25)])
        #expect(snapshot.accountEmail == "cli@example.com")
        #expect(snapshot.updatedAt == now)
    }

    @Test
    func `parses current amp usage display text`() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let output = """
        \u{1B}[2mSigned in as ampcode@3kh0.net (echo)\u{1B}[0m
        Amp Free: $4.71/$10 remaining (replenishes +$0.42/hour) - https://ampcode.com/settings#amp-free
        Individual credits: $25.64 remaining (set up automatic top-up to avoid running out) - https://ampcode.com/settings
        Workspace meow: $10.22 remaining (set up automatic top-up to avoid running out) - https://ampcode.com/workspaces/meow
        """

        let snapshot = try AmpUsageParser.parse(displayText: output, now: now)

        #expect(snapshot.freeQuota == 10)
        #expect(try abs(#require(snapshot.freeUsed) - 5.29) < 0.001)
        #expect(snapshot.hourlyReplenishment == 0.42)
        #expect(snapshot.windowHours == 24)
        #expect(snapshot.individualCredits == 25.64)
        #expect(snapshot.workspaceBalances == [AmpWorkspaceBalance(name: "meow", remaining: 10.22)])
        #expect(snapshot.accountEmail == "ampcode@3kh0.net")
        #expect(snapshot.accountOrganization == "echo")
        #expect(snapshot.toUsageSnapshot(now: now).ampUsage == AmpUsageDetails(
            individualCredits: 25.64,
            workspaceBalances: [AmpWorkspaceBalance(name: "meow", remaining: 10.22)]))

        let encoded = try JSONEncoder().encode(snapshot.toUsageSnapshot(now: now))
        let decoded = try JSONDecoder().decode(UsageSnapshot.self, from: encoded)
        #expect(decoded.ampUsage == AmpUsageDetails(
            individualCredits: 25.64,
            workspaceBalances: [AmpWorkspaceBalance(name: "meow", remaining: 10.22)]))
    }

    @Test
    func `parses percentage based amp free usage`() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let output = """
        Signed in as user@example.com (example)
        Amp Free: 61% remaining today (resets daily) - https://ampcode.com/settings#amp-free
        Individual credits: $9.86 remaining (set up automatic top-up to avoid running out)
        Workspace example: $5.33 remaining (set up automatic top-up to avoid running out)
        """

        let snapshot = try AmpUsageParser.parse(displayText: output, now: now)
        let usage = snapshot.toUsageSnapshot(now: now)

        #expect(snapshot.freeQuota == 100)
        #expect(snapshot.freeUsed == 39)
        #expect(snapshot.hourlyReplenishment == 0)
        #expect(snapshot.windowHours == 24)
        #expect(snapshot.individualCredits == 9.86)
        #expect(snapshot.workspaceBalances == [AmpWorkspaceBalance(name: "example", remaining: 5.33)])
        #expect(snapshot.accountEmail == "user@example.com")
        #expect(snapshot.accountOrganization == "example")
        #expect(usage.primary?.usedPercent == 39)
        #expect(usage.primary?.windowMinutes == 1440)
        #expect(usage.primary?.resetsAt == nil)
        #expect(usage.primary?.resetDescription == "resets daily")
    }

    @Test
    func `legacy amp free usage keeps replenishment reset when percentage text also exists`() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let output = """
        Signed in as user@example.com
        Amp Free: $6/$10 remaining (replenishes +$0.5/hour)
        Amp Free: 61% remaining today (resets daily)
        """

        let snapshot = try AmpUsageParser.parse(displayText: output, now: now)
        let usage = snapshot.toUsageSnapshot(now: now)

        #expect(snapshot.freeUsed == 4)
        #expect(snapshot.freeResetDescription == nil)
        #expect(usage.primary?.resetsAt == now.addingTimeInterval(8 * 3600))
        #expect(usage.primary?.resetDescription == nil)
    }

    @Test
    func `daily amp usage rejects cached rolling reset`() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let legacy = try AmpUsageParser.parse(
            displayText: "Signed in as user@example.com\nAmp Free: $6/$10 remaining (replenishes +$0.5/hour)",
            now: now).toUsageSnapshot(now: now)
        let daily = try AmpUsageParser.parse(
            displayText: "Signed in as user@example.com\nAmp Free: 61% remaining today (resets daily)",
            now: now).toUsageSnapshot(now: now)

        let published = daily.backfillingResetTimes(from: legacy, now: now)

        #expect(legacy.primary?.resetsAt == now.addingTimeInterval(8 * 3600))
        #expect(published.primary?.resetsAt == nil)
        #expect(published.primary?.resetDescription == "resets daily")
    }

    @Test
    func `parses individual credits without free tier usage`() throws {
        let output = """
        Signed in as paid@example.com
        Individual credits: $25.64 remaining
        """

        let snapshot = try AmpUsageParser.parse(displayText: output)
        let usage = snapshot.toUsageSnapshot()

        #expect(snapshot.freeQuota == nil)
        #expect(snapshot.freeUsed == nil)
        #expect(snapshot.individualCredits == 25.64)
        #expect(usage.primary == nil)
        #expect(usage.ampUsage == AmpUsageDetails(individualCredits: 25.64, workspaceBalances: []))
        #expect(usage.identity?.loginMethod == "Amp")
    }

    @Test
    func `parses workspace credits without free tier usage`() throws {
        let output = """
        Signed in as workspace@example.com (team)
        Workspace Alpha Team: $1,234.56 remaining
        Workspace Beta: $7 remaining
        """

        let snapshot = try AmpUsageParser.parse(displayText: output)
        let usage = snapshot.toUsageSnapshot()

        #expect(snapshot.freeQuota == nil)
        #expect(snapshot.workspaceBalances == [
            AmpWorkspaceBalance(name: "Alpha Team", remaining: 1234.56),
            AmpWorkspaceBalance(name: "Beta", remaining: 7),
        ])
        #expect(usage.primary == nil)
        #expect(usage.ampUsage == AmpUsageDetails(
            individualCredits: nil,
            workspaceBalances: snapshot.workspaceBalances))
    }

    @Test
    func `signed in identity can contain login`() throws {
        let output = """
        Signed in as login@example.com (login-team)
        Amp Free: $6/$10 remaining (replenishes +$0.5/hour)
        """

        let snapshot = try AmpUsageParser.parse(displayText: output)

        #expect(snapshot.accountEmail == "login@example.com")
        #expect(snapshot.accountOrganization == "login-team")
    }

    @Test
    func `parses current usage api response`() throws {
        let now = Date(timeIntervalSince1970: 1_700_005_000)
        let displayText = """
        Signed in as user@example.com (team)
        Amp Free: $8/$10 remaining (replenishes +$0.5/hour)
        Individual credits: $12.50 remaining
        Workspace Alpha Team: $1,234.56 remaining
        Workspace Beta: $7 remaining
        """
        let data = try JSONSerialization.data(withJSONObject: [
            "ok": true,
            "result": ["displayText": displayText],
        ])

        let snapshot = try AmpUsageFetcher.parseUsageAPIResponse(data, now: now)

        #expect(snapshot.freeUsed == 2)
        #expect(snapshot.individualCredits == 12.5)
        #expect(snapshot.workspaceBalances == [
            AmpWorkspaceBalance(name: "Alpha Team", remaining: 1234.56),
            AmpWorkspaceBalance(name: "Beta", remaining: 7),
        ])
        #expect(snapshot.accountEmail == "user@example.com")
        #expect(snapshot.accountOrganization == "team")
    }

    @Test
    func `usage api auth error is invalid API token`() {
        let data = Data(#"{"ok":false,"error":{"code":"auth-required","message":"Sign in"}}"#.utf8)

        #expect {
            try AmpUsageFetcher.parseUsageAPIResponse(data)
        } throws: { error in
            guard case AmpUsageError.invalidAPIToken = error else { return false }
            return true
        }
    }

    @Test
    func `parses free tier usage from settings HTML`() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let html = """
        <script>
        __sveltekit_x.data = {user:{},
        freeTierUsage:{bucket:"ubi",quota:1000,hourlyReplenishment:42,windowHours:24,used:338.5}};
        </script>
        """

        let snapshot = try AmpUsageParser.parse(html: html, now: now)

        #expect(snapshot.freeQuota == 1000)
        #expect(snapshot.freeUsed == 338.5)
        #expect(snapshot.hourlyReplenishment == 42)
        #expect(snapshot.windowHours == 24)

        let usage = snapshot.toUsageSnapshot(now: now)
        let expectedPercent = (338.5 / 1000) * 100
        #expect(abs((usage.primary?.usedPercent ?? 0) - expectedPercent) < 0.001)
        #expect(usage.primary?.windowMinutes == 1440)

        let expectedHoursToFull = 338.5 / 42
        let expectedReset = now.addingTimeInterval(expectedHoursToFull * 3600)
        #expect(usage.primary?.resetsAt == expectedReset)
        #expect(usage.identity?.loginMethod == "Amp Free")
    }

    @Test
    func `parses free tier usage from prefetched key`() throws {
        let now = Date(timeIntervalSince1970: 1_700_010_000)
        let html = """
        <script>
        __sveltekit_x.data = {
          "w6b2h6/getFreeTierUsage/":{bucket:"ubi",quota:1000,hourlyReplenishment:42,windowHours:24,used:0}
        };
        </script>
        """

        let snapshot = try AmpUsageParser.parse(html: html, now: now)
        #expect(snapshot.freeUsed == 0)
        #expect(snapshot.freeQuota == 1000)
    }

    @Test
    func `missing usage throws parse failed`() {
        let html = "<html><body>No usage here.</body></html>"

        #expect {
            try AmpUsageParser.parse(html: html)
        } throws: { error in
            guard case let AmpUsageError.parseFailed(message) = error else { return false }
            return message.contains("Missing Amp Free usage data")
        }
    }

    @Test
    func `signed out throws not logged in`() {
        let html = "<html><body>Please sign in to Amp.</body></html>"

        #expect {
            try AmpUsageParser.parse(html: html)
        } throws: { error in
            guard case AmpUsageError.notLoggedIn = error else { return false }
            return true
        }
    }

    @Test
    func `usage snapshot clamps percent and window`() {
        let now = Date(timeIntervalSince1970: 1_700_020_000)
        let snapshot = AmpUsageSnapshot(
            freeQuota: 100,
            freeUsed: 150,
            hourlyReplenishment: 10,
            windowHours: nil,
            updatedAt: now)

        let usage = snapshot.toUsageSnapshot(now: now)
        #expect(usage.primary?.usedPercent == 100)
        #expect(usage.primary?.windowMinutes == nil)
    }

    @Test
    func `usage snapshot omits reset when hourly replenishment is zero`() {
        let now = Date(timeIntervalSince1970: 1_700_030_000)
        let snapshot = AmpUsageSnapshot(
            freeQuota: 100,
            freeUsed: 20,
            hourlyReplenishment: 0,
            windowHours: 24,
            updatedAt: now)

        let usage = snapshot.toUsageSnapshot(now: now)
        #expect(usage.primary?.resetsAt == nil)
    }
}
