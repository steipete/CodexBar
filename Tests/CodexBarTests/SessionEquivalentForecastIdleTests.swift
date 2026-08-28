import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

extension SessionEquivalentForecastTests {
    @MainActor
    @Test
    func `usage store preserves learned forecast while current session is idle`() throws {
        let store = UsageStorePlanUtilizationTests.makeStore()
        let fixture = Self.historyFixture(burns: [4, 8, 6, 10])
        store.planUtilizationHistory[.claude] = PlanUtilizationHistoryBuckets(unscoped: fixture.histories)
        let now = fixture.currentSessionReset.addingTimeInterval(-3600)
        let session = RateWindow(
            usedPercent: 0,
            windowMinutes: 300,
            resetsAt: nil,
            resetDescription: nil)
        let weekly = RateWindow(
            usedPercent: 60,
            windowMinutes: 10080,
            resetsAt: now.addingTimeInterval(2 * 24 * 3600),
            resetDescription: nil)

        let forecast = try #require(store.sessionEquivalentForecast(
            provider: .claude,
            sessionWindow: session,
            weeklyWindow: weekly,
            now: now))

        #expect(forecast.sampleCount == 4)
        #expect(forecast.estimatedWindowsToExhaustWeekly > 0)
    }

    @MainActor
    @Test
    func `idle forecast cache refreshes after a historical session completes`() throws {
        let store = UsageStorePlanUtilizationTests.makeStore()
        let fixture = Self.historyFixture(burns: [5, 5, 5])
        store.planUtilizationHistory[.claude] = PlanUtilizationHistoryBuckets(unscoped: fixture.histories)
        store.planUtilizationHistoryRevision = 1
        let thirdReset = fixture.currentSessionReset.addingTimeInterval(-5 * 3600)
        let beforeReset = thirdReset.addingTimeInterval(-61)
        let afterReset = thirdReset.addingTimeInterval(61)
        let session = RateWindow(
            usedPercent: 0,
            windowMinutes: 300,
            resetsAt: nil,
            resetDescription: nil)
        let weekly = RateWindow(
            usedPercent: 15,
            windowMinutes: 10080,
            resetsAt: afterReset.addingTimeInterval(2 * 24 * 3600),
            resetDescription: nil)

        #expect(store.sessionEquivalentForecast(
            provider: .claude,
            sessionWindow: session,
            weeklyWindow: weekly,
            now: beforeReset) == nil)
        #expect(store._sessionEquivalentHistoryScanCountForTesting == 1)

        let forecast = try #require(store.sessionEquivalentForecast(
            provider: .claude,
            sessionWindow: session,
            weeklyWindow: weekly,
            now: afterReset))
        #expect(forecast.sampleCount == 3)
        #expect(store._sessionEquivalentHistoryScanCountForTesting == 2)
    }
}
