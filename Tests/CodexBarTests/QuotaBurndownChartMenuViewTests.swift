import Foundation
import Testing
@testable import CodexBar

@MainActor
struct QuotaBurndownChartMenuViewTests {
    @Test(arguments: [PlanUtilizationSeriesName.session, .weekly])
    func `saved legacy Codex thirty day windows display as monthly`(name: PlanUtilizationSeriesName) throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let history = PlanUtilizationSeriesHistory(
            name: name,
            windowMinutes: 43200,
            entries: [.init(capturedAt: now, usedPercent: 40, resetsAt: now.addingTimeInterval(86400))])
        let saved = try JSONDecoder().decode(
            PlanUtilizationSeriesHistory.self,
            from: JSONEncoder().encode(history))
        let view = QuotaBurndownChartMenuView(
            provider: .codex,
            histories: [saved],
            width: 400,
            referenceDate: now)

        #expect(saved.name == name)
        #expect(view._seriesTitlesForTesting == ["monthly:43200": L("Monthly")])
        #expect(view._seriesRemainingForTesting == ["monthly:43200": 60])
    }

    @Test
    func `legacy and migrated monthly captures merge without duplicate tabs or lost samples`() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let reset = now.addingTimeInterval(86400)
        let histories = [
            PlanUtilizationSeriesHistory(name: .session, windowMinutes: 43200, entries: [
                .init(capturedAt: now.addingTimeInterval(-7200), usedPercent: 20, resetsAt: reset),
            ]),
            PlanUtilizationSeriesHistory(name: .weekly, windowMinutes: 43200, entries: [
                .init(capturedAt: now.addingTimeInterval(-3600), usedPercent: 40, resetsAt: reset),
            ]),
            PlanUtilizationSeriesHistory(name: .monthly, windowMinutes: 43200, entries: [
                .init(capturedAt: now.addingTimeInterval(-10800), usedPercent: 10, resetsAt: reset),
                .init(capturedAt: now.addingTimeInterval(-7200), usedPercent: 20, resetsAt: reset),
            ]),
        ]
        let view = QuotaBurndownChartMenuView(
            provider: .codex,
            histories: histories,
            width: 400,
            referenceDate: now)

        #expect(view._seriesTitlesForTesting == ["monthly:43200": L("Monthly")])
        #expect(view._seriesRemainingForTesting == ["monthly:43200": 60])
        #expect(view._seriesSampleCountsForTesting == ["monthly:43200": 3])
        #expect(view._seriesLastKnownMessagesForTesting["monthly:43200"] == LastKnownUsagePresentation.message(
            capturedAt: now.addingTimeInterval(-3600),
            now: now))
    }

    @Test
    func `keeps same duration quota lanes separate`() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let histories = [
            PlanUtilizationSeriesHistory(
                name: .weekly,
                windowMinutes: 10080,
                entries: [
                    .init(capturedAt: now, usedPercent: 20, resetsAt: now.addingTimeInterval(3600)),
                ]),
            PlanUtilizationSeriesHistory(
                name: .opus,
                windowMinutes: 10080,
                entries: [
                    .init(
                        capturedAt: now.addingTimeInterval(-7200),
                        usedPercent: 70,
                        resetsAt: now.addingTimeInterval(7200)),
                ]),
        ]

        let view = QuotaBurndownChartMenuView(
            provider: .claude,
            histories: histories,
            width: 400,
            referenceDate: now)

        #expect(view._seriesRemainingForTesting["weekly:10080"] == 80)
        #expect(view._seriesRemainingForTesting["opus:10080"] == 30)
        #expect(view._seriesTitlesForTesting["opus:10080"] == "Sonnet")
        #expect(view._seriesLastKnownMessagesForTesting["weekly:10080"] == LastKnownUsagePresentation.message(
            capturedAt: now,
            now: now))
        #expect(view._seriesLastKnownMessagesForTesting["opus:10080"] == LastKnownUsagePresentation.message(
            capturedAt: now.addingTimeInterval(-7200),
            now: now))
    }

    @Test(arguments: [60.0, 21600.0, 172_800.0])
    func `saved weekly usage reports actual capture time rather than current time`(age: TimeInterval) {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let capturedAt = now.addingTimeInterval(-age)
        let history = PlanUtilizationSeriesHistory(
            name: .weekly,
            windowMinutes: 10080,
            entries: [.init(capturedAt: capturedAt, usedPercent: 40, resetsAt: now.addingTimeInterval(86400))])
        let view = QuotaBurndownChartMenuView(
            provider: .codex,
            histories: [history],
            width: 400,
            referenceDate: now)

        #expect(view.hasSeries)
        #expect(view._seriesRemainingForTesting["weekly:10080"] == 60)
        #expect(view._seriesLastKnownMessagesForTesting["weekly:10080"] == LastKnownUsagePresentation.message(
            capturedAt: capturedAt,
            now: now))
        #expect(view._seriesLastKnownMessagesForTesting["weekly:10080"] != LastKnownUsagePresentation.message(
            capturedAt: now,
            now: now))
    }

    @Test
    func `hides a completed reset window`() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let history = PlanUtilizationSeriesHistory(
            name: .session,
            windowMinutes: 300,
            entries: [
                .init(
                    capturedAt: now.addingTimeInterval(-3600),
                    usedPercent: 40,
                    resetsAt: now.addingTimeInterval(-1)),
            ])

        let view = QuotaBurndownChartMenuView(
            provider: .codex,
            histories: [history],
            width: 400,
            referenceDate: now)

        #expect(!view.hasSeries)
    }
}
