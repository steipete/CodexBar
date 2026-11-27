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
    func `same hour decreases retain latest observation`(hasReset: Bool) async throws {
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
                        resetTime: nil,
                        resetDescription: nil,
                        disabled: false,
                        window: nil),
                ]),
                AntigravityQuotaSummaryGroup(displayName: "Claude and GPT", description: nil, buckets: [
                    AntigravityQuotaSummaryBucket(
                        bucketId: "claude-custom",
                        displayName: cadence,
                        remainingFraction: 0.5,
                        resetTime: nil,
                        resetDescription: nil,
                        disabled: false,
                        window: nil),
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

    @MainActor
    @Test(arguments: [false, true])
    func `structured summaries retain hourly peaks with or without reset metadata`(hasReset: Bool) async throws {
        let store = UsageStorePlanUtilizationTests.makeStore()
        let hour = Date(timeIntervalSince1970: floor(self.now.timeIntervalSince1970 / 3600) * 3600)
        for (minute, used) in [(5.0, 80.0), (20.0, 20.0), (10.0, 90.0)] {
            let capture = hour.addingTimeInterval(minute * 60)
            let session = RateWindow(
                usedPercent: used,
                windowMinutes: 300,
                resetsAt: hasReset ? hour.addingTimeInterval(5 * 3600) : nil,
                resetDescription: nil)
            let weekly = RateWindow(
                usedPercent: 30,
                windowMinutes: 10080,
                resetsAt: hasReset ? hour.addingTimeInterval(7 * 86400) : nil,
                resetDescription: nil)
            let snapshot = UsageSnapshot(
                primary: session,
                secondary: weekly,
                extraRateWindows: [
                    .init(id: "antigravity-quota-summary-gemini-session", title: "Session", window: session),
                    .init(id: "antigravity-quota-summary-gemini-weekly", title: "Weekly", window: weekly),
                ],
                updatedAt: capture)
            await store.recordPlanUtilizationHistorySample(provider: .antigravity, snapshot: snapshot, now: capture)
        }
        let histories = store.planUtilizationHistory(for: .antigravity)
        #expect(Set(histories.map(\.name)) == [.session, .weekly])
        let session = try #require(histories.first { $0.name == .session })
        #expect(session.entries.count == 1)
        #expect(session.entries.last?.usedPercent == 90)
        #expect(session.latestCapturedAt == hour.addingTimeInterval(10 * 60))
    }

    @MainActor
    @Test
    func `single cadence Gemini summary snapshots record their active series`() async {
        let weeklyStore = UsageStorePlanUtilizationTests.makeStore()
        let weekly = RateWindow(
            usedPercent: 25,
            windowMinutes: 10080,
            resetsAt: self.now.addingTimeInterval(5 * 86400),
            resetDescription: nil)
        let weeklySnapshot = UsageSnapshot(
            primary: weekly,
            secondary: nil,
            extraRateWindows: [
                .init(id: "antigravity-quota-summary-gemini-weekly", title: "Gemini weekly", window: weekly),
            ],
            updatedAt: self.now)
        await weeklyStore.recordPlanUtilizationHistorySample(
            provider: .antigravity,
            snapshot: weeklySnapshot,
            now: self.now)
        let weeklyHistories = weeklyStore.planUtilizationHistory(for: .antigravity)
        #expect(weeklyHistories.map(\.name) == [.weekly])
        #expect(weeklyHistories.first?.entries.last?.usedPercent == 25)

        let sessionStore = UsageStorePlanUtilizationTests.makeStore()
        let session = RateWindow(
            usedPercent: 40,
            windowMinutes: 300,
            resetsAt: self.now.addingTimeInterval(3 * 3600),
            resetDescription: nil)
        let sessionSnapshot = UsageSnapshot(
            primary: session,
            secondary: nil,
            extraRateWindows: [
                .init(id: "antigravity-quota-summary-gemini-5h", title: "Gemini 5-hour", window: session),
            ],
            updatedAt: self.now)
        await sessionStore.recordPlanUtilizationHistorySample(
            provider: .antigravity,
            snapshot: sessionSnapshot,
            now: self.now)
        let sessionHistories = sessionStore.planUtilizationHistory(for: .antigravity)
        #expect(sessionHistories.map(\.name) == [.session])
        #expect(sessionHistories.first?.entries.last?.usedPercent == 40)
    }

    @MainActor
    @Test
    func `canonical weekly history is preserved when first session bucket arrives`() async throws {
        let store = UsageStorePlanUtilizationTests.makeStore()
        let firstCapture = self.now
        let secondCapture = self.now.addingTimeInterval(2 * 3600)
        let weeklyReset = self.now.addingTimeInterval(5 * 86400)
        let sessionReset = secondCapture.addingTimeInterval(5 * 3600)

        let weeklyOnly = UsageSnapshot(
            primary: RateWindow(usedPercent: 22, windowMinutes: 10080, resetsAt: weeklyReset, resetDescription: nil),
            secondary: nil,
            extraRateWindows: [
                .init(
                    id: "antigravity-quota-summary-gemini-weekly",
                    title: "Gemini weekly",
                    window: RateWindow(
                        usedPercent: 22,
                        windowMinutes: 10080,
                        resetsAt: weeklyReset,
                        resetDescription: nil)),
            ],
            updatedAt: firstCapture)
        await store.recordPlanUtilizationHistorySample(
            provider: .antigravity,
            snapshot: weeklyOnly,
            now: firstCapture)

        let withSession = UsageSnapshot(
            primary: RateWindow(usedPercent: 18, windowMinutes: 300, resetsAt: sessionReset, resetDescription: nil),
            secondary: RateWindow(usedPercent: 31, windowMinutes: 10080, resetsAt: weeklyReset, resetDescription: nil),
            extraRateWindows: [
                .init(
                    id: "antigravity-quota-summary-gemini-5h",
                    title: "Gemini 5-hour",
                    window: RateWindow(
                        usedPercent: 18,
                        windowMinutes: 300,
                        resetsAt: sessionReset,
                        resetDescription: nil)),
                .init(
                    id: "antigravity-quota-summary-gemini-weekly",
                    title: "Gemini weekly",
                    window: RateWindow(
                        usedPercent: 31,
                        windowMinutes: 10080,
                        resetsAt: weeklyReset,
                        resetDescription: nil)),
            ],
            updatedAt: secondCapture)
        let account = ProviderTokenAccount(
            id: UUID(), label: "Canonical", token: "canonical-token", addedAt: 0, lastUsed: nil)
        await store.recordPlanUtilizationHistorySample(
            provider: .antigravity,
            snapshot: withSession,
            account: account,
            now: secondCapture)

        let histories = store.planUtilizationHistory(for: .antigravity)
        let weekly = try #require(histories.first { $0.name == .weekly })
        let session = try #require(histories.first { $0.name == .session })
        #expect(weekly.entries.map(\.usedPercent) == [22, 31])
        #expect(session.entries.map(\.usedPercent) == [18])
    }

    @MainActor
    @Test
    func `legacy unmarked weekly history is still dropped when first session bucket arrives`() async throws {
        let store = UsageStorePlanUtilizationTests.makeStore()
        let firstCapture = self.now
        let secondCapture = self.now.addingTimeInterval(2 * 3600)
        let weeklyReset = self.now.addingTimeInterval(5 * 86400)
        let sessionReset = secondCapture.addingTimeInterval(5 * 3600)

        var legacyBuckets = PlanUtilizationHistoryBuckets()
        legacyBuckets.setHistories([
            PlanUtilizationSeriesHistory(
                name: .weekly,
                windowMinutes: 10080,
                entries: [.init(capturedAt: firstCapture, usedPercent: 88, resetsAt: weeklyReset)]),
        ], for: nil)
        store.planUtilizationHistory[.antigravity] = legacyBuckets

        let withSession = UsageSnapshot(
            primary: RateWindow(usedPercent: 14, windowMinutes: 300, resetsAt: sessionReset, resetDescription: nil),
            secondary: RateWindow(usedPercent: 25, windowMinutes: 10080, resetsAt: weeklyReset, resetDescription: nil),
            extraRateWindows: [
                .init(
                    id: "antigravity-quota-summary-gemini-5h",
                    title: "Gemini 5-hour",
                    window: RateWindow(
                        usedPercent: 14,
                        windowMinutes: 300,
                        resetsAt: sessionReset,
                        resetDescription: nil)),
                .init(
                    id: "antigravity-quota-summary-gemini-weekly",
                    title: "Gemini weekly",
                    window: RateWindow(
                        usedPercent: 25,
                        windowMinutes: 10080,
                        resetsAt: weeklyReset,
                        resetDescription: nil)),
            ],
            updatedAt: secondCapture)
        await store.recordPlanUtilizationHistorySample(
            provider: .antigravity,
            snapshot: withSession,
            now: secondCapture)

        let histories = store.planUtilizationHistory(for: .antigravity)
        let weekly = try #require(histories.first { $0.name == .weekly })
        let session = try #require(histories.first { $0.name == .session })
        #expect(weekly.entries.map(\.usedPercent) == [25])
        #expect(session.entries.map(\.usedPercent) == [14])
    }

    @MainActor
    @Test
    func `four lane summary snapshot records Gemini and Claude GPT session and weekly series`() async {
        let store = UsageStorePlanUtilizationTests.makeStore()
        let geminiSession = RateWindow(
            usedPercent: 15,
            windowMinutes: 300,
            resetsAt: self.now.addingTimeInterval(4 * 3600),
            resetDescription: nil)
        let geminiWeekly = RateWindow(
            usedPercent: 30,
            windowMinutes: 10080,
            resetsAt: self.now.addingTimeInterval(5 * 86400),
            resetDescription: nil)
        let claudeSession = RateWindow(
            usedPercent: 55,
            windowMinutes: 300,
            resetsAt: self.now.addingTimeInterval(2 * 3600),
            resetDescription: nil)
        let claudeWeekly = RateWindow(
            usedPercent: 70,
            windowMinutes: 10080,
            resetsAt: self.now.addingTimeInterval(6 * 86400),
            resetDescription: nil)
        let snapshot = UsageSnapshot(
            primary: geminiWeekly,
            secondary: claudeWeekly,
            extraRateWindows: [
                .init(id: "antigravity-quota-summary-gemini-5h", title: "Gemini 5-hour", window: geminiSession),
                .init(id: "antigravity-quota-summary-gemini-weekly", title: "Gemini weekly", window: geminiWeekly),
                .init(id: "antigravity-quota-summary-3p-5h", title: "Claude/GPT 5-hour", window: claudeSession),
                .init(id: "antigravity-quota-summary-3p-weekly", title: "Claude/GPT weekly", window: claudeWeekly),
            ],
            updatedAt: self.now)
        await store.recordPlanUtilizationHistorySample(provider: .antigravity, snapshot: snapshot, now: self.now)

        let histories = store.planUtilizationHistory(for: .antigravity)
        #expect(Set(histories.map(\.name)) == [
            .session,
            .weekly,
            .antigravityClaudeGPTSession,
            .antigravityClaudeGPTWeekly,
        ])
        #expect(histories.first { $0.name == .antigravityClaudeGPTSession }?.entries.last?.usedPercent == 55)
        #expect(histories.first { $0.name == .antigravityClaudeGPTWeekly }?.entries.last?.usedPercent == 70)
    }

    @MainActor
    @Test
    func `idle Gemini with active Claude GPT maps all four series while Argon alone stays off Gemini keys`() async {
        let idleGeminiSnapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            extraRateWindows: [
                .init(
                    id: "antigravity-quota-summary-gemini-5h",
                    title: "Gemini 5-hour",
                    window: .init(
                        usedPercent: 0,
                        windowMinutes: 300,
                        resetsAt: self.now.addingTimeInterval(4 * 3600),
                        resetDescription: nil)),
                .init(
                    id: "antigravity-quota-summary-gemini-weekly",
                    title: "Gemini weekly",
                    window: .init(
                        usedPercent: 0,
                        windowMinutes: 10080,
                        resetsAt: self.now.addingTimeInterval(5 * 86400),
                        resetDescription: nil)),
                .init(
                    id: "antigravity-quota-summary-3p-5h",
                    title: "Claude/GPT 5-hour",
                    window: .init(
                        usedPercent: 40,
                        windowMinutes: 300,
                        resetsAt: self.now.addingTimeInterval(2 * 3600),
                        resetDescription: nil)),
                .init(
                    id: "antigravity-quota-summary-3p-weekly",
                    title: "Claude/GPT weekly",
                    window: .init(
                        usedPercent: 55,
                        windowMinutes: 10080,
                        resetsAt: self.now.addingTimeInterval(6 * 86400),
                        resetDescription: nil)),
            ],
            updatedAt: self.now)

        let idleGeminiSeries = UsageStore.antigravityStructuredSeriesWindows(snapshot: idleGeminiSnapshot)
        #expect(Set(idleGeminiSeries.map(\.name)) == [
            .session,
            .weekly,
            .antigravityClaudeGPTSession,
            .antigravityClaudeGPTWeekly,
        ])
        #expect(idleGeminiSeries.first { $0.name == .session }?.window.usedPercent == 0)
        #expect(idleGeminiSeries.first { $0.name == .antigravityClaudeGPTSession }?.window.usedPercent == 40)

        let store = UsageStorePlanUtilizationTests.makeStore()
        await store.recordPlanUtilizationHistorySample(
            provider: .antigravity, snapshot: idleGeminiSnapshot, now: self.now)
        #expect(Set(store.planUtilizationHistory(for: .antigravity).map(\.name)) == [
            .session,
            .weekly,
            .antigravityClaudeGPTSession,
            .antigravityClaudeGPTWeekly,
        ])

        let customSnapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            extraRateWindows: [
                .init(
                    id: "antigravity-quota-summary-argon-5h",
                    title: "Argon 5-hour",
                    window: .init(usedPercent: 18, windowMinutes: 300, resetsAt: nil, resetDescription: nil)),
                .init(
                    id: "antigravity-quota-summary-argon-weekly",
                    title: "Argon weekly",
                    window: .init(usedPercent: 32, windowMinutes: 10080, resetsAt: nil, resetDescription: nil)),
                .init(
                    id: "antigravity-quota-summary-3p-5h",
                    title: "Claude/GPT 5-hour",
                    window: .init(usedPercent: 44, windowMinutes: 300, resetsAt: nil, resetDescription: nil)),
                .init(
                    id: "antigravity-quota-summary-3p-weekly",
                    title: "Claude/GPT weekly",
                    window: .init(usedPercent: 61, windowMinutes: 10080, resetsAt: nil, resetDescription: nil)),
            ],
            updatedAt: self.now)

        let customSeries = UsageStore.antigravityStructuredSeriesWindows(snapshot: customSnapshot)
        #expect(Set(customSeries.map(\.name)) == [
            .antigravityClaudeGPTSession,
            .antigravityClaudeGPTWeekly,
        ])
        #expect(customSeries.first { $0.name == .antigravityClaudeGPTSession }?.window.usedPercent == 44)
        #expect(customSeries.first { $0.name == .antigravityClaudeGPTWeekly }?.window.usedPercent == 61)
    }

    @MainActor
    @Test
    func `higher usage Argon buckets do not overwrite canonical Gemini session or weekly history`() async throws {
        let geminiSessionReset = self.now.addingTimeInterval(4 * 3600)
        let geminiWeeklyReset = self.now.addingTimeInterval(5 * 86400)
        let argonSessionReset = self.now.addingTimeInterval(2 * 3600)
        let argonWeeklyReset = self.now.addingTimeInterval(2 * 86400)

        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            extraRateWindows: [
                .init(
                    id: "antigravity-quota-summary-gemini-5h",
                    title: "Gemini 5-hour",
                    window: .init(
                        usedPercent: 15,
                        windowMinutes: 300,
                        resetsAt: geminiSessionReset,
                        resetDescription: nil)),
                .init(
                    id: "antigravity-quota-summary-gemini-weekly",
                    title: "Gemini weekly",
                    window: .init(
                        usedPercent: 25,
                        windowMinutes: 10080,
                        resetsAt: geminiWeeklyReset,
                        resetDescription: nil)),
                .init(
                    id: "antigravity-quota-summary-gemini-argon-5h",
                    title: "Gemini Argon 5-hour",
                    window: .init(
                        usedPercent: 85,
                        windowMinutes: 300,
                        resetsAt: argonSessionReset,
                        resetDescription: nil)),
                .init(
                    id: "antigravity-quota-summary-gemini-argon-weekly",
                    title: "Gemini Argon weekly",
                    window: .init(
                        usedPercent: 95,
                        windowMinutes: 10080,
                        resetsAt: argonWeeklyReset,
                        resetDescription: nil)),
                .init(
                    id: "antigravity-quota-summary-argon-5h",
                    title: "Argon 5-hour",
                    window: .init(
                        usedPercent: 90,
                        windowMinutes: 300,
                        resetsAt: argonSessionReset,
                        resetDescription: nil)),
                .init(
                    id: "antigravity-quota-summary-argon-weekly",
                    title: "Argon weekly",
                    window: .init(
                        usedPercent: 99,
                        windowMinutes: 10080,
                        resetsAt: argonWeeklyReset,
                        resetDescription: nil)),
            ],
            updatedAt: self.now)

        let series = UsageStore.antigravityStructuredSeriesWindows(snapshot: snapshot)
        #expect(Set(series.map(\.name)) == [.session, .weekly])
        let sessionWindow = try #require(series.first { $0.name == .session }?.window)
        let weeklyWindow = try #require(series.first { $0.name == .weekly }?.window)
        #expect(sessionWindow.usedPercent == 15)
        #expect(sessionWindow.resetsAt == geminiSessionReset)
        #expect(weeklyWindow.usedPercent == 25)
        #expect(weeklyWindow.resetsAt == geminiWeeklyReset)

        let store = UsageStorePlanUtilizationTests.makeStore()
        await store.recordPlanUtilizationHistorySample(provider: .antigravity, snapshot: snapshot, now: self.now)
        let histories = store.planUtilizationHistory(for: .antigravity)
        let sessionEntry = try #require(histories.first { $0.name == .session }?.entries.last)
        let weeklyEntry = try #require(histories.first { $0.name == .weekly }?.entries.last)
        #expect(sessionEntry.usedPercent == 15)
        #expect(sessionEntry.resetsAt == geminiSessionReset)
        #expect(weeklyEntry.usedPercent == 25)
        #expect(weeklyEntry.resetsAt == geminiWeeklyReset)
    }

    private func poolSnapshot() -> UsageSnapshot {
        UsageSnapshot(
            primary: .init(usedPercent: 82, windowMinutes: nil, resetsAt: self.now, resetDescription: nil),
            secondary: .init(usedPercent: 0, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            tertiary: nil,
            updatedAt: self.now)
    }
}
