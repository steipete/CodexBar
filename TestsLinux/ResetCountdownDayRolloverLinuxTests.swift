#if os(Linux)
import Foundation
import Testing
@testable import CodexBarCore

struct ResetCountdownDayRolloverLinuxTests {
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func at(hoursFromNow hours: Double) -> Date {
        Self.now.addingTimeInterval(hours * 3600)
    }

    @Test
    func `Windsurf web reset at exactly 24h rolls over to a day`() {
        // Was "Resets in 24h 0m"; the day form must be reachable at the 24h boundary.
        #expect(
            WindsurfGetPlanStatusResponse.formatResetDescription(self.at(hoursFromNow: 24), now: Self.now)
                == "Resets in 1d 0h")
    }

    @Test
    func `Windsurf web reset above 24h shows day and hour`() {
        #expect(
            WindsurfGetPlanStatusResponse.formatResetDescription(self.at(hoursFromNow: 25), now: Self.now)
                == "Resets in 1d 1h")
    }

    @Test
    func `Windsurf web reset below 24h stays in hours`() {
        #expect(
            WindsurfGetPlanStatusResponse.formatResetDescription(self.at(hoursFromNow: 23), now: Self.now)
                == "Resets in 23h 0m")
    }

    @Test
    func `Windsurf cached reset at exactly 24h rolls over to a day`() {
        #expect(
            WindsurfCachedPlanInfo.formatResetDescription(self.at(hoursFromNow: 24), now: Self.now)
                == "Resets in 1d 0h")
    }

    @Test
    func `Zed cycle at exactly 24h rolls over to a day`() {
        // Was "Cycle ends in 24h 0m".
        #expect(
            ZedUsageSnapshot.formatResetDescription(self.at(hoursFromNow: 24), now: Self.now)
                == "Cycle ends in 1d 0h")
    }

    @Test
    func `JetBrains reset at exactly 24h rolls over to a day`() {
        #expect(
            JetBrainsStatusSnapshot.formatResetDescription(self.at(hoursFromNow: 24), now: Self.now)
                == "Resets in 1d 0h")
    }
}
#endif
