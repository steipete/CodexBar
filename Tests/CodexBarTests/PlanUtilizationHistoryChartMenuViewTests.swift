import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct PlanUtilizationHistoryChartMenuViewTests {
    @Test
    func `ollama monthly transition filters old tabs without discarding saved history`() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let histories = [
            PlanUtilizationSeriesHistory(
                name: .session,
                windowMinutes: 300,
                entries: [.init(capturedAt: now, usedPercent: 20, resetsAt: nil)]),
            PlanUtilizationSeriesHistory(
                name: .weekly,
                windowMinutes: 10080,
                entries: [.init(capturedAt: now, usedPercent: 40, resetsAt: nil)]),
            PlanUtilizationSeriesHistory(
                name: .monthly,
                windowMinutes: 43200,
                entries: [.init(capturedAt: now, usedPercent: 12.5, resetsAt: nil)]),
        ]
        let savedData = try JSONEncoder().encode(histories)
        let savedHistories = try JSONDecoder().decode([PlanUtilizationSeriesHistory].self, from: savedData)
        let legacy = try OllamaUsageParser.parse(html: """
        <div><span>Session usage</span><span>20% used</span></div>
        <div><span>Weekly usage</span><span>40% used</span></div>
        """, now: now).toUsageSnapshot()
        let monthly = try OllamaUsageParser.parse(html: """
        <div><span>Monthly usage</span><span>$7.50 of $60 used</span></div>
        """, now: now).toUsageSnapshot()
        let presentation = OllamaProviderDescriptor.descriptor.presentation

        #expect(presentation.planUtilizationSeries(snapshot: legacy) == [.weekly])
        #expect(presentation.planUtilizationSeries(snapshot: monthly) == [.monthly])

        let legacyBefore = PlanUtilizationHistoryChartMenuView._modelSnapshotForTesting(
            histories: savedHistories,
            provider: .ollama,
            snapshot: legacy)
        #expect(legacyBefore.visibleSeries == ["weekly:10080"])
        #expect(legacyBefore.usedPercents.contains(40))

        let monthlyModel = PlanUtilizationHistoryChartMenuView._modelSnapshotForTesting(
            selectedSeriesRawValue: legacyBefore.selectedSeries,
            histories: savedHistories,
            provider: .ollama,
            snapshot: monthly)
        #expect(monthlyModel.visibleSeries == ["monthly:43200"])
        #expect(monthlyModel.selectedSeries == "monthly:43200")
        #expect(monthlyModel.usedPercents.contains(12.5))

        let legacyAfter = PlanUtilizationHistoryChartMenuView._modelSnapshotForTesting(
            selectedSeriesRawValue: monthlyModel.selectedSeries,
            histories: savedHistories,
            provider: .ollama,
            snapshot: legacy)
        #expect(legacyAfter == legacyBefore)
        #expect(savedHistories == histories)

        let withoutCurrentSnapshot = PlanUtilizationHistoryChartMenuView._modelSnapshotForTesting(
            histories: savedHistories,
            provider: .ollama)
        #expect(withoutCurrentSnapshot.visibleSeries == ["session:300", "weekly:10080", "monthly:43200"])
    }

    @Test
    func `ollama monthly history retains a currently reported weekly lane`() throws {
        let snapshot = try OllamaUsageParser.parse(html: """
        <div><span>Monthly usage</span><span>$7.50 of $60 used</span></div>
        <div><span>Weekly usage</span><span>40% used</span></div>
        """).toUsageSnapshot()

        #expect(OllamaProviderDescriptor.descriptor.presentation.planUtilizationSeries(snapshot: snapshot)
            == [.monthly, .weekly])
    }

    @Test
    func `merged entries preserve first occurrence order while removing duplicates`() {
        let first = PlanUtilizationHistoryEntry(
            capturedAt: Date(timeIntervalSince1970: 100),
            usedPercent: 10,
            resetsAt: Date(timeIntervalSince1970: 200))
        let second = PlanUtilizationHistoryEntry(
            capturedAt: Date(timeIntervalSince1970: 300),
            usedPercent: 20,
            resetsAt: nil)

        let merged = PlanUtilizationHistoryChartMenuView.mergedEntries([
            first,
            second,
            first,
            second,
        ])

        #expect(merged == [first, second])
    }

    @Test
    func `generic primary weekly window keeps weekly history visible`() {
        let history = PlanUtilizationSeriesHistory(
            name: .weekly,
            windowMinutes: 10080,
            entries: [
                PlanUtilizationHistoryEntry(
                    capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    usedPercent: 42,
                    resetsAt: nil),
            ])
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 42, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000))

        let model = PlanUtilizationHistoryChartMenuView._modelSnapshotForTesting(
            histories: [history],
            provider: .zai,
            snapshot: snapshot)

        #expect(model.visibleSeries == ["weekly:10080"])
        #expect(model.selectedSeries == "weekly:10080")
    }

    @Test
    func `generic unknown weekly extra window does not filter saved history`() {
        let history = PlanUtilizationSeriesHistory(
            name: .weekly,
            windowMinutes: 10080,
            entries: [
                PlanUtilizationHistoryEntry(
                    capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    usedPercent: 42,
                    resetsAt: nil),
            ])
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            extraRateWindows: [
                NamedRateWindow(
                    id: "weekly-reset-only",
                    title: "Weekly reset",
                    window: RateWindow(
                        usedPercent: 0,
                        windowMinutes: 10080,
                        resetsAt: Date(timeIntervalSince1970: 1_700_003_600),
                        resetDescription: nil),
                    usageKnown: false),
            ],
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000))

        let model = PlanUtilizationHistoryChartMenuView._modelSnapshotForTesting(
            histories: [history],
            provider: .zed,
            snapshot: snapshot)

        #expect(model.visibleSeries == ["weekly:10080"])
        #expect(model.selectedSeries == "weekly:10080")
    }

    @Test
    func `ollama monthly snapshot filters saved legacy windows out of the history chart`() {
        let legacyWeekly = PlanUtilizationSeriesHistory(
            name: .weekly,
            windowMinutes: 10080,
            entries: [
                PlanUtilizationHistoryEntry(
                    capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    usedPercent: 42,
                    resetsAt: nil),
            ])
        let legacySession = PlanUtilizationSeriesHistory(
            name: .session,
            windowMinutes: 300,
            entries: [
                PlanUtilizationHistoryEntry(
                    capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    usedPercent: 17,
                    resetsAt: nil),
            ])
        let monthly = PlanUtilizationSeriesHistory(
            name: .monthly,
            windowMinutes: ProviderPaceCapability.monthlyWindowSentinelMinutes,
            entries: [
                PlanUtilizationHistoryEntry(
                    capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    usedPercent: 7,
                    resetsAt: Date(timeIntervalSince1970: 1_700_100_000)),
            ])
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 7,
                windowMinutes: ProviderPaceCapability.monthlyWindowSentinelMinutes,
                resetsAt: Date(timeIntervalSince1970: 1_700_100_000),
                resetDescription: nil),
            secondary: nil,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000))

        let model = PlanUtilizationHistoryChartMenuView._modelSnapshotForTesting(
            histories: [legacyWeekly, legacySession, monthly],
            provider: .ollama,
            snapshot: snapshot)

        #expect(model.visibleSeries == ["monthly:\(ProviderPaceCapability.monthlyWindowSentinelMinutes)"])
        #expect(model.selectedSeries == "monthly:\(ProviderPaceCapability.monthlyWindowSentinelMinutes)")
    }

    @Test
    func `ollama legacy snapshot keeps the weekly history series visible`() {
        let legacyWeekly = PlanUtilizationSeriesHistory(
            name: .weekly,
            windowMinutes: 10080,
            entries: [
                PlanUtilizationHistoryEntry(
                    capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    usedPercent: 42,
                    resetsAt: nil),
            ])
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 42, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 42, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000))

        let model = PlanUtilizationHistoryChartMenuView._modelSnapshotForTesting(
            histories: [legacyWeekly],
            provider: .ollama,
            snapshot: snapshot)

        #expect(model.visibleSeries == ["weekly:10080"])
        #expect(model.selectedSeries == "weekly:10080")
    }

    @Test
    func `antigravity structured summary exposes session and weekly tabs matching claude parity`() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let histories = [
            PlanUtilizationSeriesHistory(
                name: .session,
                windowMinutes: 300,
                entries: [PlanUtilizationHistoryEntry(capturedAt: now, usedPercent: 25, resetsAt: nil)]),
            PlanUtilizationSeriesHistory(
                name: .weekly,
                windowMinutes: 10080,
                entries: [PlanUtilizationHistoryEntry(capturedAt: now, usedPercent: 45, resetsAt: nil)]),
        ]
        let sessionWindow = RateWindow(
            usedPercent: 25, windowMinutes: 300, resetsAt: now.addingTimeInterval(3600), resetDescription: nil)
        let weeklyWindow = RateWindow(
            usedPercent: 45, windowMinutes: 10080, resetsAt: now.addingTimeInterval(86400), resetDescription: nil)

        let fullSnapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            extraRateWindows: [
                NamedRateWindow(
                    id: "antigravity-quota-summary-gemini-5h", title: "Gemini 5-hour", window: sessionWindow),
                NamedRateWindow(
                    id: "antigravity-quota-summary-gemini-weekly", title: "Gemini weekly", window: weeklyWindow),
            ],
            updatedAt: now)
        let fullModel = PlanUtilizationHistoryChartMenuView._modelSnapshotForTesting(
            histories: histories,
            provider: .antigravity,
            snapshot: fullSnapshot,
            referenceDate: now)
        #expect(fullModel.visibleSeries == ["session:300", "weekly:10080"])
        #expect(fullModel.visibleSeriesTitles == [L("Session"), L("Weekly")])

        let weeklyOnlySnapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            extraRateWindows: [
                NamedRateWindow(
                    id: "antigravity-quota-summary-gemini-weekly", title: "Gemini weekly", window: weeklyWindow),
            ],
            updatedAt: now)
        let weeklyOnlyModel = PlanUtilizationHistoryChartMenuView._modelSnapshotForTesting(
            histories: histories,
            provider: .antigravity,
            snapshot: weeklyOnlySnapshot,
            referenceDate: now)
        #expect(weeklyOnlyModel.visibleSeries == ["weekly:10080"])
        #expect(weeklyOnlyModel.visibleSeriesTitles == [L("Weekly")])
    }

    @Test
    func `antigravity four lane snapshot exposes active Claude GPT tabs and hides idle ones`() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let histories = [
            PlanUtilizationSeriesHistory(
                name: .session,
                windowMinutes: 300,
                entries: [PlanUtilizationHistoryEntry(capturedAt: now, usedPercent: 25, resetsAt: nil)]),
            PlanUtilizationSeriesHistory(
                name: .weekly,
                windowMinutes: 10080,
                entries: [PlanUtilizationHistoryEntry(capturedAt: now, usedPercent: 45, resetsAt: nil)]),
            PlanUtilizationSeriesHistory(
                name: .antigravityClaudeGPTSession,
                windowMinutes: 300,
                entries: [PlanUtilizationHistoryEntry(capturedAt: now, usedPercent: 35, resetsAt: nil)]),
            PlanUtilizationSeriesHistory(
                name: .antigravityClaudeGPTWeekly,
                windowMinutes: 10080,
                entries: [PlanUtilizationHistoryEntry(capturedAt: now, usedPercent: 60, resetsAt: nil)]),
        ]
        let geminiSession = RateWindow(
            usedPercent: 25, windowMinutes: 300, resetsAt: now.addingTimeInterval(3600), resetDescription: nil)
        let geminiWeekly = RateWindow(
            usedPercent: 45, windowMinutes: 10080, resetsAt: now.addingTimeInterval(86400), resetDescription: nil)
        let activeClaudeSession = RateWindow(
            usedPercent: 35, windowMinutes: 300, resetsAt: now.addingTimeInterval(3600), resetDescription: nil)
        let activeClaudeWeekly = RateWindow(
            usedPercent: 60, windowMinutes: 10080, resetsAt: now.addingTimeInterval(86400), resetDescription: nil)

        let activeSnapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            extraRateWindows: [
                NamedRateWindow(
                    id: "antigravity-quota-summary-gemini-5h", title: "Gemini 5-hour", window: geminiSession),
                NamedRateWindow(
                    id: "antigravity-quota-summary-gemini-weekly", title: "Gemini weekly", window: geminiWeekly),
                NamedRateWindow(
                    id: "antigravity-quota-summary-3p-5h", title: "Claude/GPT 5-hour", window: activeClaudeSession),
                NamedRateWindow(
                    id: "antigravity-quota-summary-3p-weekly",
                    title: "Claude/GPT weekly",
                    window: activeClaudeWeekly),
            ],
            updatedAt: now)
        let activeModel = PlanUtilizationHistoryChartMenuView._modelSnapshotForTesting(
            histories: histories,
            provider: .antigravity,
            snapshot: activeSnapshot,
            referenceDate: now)
        #expect(activeModel.visibleSeries == [
            "session:300",
            "weekly:10080",
            "antigravityClaudeGPTSession:300",
            "antigravityClaudeGPTWeekly:10080",
        ])
        #expect(activeModel.visibleSeriesTitles == [
            L("Session"),
            L("Weekly"),
            "Claude/GPT 5h",
            "Claude/GPT \(L("Weekly"))",
        ])

        let idleClaudeSession = RateWindow(
            usedPercent: 0, windowMinutes: 300, resetsAt: now.addingTimeInterval(3600), resetDescription: nil)
        let idleClaudeWeekly = RateWindow(
            usedPercent: 0, windowMinutes: 10080, resetsAt: now.addingTimeInterval(86400), resetDescription: nil)
        let idleSnapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            extraRateWindows: [
                NamedRateWindow(
                    id: "antigravity-quota-summary-gemini-5h", title: "Gemini 5-hour", window: geminiSession),
                NamedRateWindow(
                    id: "antigravity-quota-summary-gemini-weekly", title: "Gemini weekly", window: geminiWeekly),
                NamedRateWindow(
                    id: "antigravity-quota-summary-3p-5h", title: "Claude/GPT 5-hour", window: idleClaudeSession),
                NamedRateWindow(
                    id: "antigravity-quota-summary-3p-weekly",
                    title: "Claude/GPT weekly",
                    window: idleClaudeWeekly),
            ],
            updatedAt: now)
        let idleModel = PlanUtilizationHistoryChartMenuView._modelSnapshotForTesting(
            histories: histories,
            provider: .antigravity,
            snapshot: idleSnapshot,
            referenceDate: now)
        #expect(idleModel.visibleSeries == ["session:300", "weekly:10080"])
    }

    @MainActor
    @Test
    func `antigravity idle Gemini with active Claude GPT and snapshot nil reload keep all four chart series`() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let histories = [
            PlanUtilizationSeriesHistory(
                name: .session,
                windowMinutes: 300,
                entries: [
                    .init(
                        capturedAt: now.addingTimeInterval(-3600),
                        usedPercent: 0,
                        resetsAt: now.addingTimeInterval(4 * 3600)),
                    .init(capturedAt: now, usedPercent: 0, resetsAt: now.addingTimeInterval(4 * 3600)),
                ]),
            PlanUtilizationSeriesHistory(
                name: .weekly,
                windowMinutes: 10080,
                entries: [
                    .init(
                        capturedAt: now.addingTimeInterval(-3600),
                        usedPercent: 0,
                        resetsAt: now.addingTimeInterval(5 * 86400)),
                    .init(capturedAt: now, usedPercent: 0, resetsAt: now.addingTimeInterval(5 * 86400)),
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
                        usedPercent: 25,
                        resetsAt: now.addingTimeInterval(6 * 86400)),
                    .init(capturedAt: now, usedPercent: 55, resetsAt: now.addingTimeInterval(6 * 86400)),
                ]),
        ]
        let idleGeminiSnapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            extraRateWindows: [
                NamedRateWindow(
                    id: "antigravity-quota-summary-gemini-5h",
                    title: "Gemini 5-hour",
                    window: RateWindow(
                        usedPercent: 0,
                        windowMinutes: 300,
                        resetsAt: now.addingTimeInterval(4 * 3600),
                        resetDescription: nil)),
                NamedRateWindow(
                    id: "antigravity-quota-summary-gemini-weekly",
                    title: "Gemini weekly",
                    window: RateWindow(
                        usedPercent: 0,
                        windowMinutes: 10080,
                        resetsAt: now.addingTimeInterval(5 * 86400),
                        resetDescription: nil)),
                NamedRateWindow(
                    id: "antigravity-quota-summary-3p-5h",
                    title: "Claude/GPT 5-hour",
                    window: RateWindow(
                        usedPercent: 40,
                        windowMinutes: 300,
                        resetsAt: now.addingTimeInterval(3 * 3600),
                        resetDescription: nil)),
                NamedRateWindow(
                    id: "antigravity-quota-summary-3p-weekly",
                    title: "Claude/GPT weekly",
                    window: RateWindow(
                        usedPercent: 55,
                        windowMinutes: 10080,
                        resetsAt: now.addingTimeInterval(6 * 86400),
                        resetDescription: nil)),
            ],
            updatedAt: now)

        let expectedSeries = [
            "session:300",
            "weekly:10080",
            "antigravityClaudeGPTSession:300",
            "antigravityClaudeGPTWeekly:10080",
        ]
        let activeModel = PlanUtilizationHistoryChartMenuView._modelSnapshotForTesting(
            histories: histories,
            provider: .antigravity,
            snapshot: idleGeminiSnapshot,
            referenceDate: now)
        #expect(activeModel.visibleSeries == expectedSeries)

        let reloadedModel = PlanUtilizationHistoryChartMenuView._modelSnapshotForTesting(
            histories: histories,
            provider: .antigravity,
            snapshot: nil,
            referenceDate: now)
        #expect(reloadedModel.visibleSeries == expectedSeries)

        let reloadedBurndown = QuotaBurndownChartMenuView(
            provider: .antigravity,
            histories: histories,
            snapshot: nil,
            width: 400,
            referenceDate: now)
        #expect(Set(reloadedBurndown._seriesTitlesForTesting.keys) == Set(expectedSeries))
        #expect(reloadedBurndown._seriesRemainingForTesting["antigravityClaudeGPTSession:300"] == 60)
        #expect(reloadedBurndown._seriesRemainingForTesting["antigravityClaudeGPTWeekly:10080"] == 45)
    }
}
