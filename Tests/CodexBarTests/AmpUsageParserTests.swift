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
}
