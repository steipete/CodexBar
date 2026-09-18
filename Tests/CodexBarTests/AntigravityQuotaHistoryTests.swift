import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct AntigravityQuotaHistoryTests {
    private let now = Date(timeIntervalSince1970: 1_789_300_000)

    @Test
    func `unknown pool cadence cannot produce a five hour pace forecast`() {
        let window = RateWindow(
            usedPercent: 82,
            windowMinutes: nil,
            resetsAt: self.now.addingTimeInterval(600),
            resetDescription: nil)
        #expect(UsagePaceText.sessionDetail(provider: .antigravity, window: window, now: self.now) == nil)
    }

    @MainActor
    @Test
    func `normal refresh records pool samples without a complete session weekly pair`() async {
        let store = UsageStorePlanUtilizationTests.makeStore()
        await store.recordPlanUtilizationHistorySample(
            provider: .antigravity, snapshot: self.poolSnapshot(), now: self.now)
        let histories = store.planUtilizationHistory(for: .antigravity)
        #expect(Set(histories.map(\.name)) == [.antigravityGemini, .antigravityClaudeGPT])
        #expect(histories.first(where: { $0.name == .antigravityGemini })?.entries.last?.usedPercent == 82)
        #expect(!histories.contains { $0.name == .session || $0.name == .weekly })
    }

    @MainActor
    @Test(arguments: [false, true])
    func `same hour decreases retain latest observation and format freshness`(hasReset: Bool) async throws {
        let store = UsageStorePlanUtilizationTests.makeStore()
        let hour = Date(timeIntervalSince1970: floor(self.now.timeIntervalSince1970 / 3600) * 3600)
        // Include a delayed older response after the replenishment to protect capture ordering too.
        for (minute, used) in [(5.0, 80.0), (20.0, 20.0), (10.0, 90.0)] {
            let capture = hour.addingTimeInterval(minute * 60)
            await store.recordPlanUtilizationHistorySample(
                provider: .antigravity,
                snapshot: UsageSnapshot(
                    primary: .init(
                        usedPercent: used,
                        windowMinutes: nil,
                        resetsAt: hasReset ? self.now : nil,
                        resetDescription: nil),
                    secondary: nil,
                    updatedAt: capture),
                now: capture)
        }
        let histories = store.planUtilizationHistory(for: .antigravity)
        let observation = try #require(histories.first { $0.name == .antigravityGemini })
        #expect(observation.entries.count == 1)
        #expect(observation.entries.last?.usedPercent == 20)
        #expect(observation.latestCapturedAt == hour.addingTimeInterval(20 * 60))
        let structured = PlanUtilizationSeriesHistory(
            name: .weekly,
            windowMinutes: 10080,
            entries: [.init(capturedAt: hour.addingTimeInterval(15 * 60), usedPercent: 30, resetsAt: nil)])
        #expect(UsageStore.antigravityHistoryUsesObservations(snapshot: nil, histories: histories + [structured]))
        let chart = PlanUtilizationHistoryChartMenuView._modelSnapshotForTesting(
            histories: histories + [structured], provider: .antigravity, snapshot: nil, referenceDate: self.now)
        #expect(chart.usedPercents == [20])
    }

    @MainActor
    @Test(arguments: ["Custom pool", ""])
    func `summary balances with unknown cadence survive parsing recording and chart selection`(cadence: String)
        async throws
    {
        let status = AntigravityStatusSnapshot(
            quotaSummary: AntigravityQuotaSummary(description: nil, groups: [
                AntigravityQuotaSummaryGroup(displayName: "Gemini", description: nil, buckets: [
                    AntigravityQuotaSummaryBucket(
                        bucketId: "gemini-custom",
                        displayName: cadence,
                        remainingFraction: 0.25,
                        resetDescription: nil,
                        disabled: false),
                ]),
                AntigravityQuotaSummaryGroup(displayName: "Claude and GPT", description: nil, buckets: [
                    AntigravityQuotaSummaryBucket(
                        bucketId: "claude-custom",
                        displayName: cadence,
                        remainingFraction: 0.5,
                        resetDescription: nil,
                        disabled: false),
                ]),
            ]),
            accountEmail: nil,
            accountPlan: nil)
        let snapshot = try status.toUsageSnapshot()
        #expect(snapshot.primary?.windowMinutes == nil)
        let store = UsageStorePlanUtilizationTests.makeStore()
        await store.recordPlanUtilizationHistorySample(provider: .antigravity, snapshot: snapshot, now: self.now)
        let histories = store.planUtilizationHistory(for: .antigravity)
        #expect(histories.first { $0.name == .antigravityGemini }?.entries.last?.usedPercent == 75)
        #expect(histories.first { $0.name == .antigravityClaudeGPT }?.entries.last?.usedPercent == 50)
        let staleStructured = PlanUtilizationSeriesHistory(
            name: .weekly,
            windowMinutes: 10080,
            entries: [.init(capturedAt: self.now.addingTimeInterval(-3600), usedPercent: 10, resetsAt: nil)])
        let chart = PlanUtilizationHistoryChartMenuView._modelSnapshotForTesting(
            histories: histories + [staleStructured],
            provider: .antigravity,
            snapshot: snapshot,
            referenceDate: self.now)
        #expect(chart.selectedSeries == "antigravityGemini:0")
        #expect(chart.usedPercents == [75])
    }

    @MainActor
    @Test
    func `adopting unscoped observations preserves latest balance over account hourly peak`() async throws {
        let store = UsageStorePlanUtilizationTests.makeStore()
        let account = ProviderTokenAccount(
            id: UUID(), label: "Fixture", token: "fixture-only", addedAt: 0, lastUsed: nil)
        let key = try #require(UsageStore._planUtilizationTokenAccountKeyForTesting(
            provider: .antigravity, account: account))
        let hour = Date(timeIntervalSince1970: floor(self.now.timeIntervalSince1970 / 3600) * 3600)
        func history(minute: Double, used: Double) -> PlanUtilizationSeriesHistory {
            .init(name: .antigravityGemini, windowMinutes: 0, entries: [
                .init(capturedAt: hour.addingTimeInterval(minute * 60), usedPercent: used, resetsAt: nil),
            ])
        }
        var buckets = PlanUtilizationHistoryBuckets()
        buckets.setHistories([history(minute: 5, used: 80)], for: key)
        buckets.setHistories([history(minute: 20, used: 20)], for: nil)
        store.planUtilizationHistory[.antigravity] = buckets
        await store.recordPlanUtilizationHistorySample(
            provider: .antigravity,
            snapshot: UsageSnapshot(
                primary: nil,
                secondary: .init(usedPercent: 10, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                updatedAt: self.now),
            account: account,
            now: self.now)
        let adopted = try #require(store.planUtilizationHistory[.antigravity]?.histories(for: key)
            .first { $0.name == .antigravityGemini })
        #expect(adopted.entries == history(minute: 20, used: 20).entries)
    }

    @Test
    func `pool observations do not require or invent a reset duration`() {
        let snapshot = self.poolSnapshot()
        let samples = UsageStore.antigravityQuotaObservationSamples(snapshot: snapshot, capturedAt: self.now)
        #expect(samples.map(\.name) == [.antigravityGemini, .antigravityClaudeGPT])
        #expect(samples.map(\.windowMinutes) == [0, 0])
        #expect(samples.map(\.entry.usedPercent) == [82, 0])
        #expect(samples.allSatisfy { $0.entry.capturedAt == self.now })
    }

    @Test
    func `pool chart ignores legacy session rows and retains real samples across gaps`() {
        let samples = UsageStore.antigravityQuotaObservationSamples(snapshot: self.poolSnapshot(), capturedAt: self.now)
        let histories = samples.map { sample in
            PlanUtilizationSeriesHistory(name: sample.name, windowMinutes: 0, entries: [sample.entry])
        } + [PlanUtilizationSeriesHistory(
            name: .session,
            windowMinutes: 300,
            entries: [.init(capturedAt: self.now.addingTimeInterval(-86400 * 7), usedPercent: 1, resetsAt: nil)])]
        let chart = PlanUtilizationHistoryChartMenuView._modelSnapshotForTesting(
            histories: histories,
            provider: .antigravity,
            snapshot: self.poolSnapshot(),
            referenceDate: self.now.addingTimeInterval(86400 * 7))
        #expect(chart.pointCount == 1)
        #expect(chart.usedPercents == [82])
        #expect(chart.selectedSeries == "antigravityGemini:0")
        #expect(chart.visibleSeries.count == 2)
        #expect(Set(chart.visibleSeries) == ["antigravityGemini:0", "antigravityClaudeGPT:0"])
        #expect(!chart.visibleSeries.contains("session:300"))
        let unavailable = PlanUtilizationHistoryChartMenuView._modelSnapshotForTesting(
            histories: histories, provider: .antigravity, snapshot: nil, referenceDate: self.now)
        #expect(Set(unavailable.visibleSeries) == ["antigravityGemini:0", "antigravityClaudeGPT:0"])
    }

    @Test(arguments: [-3600.0, 0.0, 3600.0])
    func `missing snapshot selects the newest stored format with structured ties`(observationOffset: TimeInterval) {
        let histories = [
            PlanUtilizationSeriesHistory(
                name: .antigravityGemini,
                windowMinutes: 0,
                entries: [.init(
                    capturedAt: self.now.addingTimeInterval(observationOffset), usedPercent: 82, resetsAt: nil)]),
            PlanUtilizationSeriesHistory(
                name: .session,
                windowMinutes: 300,
                entries: [.init(capturedAt: self.now, usedPercent: 20, resetsAt: nil)]),
        ]
        let chart = PlanUtilizationHistoryChartMenuView._modelSnapshotForTesting(
            histories: histories, provider: .antigravity, snapshot: nil, referenceDate: self.now)
        #expect(chart.visibleSeries == (observationOffset > 0 ? ["antigravityGemini:0"] : ["session:300"]))
    }

    @Test(arguments: ["offline", "empty", "placeholder", "nonfinite", "unknown-summary"], [false, true])
    func `quota unavailable responses preserve the freshest stored format`(source: String, newerPool: Bool) {
        let unavailable = RateWindow(
            usedPercent: source == "nonfinite" ? .nan : 0,
            windowMinutes: nil,
            resetsAt: nil,
            resetDescription: nil,
            isSyntheticPlaceholder: source == "placeholder")
        // Production offline responses have an unknown extra row; empty OAuth responses have no windows.
        let extras: [NamedRateWindow]? = switch source {
        case "offline": [.init(
                id: "antigravity-offline-conversations",
                title: "Offline · 1 conversation",
                window: unavailable,
                usageKnown: false)]
        case "unknown-summary": [.init(
                id: "antigravity-quota-summary-gemini-session",
                title: "Session",
                window: unavailable,
                usageKnown: false)]
        default: nil
        }
        let snapshot = UsageSnapshot(
            primary: ["placeholder", "nonfinite"].contains(source) ? unavailable : nil,
            secondary: nil,
            extraRateWindows: extras,
            updatedAt: self.now)
        let histories = [
            PlanUtilizationSeriesHistory(
                name: .antigravityGemini,
                windowMinutes: 0,
                entries: [.init(
                    capturedAt: self.now.addingTimeInterval(newerPool ? 3600 : -3600),
                    usedPercent: 82,
                    resetsAt: nil)]),
            PlanUtilizationSeriesHistory(
                name: .weekly,
                windowMinutes: 10080,
                entries: [.init(capturedAt: self.now, usedPercent: 20, resetsAt: nil)]),
        ]
        #expect(UsageStore.antigravityQuotaObservationSamples(snapshot: snapshot, capturedAt: self.now).isEmpty)
        let chart = PlanUtilizationHistoryChartMenuView._modelSnapshotForTesting(
            histories: histories, provider: .antigravity, snapshot: snapshot, referenceDate: self.now)
        #expect(chart.visibleSeries == (newerPool ? ["antigravityGemini:0"] : ["weekly:10080"]))
    }

    @Test
    func `quota observation histories survive disk round trip without adopting a cadence`() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let history = PlanUtilizationSeriesHistory(
            name: .antigravityGemini,
            windowMinutes: 0,
            entries: [.init(capturedAt: self.now, usedPercent: 82, resetsAt: nil)])
        let disk = PlanUtilizationHistoryStore(directoryURL: root)
        var bucket = PlanUtilizationHistoryBuckets()
        bucket.setHistories([history], for: "fixture-account")
        disk.save([UsageProvider.antigravity.instanceID: bucket])
        #expect(disk.load()[UsageProvider.antigravity.instanceID]?.histories(for: "fixture-account") == [history])
    }

    @Test
    func `structured quota summary cannot be recorded as legacy pool observations`() {
        let snapshot = UsageSnapshot(
            primary: self.poolSnapshot().primary,
            secondary: nil,
            tertiary: nil,
            extraRateWindows: [.init(
                id: "antigravity-quota-summary-gemini-session",
                title: "Session",
                window: .init(
                    usedPercent: 20,
                    windowMinutes: 300,
                    resetsAt: self.now,
                    resetDescription: nil))],
            updatedAt: self.now)
        #expect(UsageStore.antigravityQuotaObservationSamples(snapshot: snapshot, capturedAt: self.now).isEmpty)
    }

    private func poolSnapshot() -> UsageSnapshot {
        UsageSnapshot(
            primary: .init(usedPercent: 82, windowMinutes: nil, resetsAt: self.now, resetDescription: nil),
            secondary: .init(usedPercent: 0, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            tertiary: nil,
            updatedAt: self.now)
    }
}
