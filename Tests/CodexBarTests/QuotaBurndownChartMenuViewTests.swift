import CodexBarCore
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
    func `kiro monthly credits show a burndown`() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let reset = now.addingTimeInterval(20 * 86400)
        let history = PlanUtilizationSeriesHistory(name: .monthly, windowMinutes: 43200, entries: [
            .init(capturedAt: now.addingTimeInterval(-86400), usedPercent: 10, resetsAt: reset),
            .init(capturedAt: now, usedPercent: 18, resetsAt: reset),
        ])
        let view = QuotaBurndownChartMenuView(
            provider: .kiro,
            histories: [history],
            width: 400,
            referenceDate: now)

        #expect(view._seriesRemainingForTesting == ["monthly:43200": 82])
        #expect(view._seriesSampleCountsForTesting == ["monthly:43200": 2])
    }

    @Test(arguments: [
        ("2026-02-01T00:00:00Z", "2026-03-01T00:00:00Z"),
        ("2026-09-01T00:00:00Z", "2026-10-01T00:00:00Z"),
        ("2026-10-01T00:00:00Z", "2026-11-01T00:00:00Z"),
    ])
    func `kiro burndown starts at the calendar month start`(start: String, reset: String) throws {
        let start = try #require(ISO8601DateFormatter().date(from: start))
        let reset = try #require(ISO8601DateFormatter().date(from: reset))
        let now = start.addingTimeInterval(3600)
        let history = PlanUtilizationSeriesHistory(name: .monthly, windowMinutes: 43200, entries: [
            .init(capturedAt: now, usedPercent: 1, resetsAt: reset),
        ])
        let view = QuotaBurndownChartMenuView(
            provider: .kiro,
            histories: [history],
            width: 400,
            referenceDate: now)

        #expect(view._seriesStartsForTesting == ["monthly:43200": start])
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

    @Test
    func `antigravity structured session and weekly histories render session and weekly burndown tabs`() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let histories = [
            PlanUtilizationSeriesHistory(
                name: .session,
                windowMinutes: 300,
                entries: [
                    .init(
                        capturedAt: now.addingTimeInterval(-3600),
                        usedPercent: 15,
                        resetsAt: now.addingTimeInterval(4 * 3600)),
                    .init(
                        capturedAt: now,
                        usedPercent: 30,
                        resetsAt: now.addingTimeInterval(4 * 3600)),
                ]),
            PlanUtilizationSeriesHistory(
                name: .weekly,
                windowMinutes: 10080,
                entries: [
                    .init(
                        capturedAt: now.addingTimeInterval(-86400),
                        usedPercent: 20,
                        resetsAt: now.addingTimeInterval(5 * 86400)),
                    .init(
                        capturedAt: now,
                        usedPercent: 45,
                        resetsAt: now.addingTimeInterval(5 * 86400)),
                ]),
        ]

        let view = QuotaBurndownChartMenuView(
            provider: .antigravity,
            histories: histories,
            snapshot: UsageSnapshot(
                primary: nil,
                secondary: nil,
                extraRateWindows: [
                    NamedRateWindow(
                        id: "antigravity-quota-summary-gemini-session",
                        title: "Gemini",
                        window: RateWindow(
                            usedPercent: 30,
                            windowMinutes: 300,
                            resetsAt: now.addingTimeInterval(4 * 3600),
                            resetDescription: nil)),
                    NamedRateWindow(
                        id: "antigravity-quota-summary-gemini-weekly",
                        title: "Gemini",
                        window: RateWindow(
                            usedPercent: 45,
                            windowMinutes: 10080,
                            resetsAt: now.addingTimeInterval(5 * 86400),
                            resetDescription: nil)),
                ],
                updatedAt: now),
            width: 400,
            referenceDate: now)

        #expect(view.hasSeries)
        #expect(view._seriesTitlesForTesting["session:300"] == L("Session"))
        #expect(view._seriesTitlesForTesting["weekly:10080"] == L("Weekly"))
        #expect(!view._seriesTitlesForTesting.values.contains("Claude and GPT"))
        #expect(view._seriesRemainingForTesting["session:300"] == 70)
        #expect(view._seriesRemainingForTesting["weekly:10080"] == 55)
    }

    @Test
    func `antigravity pool observation histories do not fabricate burndown curves`() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let observationHistories = [
            PlanUtilizationSeriesHistory(
                name: .antigravityGemini,
                windowMinutes: 0,
                entries: [
                    .init(capturedAt: now, usedPercent: 25, resetsAt: now.addingTimeInterval(3600)),
                ]),
            PlanUtilizationSeriesHistory(
                name: .antigravityClaudeGPT,
                windowMinutes: 0,
                entries: [
                    .init(capturedAt: now, usedPercent: 50, resetsAt: now.addingTimeInterval(3600)),
                ]),
        ]

        let observationView = QuotaBurndownChartMenuView(
            provider: .antigravity,
            histories: observationHistories,
            width: 400,
            referenceDate: now)
        #expect(!observationView.hasSeries)

        let staleStructuredWithLiveObservationSnapshot = QuotaBurndownChartMenuView(
            provider: .antigravity,
            histories: [
                PlanUtilizationSeriesHistory(
                    name: .weekly,
                    windowMinutes: 10080,
                    entries: [
                        .init(capturedAt: now, usedPercent: 40, resetsAt: now.addingTimeInterval(5 * 86400)),
                    ]),
            ],
            snapshot: UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 40,
                    windowMinutes: nil,
                    resetsAt: now.addingTimeInterval(3600),
                    resetDescription: nil),
                secondary: nil,
                updatedAt: now),
            width: 400,
            referenceDate: now)
        #expect(!staleStructuredWithLiveObservationSnapshot.hasSeries)
    }

    @Test
    func `antigravity live structured snapshot keeps burndown when histories contain newer observation entry`() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let mixedHistories = [
            PlanUtilizationSeriesHistory(
                name: .session,
                windowMinutes: 300,
                entries: [
                    .init(
                        capturedAt: now.addingTimeInterval(-1800),
                        usedPercent: 20,
                        resetsAt: now.addingTimeInterval(4 * 3600)),
                ]),
            PlanUtilizationSeriesHistory(
                name: .weekly,
                windowMinutes: 10080,
                entries: [
                    .init(
                        capturedAt: now.addingTimeInterval(-1800),
                        usedPercent: 35,
                        resetsAt: now.addingTimeInterval(5 * 86400)),
                ]),
            PlanUtilizationSeriesHistory(
                name: .antigravityGemini,
                windowMinutes: 0,
                entries: [
                    .init(
                        capturedAt: now.addingTimeInterval(-60),
                        usedPercent: 50,
                        resetsAt: now.addingTimeInterval(3600)),
                ]),
        ]
        let structuredSnapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            extraRateWindows: [
                NamedRateWindow(
                    id: "antigravity-quota-summary-gemini-session",
                    title: "Gemini",
                    window: RateWindow(
                        usedPercent: 20,
                        windowMinutes: 300,
                        resetsAt: now.addingTimeInterval(4 * 3600),
                        resetDescription: nil)),
                NamedRateWindow(
                    id: "antigravity-quota-summary-gemini-weekly",
                    title: "Gemini",
                    window: RateWindow(
                        usedPercent: 35,
                        windowMinutes: 10080,
                        resetsAt: now.addingTimeInterval(5 * 86400),
                        resetDescription: nil)),
            ],
            updatedAt: now)

        let view = QuotaBurndownChartMenuView(
            provider: .antigravity,
            histories: mixedHistories,
            snapshot: structuredSnapshot,
            width: 400,
            referenceDate: now)

        #expect(view.hasSeries)
        #expect(view._seriesTitlesForTesting == [
            "session:300": L("Session"),
            "weekly:10080": L("Weekly"),
        ])
        #expect(view._seriesRemainingForTesting == [
            "session:300": 80,
            "weekly:10080": 65,
        ])
    }

    @Test
    func `antigravity active Claude GPT histories render burndown alongside Gemini and stay hidden when idle`() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let histories = [
            PlanUtilizationSeriesHistory(
                name: .session,
                windowMinutes: 300,
                entries: [
                    .init(
                        capturedAt: now.addingTimeInterval(-3600),
                        usedPercent: 10,
                        resetsAt: now.addingTimeInterval(4 * 3600)),
                    .init(capturedAt: now, usedPercent: 25, resetsAt: now.addingTimeInterval(4 * 3600)),
                ]),
            PlanUtilizationSeriesHistory(
                name: .weekly,
                windowMinutes: 10080,
                entries: [
                    .init(
                        capturedAt: now.addingTimeInterval(-3600),
                        usedPercent: 20,
                        resetsAt: now.addingTimeInterval(5 * 86400)),
                    .init(capturedAt: now, usedPercent: 30, resetsAt: now.addingTimeInterval(5 * 86400)),
                ]),
            PlanUtilizationSeriesHistory(
                name: .antigravityClaudeGPTSession,
                windowMinutes: 300,
                entries: [
                    .init(
                        capturedAt: now.addingTimeInterval(-3600),
                        usedPercent: 15,
                        resetsAt: now.addingTimeInterval(3 * 3600)),
                    .init(capturedAt: now, usedPercent: 40, resetsAt: now.addingTimeInterval(3 * 3600)),
                ]),
            PlanUtilizationSeriesHistory(
                name: .antigravityClaudeGPTWeekly,
                windowMinutes: 10080,
                entries: [
                    .init(
                        capturedAt: now.addingTimeInterval(-3600),
                        usedPercent: 30,
                        resetsAt: now.addingTimeInterval(6 * 86400)),
                    .init(capturedAt: now, usedPercent: 55, resetsAt: now.addingTimeInterval(6 * 86400)),
                ]),
        ]

        func makeWindow(used: Double, minutes: Int, resetsAt: Date) -> RateWindow {
            RateWindow(
                usedPercent: used,
                windowMinutes: minutes,
                resetsAt: resetsAt,
                resetDescription: nil)
        }

        let activeSnapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            extraRateWindows: [
                NamedRateWindow(
                    id: "antigravity-quota-summary-gemini-5h",
                    title: "Gemini 5-hour",
                    window: makeWindow(used: 25, minutes: 300, resetsAt: now.addingTimeInterval(4 * 3600))),
                NamedRateWindow(
                    id: "antigravity-quota-summary-gemini-weekly",
                    title: "Gemini weekly",
                    window: makeWindow(used: 30, minutes: 10080, resetsAt: now.addingTimeInterval(5 * 86400))),
                NamedRateWindow(
                    id: "antigravity-quota-summary-3p-5h",
                    title: "Claude/GPT 5-hour",
                    window: makeWindow(used: 40, minutes: 300, resetsAt: now.addingTimeInterval(3 * 3600))),
                NamedRateWindow(
                    id: "antigravity-quota-summary-3p-weekly",
                    title: "Claude/GPT weekly",
                    window: makeWindow(used: 55, minutes: 10080, resetsAt: now.addingTimeInterval(6 * 86400))),
            ],
            updatedAt: now)

        let activeView = QuotaBurndownChartMenuView(
            provider: .antigravity,
            histories: histories,
            snapshot: activeSnapshot,
            width: 400,
            referenceDate: now)
        #expect(activeView._seriesTitlesForTesting == [
            "session:300": L("Session"),
            "weekly:10080": L("Weekly"),
            "antigravityClaudeGPTSession:300": "Claude/GPT 5h",
            "antigravityClaudeGPTWeekly:10080": "Claude/GPT \(L("Weekly"))",
        ])
        #expect(activeView._seriesRemainingForTesting["antigravityClaudeGPTSession:300"] == 60)
        #expect(activeView._seriesRemainingForTesting["antigravityClaudeGPTWeekly:10080"] == 45)

        let idleSnapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            extraRateWindows: [
                NamedRateWindow(
                    id: "antigravity-quota-summary-gemini-5h",
                    title: "Gemini 5-hour",
                    window: makeWindow(used: 25, minutes: 300, resetsAt: now.addingTimeInterval(4 * 3600))),
                NamedRateWindow(
                    id: "antigravity-quota-summary-gemini-weekly",
                    title: "Gemini weekly",
                    window: makeWindow(used: 30, minutes: 10080, resetsAt: now.addingTimeInterval(5 * 86400))),
                NamedRateWindow(
                    id: "antigravity-quota-summary-3p-5h",
                    title: "Claude/GPT 5-hour",
                    window: makeWindow(used: 0, minutes: 300, resetsAt: now.addingTimeInterval(3 * 3600))),
                NamedRateWindow(
                    id: "antigravity-quota-summary-3p-weekly",
                    title: "Claude/GPT weekly",
                    window: makeWindow(used: 0, minutes: 10080, resetsAt: now.addingTimeInterval(6 * 86400))),
            ],
            updatedAt: now)

        let idleView = QuotaBurndownChartMenuView(
            provider: .antigravity,
            histories: histories,
            snapshot: idleSnapshot,
            width: 400,
            referenceDate: now)
        #expect(idleView._seriesTitlesForTesting == [
            "session:300": L("Session"),
            "weekly:10080": L("Weekly"),
        ])
    }
}
