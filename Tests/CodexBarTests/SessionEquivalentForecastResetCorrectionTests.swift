import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct SessionEquivalentForecastResetCorrectionTests {
    @Test(arguments: [2, 3])
    func `old reset reversals do not poison a clean recent history segment`(_ recentSamples: Int) throws {
        let fixture = SessionEquivalentForecastTests.historyFixture(burns: Array(repeating: 6, count: recentSamples))
        let session = fixture.histories[0]
        let oldStart = try #require(session.entries.first?.capturedAt).addingTimeInterval(-150 * 86400)
        let oldEntries = [
            planEntry(at: oldStart, usedPercent: 10, resetsAt: oldStart.addingTimeInterval(5 * 3600)),
            planEntry(
                at: oldStart.addingTimeInterval(600),
                usedPercent: 20,
                resetsAt: oldStart.addingTimeInterval(4.5 * 3600)),
        ]
        let histories = [
            planSeries(name: .session, windowMinutes: 300, entries: oldEntries + session.entries),
            fixture.histories[1],
        ]
        let now = fixture.currentSessionReset.addingTimeInterval(-3600)
        let estimate = SessionEquivalentBurnEstimator.estimate(
            histories: histories, currentSessionResetsAt: fixture.currentSessionReset, now: now)
        if recentSamples < 3 {
            #expect(estimate == nil)
        } else {
            let burn = try #require(estimate)
            #expect(burn.sampleCount == 3)
            #expect(burn.medianWeeklyPercentPerWindow == 6)
            let weekly = try #require(histories[1].entries.last)
            let forecast = try #require(SessionEquivalentForecast.make(
                sessionWindow: RateWindow(
                    usedPercent: 20,
                    windowMinutes: 300,
                    resetsAt: fixture.currentSessionReset,
                    resetDescription: nil),
                weeklyWindow: RateWindow(
                    usedPercent: weekly.usedPercent,
                    windowMinutes: 10080,
                    resetsAt: weekly.resetsAt,
                    resetDescription: nil),
                burnEstimate: burn,
                now: now,
                workDays: nil))
            let detail = UsagePaceText.sessionEquivalentDetail(forecast: forecast)
            #expect(!detail.leftText.isEmpty)
            #expect(!detail.rightText.isEmpty)
        }
    }
}
