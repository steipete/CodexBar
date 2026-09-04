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
}
