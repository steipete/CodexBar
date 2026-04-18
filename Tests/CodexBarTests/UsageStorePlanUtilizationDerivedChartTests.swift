import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct UsageStorePlanUtilizationDerivedChartTests {
    @MainActor
    @Test
    func `chart uses requested native series without cross series selection`() {
        let firstBoundary = Date(timeIntervalSince1970: 1_710_000_000)
        let secondBoundary = firstBoundary.addingTimeInterval(7 * 24 * 60 * 60)
        let histories = [
            planSeries(name: .session, windowMinutes: 300, entries: [
                planEntry(at: firstBoundary.addingTimeInterval(-30 * 60), usedPercent: 20, resetsAt: firstBoundary),
            ]),
            planSeries(name: .weekly, windowMinutes: 10080, entries: [
                planEntry(at: firstBoundary.addingTimeInterval(-30 * 60), usedPercent: 62, resetsAt: firstBoundary),
                planEntry(at: secondBoundary.addingTimeInterval(-30 * 60), usedPercent: 48, resetsAt: secondBoundary),
            ]),
        ]

        let model = PlanUtilizationHistoryChartMenuView._modelSnapshotForTesting(
            selectedSeriesRawValue: "weekly:10080",
            histories: histories,
            provider: .codex,
            referenceDate: secondBoundary)

        #expect(model.selectedSeries == "weekly:10080")
        #expect(model.usedPercents == [62, 48])
    }

    @MainActor
    @Test
    func `chart exposes claude opus as separate native tab`() {
        let boundary = Date(timeIntervalSince1970: 1_710_000_000)
        let histories = [
            planSeries(name: .session, windowMinutes: 300, entries: [
                planEntry(at: boundary.addingTimeInterval(-30 * 60), usedPercent: 10, resetsAt: boundary),
            ]),
            planSeries(name: .weekly, windowMinutes: 10080, entries: [
                planEntry(at: boundary.addingTimeInterval(-30 * 60), usedPercent: 20, resetsAt: boundary),
            ]),
            planSeries(name: .opus, windowMinutes: 10080, entries: [
                planEntry(at: boundary.addingTimeInterval(-30 * 60), usedPercent: 30, resetsAt: boundary),
            ]),
        ]

        let model = PlanUtilizationHistoryChartMenuView._modelSnapshotForTesting(
            histories: histories,
            provider: .claude,
            referenceDate: boundary)

        #expect(model.visibleSeries == ["session:300", "weekly:10080", "opus:10080"])
    }
}
