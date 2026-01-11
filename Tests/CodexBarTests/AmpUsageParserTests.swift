import Foundation
import Testing
@testable import CodexBarCore

@Suite
struct AmpUsageParserTests {
    @Test
    func parsesFreeTierUsageFromSettingsHTML() throws {
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

        let expectedHoursToFull = (1000 - 338.5) / 42
        let expectedReset = now.addingTimeInterval(expectedHoursToFull * 3600)
        #expect(usage.primary?.resetsAt == expectedReset)
        #expect(usage.identity?.loginMethod == "Amp Free")
    }

    @Test
    func parsesFreeTierUsageFromPrefetchedKey() throws {
        let now = Date(timeIntervalSince1970: 1_700_010_000)
        let html = """
        <script>
        __sveltekit_x.data = {"w6b2h6/getFreeTierUsage/":{bucket:"ubi",quota:1000,hourlyReplenishment:42,windowHours:24,used:0}};
        </script>
        """

        let snapshot = try AmpUsageParser.parse(html: html, now: now)
        #expect(snapshot.freeUsed == 0)
        #expect(snapshot.freeQuota == 1000)
    }

    @Test
    func missingUsageThrowsParseFailed() {
        let html = "<html><body>No usage here.</body></html>"

        #expect {
            try AmpUsageParser.parse(html: html)
        } throws: { error in
            guard case let AmpUsageError.parseFailed(message) = error else { return false }
            return message.contains("Missing Amp Free usage data")
        }
    }

    @Test
    func signedOutThrowsNotLoggedIn() {
        let html = "<html><body>Please sign in to Amp.</body></html>"

        #expect {
            try AmpUsageParser.parse(html: html)
        } throws: { error in
            guard case AmpUsageError.notLoggedIn = error else { return false }
            return true
        }
    }

    @Test
    func usageSnapshotClampsPercentAndWindow() {
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
    func usageSnapshotOmitsResetWhenHourlyReplenishmentIsZero() {
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
