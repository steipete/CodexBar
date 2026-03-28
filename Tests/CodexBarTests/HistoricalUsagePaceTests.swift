import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct HistoricalUsagePaceTests {
    @Test
    func `history store reconstructs deterministic monotone curve`() async throws {
        let fileURL = Self.makeTempURL()
        let store = HistoricalUsageHistoryStore(fileURL: fileURL)
        let windowMinutes = 10080
        let duration = TimeInterval(windowMinutes) * 60
        let resetsAt = Date().addingTimeInterval(-24 * 60 * 60)
        let windowStart = resetsAt.addingTimeInterval(-duration)

        let samples: [(u: Double, used: Double)] = [
            (0.02, 3),
            (0.10, 10),
            (0.40, 40),
            (0.60, 60),
            (0.80, 80),
            (0.98, 95),
        ]
        for sample in samples {
            let sampledAt = windowStart.addingTimeInterval(sample.u * duration)
            _ = await store.recordCodexWeekly(
                window: RateWindow(
                    usedPercent: sample.used,
                    windowMinutes: windowMinutes,
                    resetsAt: resetsAt,
                    resetDescription: nil),
                sampledAt: sampledAt,
                accountKey: nil)
        }

        let dataset = await store.loadCodexDataset(accountKey: nil)
        #expect(dataset?.weeks.count == 1)
        let curve = try #require(dataset?.weeks.first?.curve)
        #expect(curve.count == CodexHistoricalDataset.gridPointCount)
        #expect(abs(curve[0]) < 0.001)
        for index in 1..<curve.count {
            #expect(curve[index] >= curve[index - 1])
        }
        // u=0.5 is index 84 in a 169-point grid.
        #expect(abs(curve[84] - 50) < 0.5)
    }

    @Test
    func `reconstruct week curve anchors at zero at window start`() async throws {
        let fileURL = Self.makeTempURL()
        let store = HistoricalUsageHistoryStore(fileURL: fileURL)
        let windowMinutes = 10080
        let duration = TimeInterval(windowMinutes) * 60
        let resetsAt = Date().addingTimeInterval(-24 * 60 * 60)
        let windowStart = resetsAt.addingTimeInterval(-duration)

        let samples: [(u: Double, used: Double)] = [
            (0.10, 12),
            (0.25, 25),
            (0.50, 50),
            (0.70, 70),
            (0.90, 90),
            (0.98, 96),
        ]
        for sample in samples {
            _ = await store.recordCodexWeekly(
                window: RateWindow(
                    usedPercent: sample.used,
                    windowMinutes: windowMinutes,
                    resetsAt: resetsAt,
                    resetDescription: nil),
                sampledAt: windowStart.addingTimeInterval(sample.u * duration),
                accountKey: nil)
        }

        let curve = try #require(await store.loadCodexDataset(accountKey: nil)?.weeks.first?.curve)
        #expect(abs(curve[0]) < 0.001)
        #expect(curve[1] >= curve[0])
    }

    @Test
    func `reconstruct week curve adds end anchor without breaking monotonicity`() async throws {
        let fileURL = Self.makeTempURL()
        let store = HistoricalUsageHistoryStore(fileURL: fileURL)
        let windowMinutes = 10080
        let duration = TimeInterval(windowMinutes) * 60
        let resetsAt = Date().addingTimeInterval(-24 * 60 * 60)
        let windowStart = resetsAt.addingTimeInterval(-duration)

        let samples: [(u: Double, used: Double)] = [
            (0.02, 2),
            (0.15, 18),
            (0.35, 40),
            (0.55, 58),
            (0.80, 82),
            (0.90, 88),
        ]
        for sample in samples {
            _ = await store.recordCodexWeekly(
                window: RateWindow(
                    usedPercent: sample.used,
                    windowMinutes: windowMinutes,
                    resetsAt: resetsAt,
                    resetDescription: nil),
                sampledAt: windowStart.addingTimeInterval(sample.u * duration),
                accountKey: nil)
        }

        let curve = try #require(await store.loadCodexDataset(accountKey: nil)?.weeks.first?.curve)
        for index in 1..<curve.count {
            #expect(curve[index] >= curve[index - 1])
        }
        let last = try #require(curve.last)
        #expect(abs(last - 88) < 1.5)
    }

    @Test
    func `history store requires start and end coverage for complete week`() async {
        let fileURL = Self.makeTempURL()
        let store = HistoricalUsageHistoryStore(fileURL: fileURL)
        let windowMinutes = 10080
        let duration = TimeInterval(windowMinutes) * 60
        let resetsAt = Date().addingTimeInterval(-24 * 60 * 60)
        let windowStart = resetsAt.addingTimeInterval(-duration)

        // Missing first-24h coverage on purpose.
        let lateOnlySamples: [(u: Double, used: Double)] = [
            (0.30, 20),
            (0.45, 35),
            (0.60, 50),
            (0.75, 65),
            (0.90, 80),
            (0.98, 92),
        ]
        for sample in lateOnlySamples {
            let sampledAt = windowStart.addingTimeInterval(sample.u * duration)
            _ = await store.recordCodexWeekly(
                window: RateWindow(
                    usedPercent: sample.used,
                    windowMinutes: windowMinutes,
                    resetsAt: resetsAt,
                    resetDescription: nil),
                sampledAt: sampledAt,
                accountKey: nil)
        }

        #expect(await store.loadCodexDataset(accountKey: nil) == nil)
    }

    @Test
    func `evaluator applies smoothed probability and hides risk below threshold`() throws {
        let now = Date(timeIntervalSince1970: 0)
        let windowMinutes = 10080
        let duration = TimeInterval(windowMinutes) * 60
        let currentResetsAt = now.addingTimeInterval(duration / 2)
        let window = RateWindow(
            usedPercent: 50,
            windowMinutes: windowMinutes,
            resetsAt: currentResetsAt,
            resetDescription: nil)

        let fiveTrueWeeks = (0..<5).map { index in
            HistoricalWeekProfile(
                resetsAt: currentResetsAt.addingTimeInterval(-duration * Double(index + 1)),
                windowMinutes: windowMinutes,
                curve: Self.linearCurve(end: 100))
        }
        let paceAllTrue = CodexHistoricalPaceEvaluator.evaluate(
            window: window,
            now: now,
            dataset: CodexHistoricalDataset(weeks: fiveTrueWeeks))
        let probabilityTrue = try #require(paceAllTrue?.runOutProbability)
        #expect(probabilityTrue > 0)
        #expect(probabilityTrue < 1)

        let fiveFalseWeeks = (0..<5).map { index in
            HistoricalWeekProfile(
                resetsAt: currentResetsAt.addingTimeInterval(-duration * Double(index + 1)),
                windowMinutes: windowMinutes,
                curve: Self.linearCurve(end: 80))
        }
        let paceAllFalse = CodexHistoricalPaceEvaluator.evaluate(
            window: window,
            now: now,
            dataset: CodexHistoricalDataset(weeks: fiveFalseWeeks))
        let probabilityFalse = try #require(paceAllFalse?.runOutProbability)
        #expect(probabilityFalse > 0)
        #expect(probabilityFalse < 1)

        let fourWeeks = Array(fiveTrueWeeks.prefix(4))
        let paceFourWeeks = CodexHistoricalPaceEvaluator.evaluate(
            window: window,
            now: now,
            dataset: CodexHistoricalDataset(weeks: fourWeeks))
        #expect(paceFourWeeks?.runOutProbability == nil)
    }

    @Test
    func `evaluator never returns negative eta with outlier week`() {
        let now = Date(timeIntervalSince1970: 0)
        let windowMinutes = 10080
        let duration = TimeInterval(windowMinutes) * 60
        let currentResetsAt = now.addingTimeInterval(duration / 2)
        let window = RateWindow(
            usedPercent: 50,
            windowMinutes: windowMinutes,
            resetsAt: currentResetsAt,
            resetDescription: nil)

        var weeks = (0..<4).map { index in
            HistoricalWeekProfile(
                resetsAt: currentResetsAt.addingTimeInterval(-duration * Double(index + 1)),
                windowMinutes: windowMinutes,
                curve: Self.linearCurve(end: 100))
        }
        weeks.append(HistoricalWeekProfile(
            resetsAt: currentResetsAt.addingTimeInterval(-duration * 5),
            windowMinutes: windowMinutes,
            curve: Self.outlierCurve()))

        let pace = CodexHistoricalPaceEvaluator.evaluate(
            window: window,
            now: now,
            dataset: CodexHistoricalDataset(weeks: weeks))

        #expect(pace != nil)
        #expect((pace?.etaSeconds ?? 0) >= 0)
    }

    @Test
    func `history store backfills from usage breakdown when history is empty`() async {
        let fileURL = Self.makeTempURL()
        let store = HistoricalUsageHistoryStore(fileURL: fileURL)
        let now = Date(timeIntervalSince1970: 1_770_000_000)
        let windowMinutes = 10080
        let resetsAt = now.addingTimeInterval(2 * 24 * 60 * 60)
        let referenceWindow = RateWindow(
            usedPercent: 50,
            windowMinutes: windowMinutes,
            resetsAt: resetsAt,
            resetDescription: nil)

        let breakdown = Self.syntheticBreakdown(endingAt: now, days: 35, dailyCredits: 10)
        let dataset = await store.backfillCodexWeeklyFromUsageBreakdown(
            breakdown,
            referenceWindow: referenceWindow,
            now: now,
            accountKey: nil)

        #expect((dataset?.weeks.count ?? 0) >= 3)
    }

    @Test
    func `history store backfill is idempotent for existing weeks`() async {
        let fileURL = Self.makeTempURL()
        let store = HistoricalUsageHistoryStore(fileURL: fileURL)
        let now = Date(timeIntervalSince1970: 1_770_000_000)
        let windowMinutes = 10080
        let resetsAt = now.addingTimeInterval(2 * 24 * 60 * 60)
        let referenceWindow = RateWindow(
            usedPercent: 50,
            windowMinutes: windowMinutes,
            resetsAt: resetsAt,
            resetDescription: nil)

        let breakdown = Self.syntheticBreakdown(endingAt: now, days: 35, dailyCredits: 10)
        let first = await store.backfillCodexWeeklyFromUsageBreakdown(
            breakdown,
            referenceWindow: referenceWindow,
            now: now,
            accountKey: nil)
        let recordsAfterFirst = (try? Self.readHistoricalRecords(from: fileURL)) ?? []
        let second = await store.backfillCodexWeeklyFromUsageBreakdown(
            breakdown,
            referenceWindow: referenceWindow,
            now: now,
            accountKey: nil)
        let recordsAfterSecond = (try? Self.readHistoricalRecords(from: fileURL)) ?? []

        #expect((first?.weeks.count ?? 0) >= 3)
        #expect(first?.weeks.count == second?.weeks.count)
        #expect(recordsAfterSecond.count == recordsAfterFirst.count)
        #expect(Self.recordDedupKeyCount(recordsAfterSecond) == recordsAfterSecond.count)
        #expect(Self.datasetCurveSignature(first) == Self.datasetCurveSignature(second))
    }

    @Test
    func `history store backfill fills incomplete existing week`() async {
        let fileURL = Self.makeTempURL()
        let store = HistoricalUsageHistoryStore(fileURL: fileURL)
        let now = Date(timeIntervalSince1970: 1_770_000_000)
        let windowMinutes = 10080
        let duration = TimeInterval(windowMinutes) * 60
        let resetsAt = now.addingTimeInterval(2 * 24 * 60 * 60)
        let referenceWindow = RateWindow(
            usedPercent: 50,
            windowMinutes: windowMinutes,
            resetsAt: resetsAt,
            resetDescription: nil)

        let incompleteReset = resetsAt.addingTimeInterval(-2 * duration)
        let incompleteStart = incompleteReset.addingTimeInterval(-duration)
        _ = await store.recordCodexWeekly(
            window: RateWindow(
                usedPercent: 42,
                windowMinutes: windowMinutes,
                resetsAt: incompleteReset,
                resetDescription: nil),
            sampledAt: incompleteStart.addingTimeInterval(duration * 0.5),
            accountKey: nil)

        let breakdown = Self.syntheticBreakdown(endingAt: now, days: 29, dailyCredits: 10)
        let dataset = await store.backfillCodexWeeklyFromUsageBreakdown(
            breakdown,
            referenceWindow: referenceWindow,
            now: now,
            accountKey: nil)

        #expect((dataset?.weeks.count ?? 0) >= 3)
    }

    @Test
    func `history store should accept does not cross window minutes regimes`() async throws {
        let fileURL = Self.makeTempURL()
        let store = HistoricalUsageHistoryStore(fileURL: fileURL)
        let sampledAt = Date(timeIntervalSince1970: 1_770_000_000)
        let resetsAt = sampledAt.addingTimeInterval(3 * 24 * 60 * 60)

        _ = await store.recordCodexWeekly(
            window: RateWindow(
                usedPercent: 20,
                windowMinutes: 10080,
                resetsAt: resetsAt,
                resetDescription: nil),
            sampledAt: sampledAt,
            accountKey: nil)
        _ = await store.recordCodexWeekly(
            window: RateWindow(
                usedPercent: 20,
                windowMinutes: 20160,
                resetsAt: resetsAt,
                resetDescription: nil),
            sampledAt: sampledAt.addingTimeInterval(60),
            accountKey: nil)

        let data = try Data(contentsOf: fileURL)
        let text = String(data: data, encoding: .utf8) ?? ""
        let lines = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        #expect(lines.count == 2)
    }

    @Test
    func `weeks with reset jitter are grouped together`() async {
        let fileURL = Self.makeTempURL()
        let store = HistoricalUsageHistoryStore(fileURL: fileURL)
        let windowMinutes = 10080
        let duration = TimeInterval(windowMinutes) * 60
        let canonicalReset = Date(timeIntervalSince1970: 1_770_000_000)
        let windowStart = canonicalReset.addingTimeInterval(-duration)

        let samples: [(u: Double, used: Double)] = [
            (0.02, 2),
            (0.10, 10),
            (0.30, 30),
            (0.50, 50),
            (0.80, 80),
            (0.98, 95),
        ]
        for (index, sample) in samples.enumerated() {
            let jitteredReset = canonicalReset.addingTimeInterval(index.isMultiple(of: 2) ? -20 : 20)
            _ = await store.recordCodexWeekly(
                window: RateWindow(
                    usedPercent: sample.used,
                    windowMinutes: windowMinutes,
                    resetsAt: jitteredReset,
                    resetDescription: nil),
                sampledAt: windowStart.addingTimeInterval(sample.u * duration),
                accountKey: nil)
        }

        let dataset = await store.loadCodexDataset(accountKey: nil)
        #expect(dataset?.weeks.count == 1)
    }

    @Test
    func `backfill matches incomplete week when reset jitter exists`() async throws {
        let fileURL = Self.makeTempURL()
        let store = HistoricalUsageHistoryStore(fileURL: fileURL)
        let now = Date(timeIntervalSince1970: 1_770_000_000)
        let windowMinutes = 10080
        let duration = TimeInterval(windowMinutes) * 60
        let currentReset = now.addingTimeInterval(2 * 24 * 60 * 60)
        let targetReset = currentReset.addingTimeInterval(-2 * duration)
        let targetStart = targetReset.addingTimeInterval(-duration)

        _ = await store.recordCodexWeekly(
            window: RateWindow(
                usedPercent: 35,
                windowMinutes: windowMinutes,
                resetsAt: targetReset.addingTimeInterval(30),
                resetDescription: nil),
            sampledAt: targetStart.addingTimeInterval(duration * 0.5),
            accountKey: nil)

        let datasetBefore = await store.loadCodexDataset(accountKey: nil)
        #expect(datasetBefore == nil)

        let referenceWindow = RateWindow(
            usedPercent: 50,
            windowMinutes: windowMinutes,
            resetsAt: currentReset,
            resetDescription: nil)
        let breakdown = Self.syntheticBreakdown(endingAt: now, days: 29, dailyCredits: 10)
        let datasetAfter = await store.backfillCodexWeeklyFromUsageBreakdown(
            breakdown,
            referenceWindow: referenceWindow,
            now: now,
            accountKey: nil)
        #expect((datasetAfter?.weeks.count ?? 0) >= 3)

        let normalizedTargetReset = Self.normalizeReset(targetReset)
        let records = try Self.readHistoricalRecords(from: fileURL)
        let matching = records.filter { $0.accountKey == nil && $0.resetsAt == normalizedTargetReset }
        #expect(matching.count > 1)
    }

    @Test
    func `backfill does not stop at three weeks when more backfillable weeks exist`() async throws {
        let fileURL = Self.makeTempURL()
        let store = HistoricalUsageHistoryStore(fileURL: fileURL)
        let now = Date(timeIntervalSince1970: 1_770_000_000)
        let windowMinutes = 10080
        let duration = TimeInterval(windowMinutes) * 60
        let currentReset = now.addingTimeInterval(2 * 24 * 60 * 60)

        // Seed 3 complete weeks.
        for weekOffset in 1...3 {
            let reset = currentReset.addingTimeInterval(-duration * Double(weekOffset))
            let start = reset.addingTimeInterval(-duration)
            let samples: [(u: Double, used: Double)] = [
                (0.02, 2), (0.10, 10), (0.30, 30), (0.50, 50), (0.80, 80), (0.98, 95),
            ]
            for sample in samples {
                _ = await store.recordCodexWeekly(
                    window: RateWindow(
                        usedPercent: sample.used,
                        windowMinutes: windowMinutes,
                        resetsAt: reset,
                        resetDescription: nil),
                    sampledAt: start.addingTimeInterval(sample.u * duration),
                    accountKey: nil)
            }
        }

        let pre = try #require(await store.loadCodexDataset(accountKey: nil))
        #expect(pre.weeks.count == 3)

        let referenceWindow = RateWindow(
            usedPercent: 50,
            windowMinutes: windowMinutes,
            resetsAt: currentReset,
            resetDescription: nil)
        let breakdown = Self.syntheticBreakdown(endingAt: now, days: 56, dailyCredits: 10)
        let post = await store.backfillCodexWeeklyFromUsageBreakdown(
            breakdown,
            referenceWindow: referenceWindow,
            now: now,
            accountKey: nil)

        #expect((post?.weeks.count ?? 0) > 3)
    }

    @Test
    func `load dataset uses only current account key`() async throws {
        let fileURL = Self.makeTempURL()
        let store = HistoricalUsageHistoryStore(fileURL: fileURL)
        let windowMinutes = 10080
        let duration = TimeInterval(windowMinutes) * 60
        let reset = Date(timeIntervalSince1970: 1_770_000_000)
        let start = reset.addingTimeInterval(-duration)
        let samples: [Double] = [0.02, 0.10, 0.30, 0.50, 0.80, 0.98]

        for u in samples {
            _ = await store.recordCodexWeekly(
                window: RateWindow(
                    usedPercent: u * 100,
                    windowMinutes: windowMinutes,
                    resetsAt: reset,
                    resetDescription: nil),
                sampledAt: start.addingTimeInterval(u * duration),
                accountKey: "acct-a")
        }
        for u in samples {
            _ = await store.recordCodexWeekly(
                window: RateWindow(
                    usedPercent: min(100, (u * 100) + 10),
                    windowMinutes: windowMinutes,
                    resetsAt: reset,
                    resetDescription: nil),
                sampledAt: start.addingTimeInterval(u * duration),
                accountKey: "acct-b")
        }

        let aDataset = try #require(await store.loadCodexDataset(accountKey: "acct-a"))
        let bDataset = try #require(await store.loadCodexDataset(accountKey: "acct-b"))
        let nilDataset = await store.loadCodexDataset(accountKey: nil)
        #expect(aDataset.weeks.count == 1)
        #expect(bDataset.weeks.count == 1)
        #expect(nilDataset == nil)
        #expect(abs(aDataset.weeks[0].curve[84] - bDataset.weeks[0].curve[84]) > 0.1)
    }

    @Test
    func `backfill filters by account key`() async throws {
        let fileURL = Self.makeTempURL()
        let store = HistoricalUsageHistoryStore(fileURL: fileURL)
        let now = Date(timeIntervalSince1970: 1_770_000_000)
        let resetsAt = now.addingTimeInterval(2 * 24 * 60 * 60)
        let referenceWindow = RateWindow(
            usedPercent: 50,
            windowMinutes: 10080,
            resetsAt: resetsAt,
            resetDescription: nil)
        let breakdown = Self.syntheticBreakdown(endingAt: now, days: 35, dailyCredits: 10)

        _ = await store.backfillCodexWeeklyFromUsageBreakdown(
            breakdown,
            referenceWindow: referenceWindow,
            now: now,
            accountKey: "acct-a")
        _ = await store.backfillCodexWeeklyFromUsageBreakdown(
            breakdown,
            referenceWindow: referenceWindow,
            now: now,
            accountKey: "acct-b")

        let records = try Self.readHistoricalRecords(from: fileURL)
        #expect(records.contains { $0.accountKey == "acct-a" })
        #expect(records.contains { $0.accountKey == "acct-b" })

        let aDataset = await store.loadCodexDataset(accountKey: "acct-a")
        let bDataset = await store.loadCodexDataset(accountKey: "acct-b")
        #expect((aDataset?.weeks.count ?? 0) >= 3)
        #expect((bDataset?.weeks.count ?? 0) >= 3)
    }

    @Test
    func `coverage tolerance allows day boundary shift without no op`() async {
        let fileURL = Self.makeTempURL()
        let store = HistoricalUsageHistoryStore(fileURL: fileURL)
        let now = Date(timeIntervalSince1970: 1_770_000_000)
        let breakdown = Self.syntheticBreakdown(endingAt: now, days: 35, dailyCredits: 10)

        let coverageStart = Self.dayStart(for: breakdown.last?.day ?? "")!
        let priorBackfillStart = coverageStart.addingTimeInterval(-10 * 60 * 60)
        let priorBackfillReset = priorBackfillStart.addingTimeInterval(7 * 24 * 60 * 60)
        let resetsAt = priorBackfillReset.addingTimeInterval(7 * 24 * 60 * 60)
        let referenceWindow = RateWindow(
            usedPercent: 50,
            windowMinutes: 10080,
            resetsAt: resetsAt,
            resetDescription: nil)

        let dataset = await store.backfillCodexWeeklyFromUsageBreakdown(
            breakdown,
            referenceWindow: referenceWindow,
            now: now,
            accountKey: nil)
        #expect((dataset?.weeks.count ?? 0) >= 1)
    }

    @Test
    func `backfill treats omitted recent zero usage days as coverage`() async {
        let fileURL = Self.makeTempURL()
        let store = HistoricalUsageHistoryStore(fileURL: fileURL)
        let now = Self.gregorianDate(year: 2026, month: 2, day: 26, hour: 20)
        let resetsAt = now.addingTimeInterval(2 * 24 * 60 * 60)
        let referenceWindow = RateWindow(
            usedPercent: 50,
            windowMinutes: 10080,
            resetsAt: resetsAt,
            resetDescription: nil)

        let breakdown = Self.syntheticBreakdown(
            endingAt: now,
            days: 35,
            dailyCredits: 10,
            overridesByDayOffset: [
                0: 0,
                1: 0,
            ])
            .filter { $0.totalCreditsUsed > 0 }

        let dataset = await store.backfillCodexWeeklyFromUsageBreakdown(
            breakdown,
            referenceWindow: referenceWindow,
            now: now,
            accountKey: nil)

        #expect((dataset?.weeks.count ?? 0) >= 3)
    }

    @Test
    func `backfill treats omitted leading zero usage days as coverage`() async {
        let fileURL = Self.makeTempURL()
        let store = HistoricalUsageHistoryStore(fileURL: fileURL)
        let now = Self.gregorianDate(year: 2026, month: 2, day: 26, hour: 20)
        let resetsAt = now.addingTimeInterval(2 * 24 * 60 * 60)
        let referenceWindow = RateWindow(
            usedPercent: 50,
            windowMinutes: 10080,
            resetsAt: resetsAt,
            resetDescription: nil)

        let breakdown = Self.syntheticBreakdown(
            endingAt: now,
            days: 35,
            dailyCredits: 10,
            overridesByDayOffset: [
                3: 0,
                4: 0,
                5: 0,
            ])
            .filter { $0.totalCreditsUsed > 0 }

        let dataset = await store.backfillCodexWeeklyFromUsageBreakdown(
            breakdown,
            referenceWindow: referenceWindow,
            now: now,
            accountKey: nil)

        #expect((dataset?.weeks.count ?? 0) >= 3)
    }

    @Test
    func `partial day credits are not undercounted at as of time`() {
        let asOf = Self.gregorianDate(year: 2026, month: 2, day: 26, hour: 12)
        let start = Self.gregorianDate(year: 2026, month: 2, day: 20, hour: 0)
        let breakdown = Self.syntheticBreakdown(
            endingAt: asOf,
            days: 35,
            dailyCredits: 1,
            overridesByDayOffset: [
                0: 20,
                7: 20,
            ])

        let credits = HistoricalUsageHistoryStore._creditsUsedForTesting(
            breakdown: breakdown,
            asOf: asOf,
            start: start,
            end: asOf)

        #expect(abs(credits - 26) < 0.001)
    }

    @Test
    func `gregorian day parsing is stable for YYYYMMDD`() {
        let parsed = HistoricalUsageHistoryStore._dayStartForTesting("2026-02-26")
        let expected = Self.gregorianDate(year: 2026, month: 2, day: 26, hour: 0)
        #expect(parsed == expected)
    }

    @MainActor
    @Test
    func `backfill skips when timestamp mismatch exceeds5 minutes`() async throws {
        let store = try Self.makeUsageStoreForBackfillTests(
            suite: "HistoricalUsagePaceTests-backfill-mismatch",
            historyFileURL: Self.makeTempURL())
        store._setCodexHistoricalDatasetForTesting(nil)

        let snapshotNow = Date(timeIntervalSince1970: 1_770_000_000)
        let weekly = RateWindow(
            usedPercent: 55,
            windowMinutes: 10080,
            resetsAt: snapshotNow.addingTimeInterval(2 * 24 * 60 * 60),
            resetDescription: nil)
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: weekly,
            tertiary: nil,
            providerCost: nil,
            updatedAt: snapshotNow,
            identity: nil)
        store._setSnapshotForTesting(snapshot, provider: .codex)

        let dashboard = OpenAIDashboardSnapshot(
            signedInEmail: nil,
            codeReviewRemainingPercent: nil,
            creditEvents: [],
            dailyBreakdown: [],
            usageBreakdown: Self.syntheticBreakdown(endingAt: snapshotNow, days: 35, dailyCredits: 10),
            creditsPurchaseURL: nil,
            primaryLimit: nil,
            secondaryLimit: nil,
            creditsRemaining: nil,
            accountPlan: nil,
            updatedAt: snapshotNow.addingTimeInterval(-10 * 60))
        store.backfillCodexHistoricalFromDashboardIfNeeded(dashboard)

        try await Task.sleep(for: .milliseconds(250))
        #expect(store.codexHistoricalDataset == nil)
    }

    @MainActor
    @Test
    func `backfill uses dashboard secondary when available`() async throws {
        let store = try Self.makeUsageStoreForBackfillTests(
            suite: "HistoricalUsagePaceTests-backfill-dashboard-secondary",
            historyFileURL: Self.makeTempURL())
        store._setCodexHistoricalDatasetForTesting(nil)

        let snapshotNow = Date(timeIntervalSince1970: 1_770_000_000)
        let staleSnapshot = UsageSnapshot(
            primary: nil,
            secondary: RateWindow(
                usedPercent: 5,
                windowMinutes: 10080,
                resetsAt: snapshotNow.addingTimeInterval(2 * 24 * 60 * 60),
                resetDescription: nil),
            tertiary: nil,
            providerCost: nil,
            updatedAt: snapshotNow.addingTimeInterval(-30 * 60),
            identity: nil)
        store._setSnapshotForTesting(staleSnapshot, provider: .codex)

        let dashboard = OpenAIDashboardSnapshot(
            signedInEmail: nil,
            codeReviewRemainingPercent: nil,
            creditEvents: [],
            dailyBreakdown: [],
            usageBreakdown: Self.syntheticBreakdown(endingAt: snapshotNow, days: 35, dailyCredits: 10),
            creditsPurchaseURL: nil,
            primaryLimit: nil,
            secondaryLimit: RateWindow(
                usedPercent: 50,
                windowMinutes: 10080,
                resetsAt: snapshotNow.addingTimeInterval(2 * 24 * 60 * 60),
                resetDescription: nil),
            creditsRemaining: nil,
            accountPlan: nil,
            updatedAt: snapshotNow)
        store.backfillCodexHistoricalFromDashboardIfNeeded(dashboard)

        for _ in 0..<40 {
            if (store.codexHistoricalDataset?.weeks.count ?? 0) >= 3 {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect((store.codexHistoricalDataset?.weeks.count ?? 0) >= 3)
    }

    @Test
    func `will last decision uses smoothed probability when risk hidden`() throws {
        let now = Date(timeIntervalSince1970: 0)
        let windowMinutes = 10080
        let duration = TimeInterval(windowMinutes) * 60
        let currentResetsAt = now.addingTimeInterval(duration / 2)
        let window = RateWindow(
            usedPercent: 50,
            windowMinutes: windowMinutes,
            resetsAt: currentResetsAt,
            resetDescription: nil)

        let weeks = (0..<4).map { index in
            HistoricalWeekProfile(
                resetsAt: currentResetsAt.addingTimeInterval(-duration * Double(index + 1)),
                windowMinutes: windowMinutes,
                curve: Self.linearCurve(end: 100))
        }
        let pace = try #require(CodexHistoricalPaceEvaluator.evaluate(
            window: window,
            now: now,
            dataset: CodexHistoricalDataset(weeks: weeks)))
        #expect(pace.runOutProbability == nil)

        let totalWeight = weeks.enumerated().reduce(0.0) { partial, element in
            let ageWeeks = currentResetsAt.timeIntervalSince(element.element.resetsAt) / duration
            return partial + exp(-ageWeeks / 3.0)
        }
        let smoothedProbability = (totalWeight + 0.5) / (totalWeight + 1.0)
        #expect(pace.willLastToReset == (smoothedProbability < 0.5))
    }

    @MainActor
    @Test
    func `usage store falls back to linear when history disabled or insufficient`() throws {
        let suite = "HistoricalUsagePaceTests-usage-store"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore(),
            codexCookieStore: InMemoryCookieHeaderStore(),
            claudeCookieStore: InMemoryCookieHeaderStore(),
            cursorCookieStore: InMemoryCookieHeaderStore(),
            opencodeCookieStore: InMemoryCookieHeaderStore(),
            factoryCookieStore: InMemoryCookieHeaderStore(),
            minimaxCookieStore: InMemoryMiniMaxCookieStore(),
            minimaxAPITokenStore: InMemoryMiniMaxAPITokenStore(),
            kimiTokenStore: InMemoryKimiTokenStore(),
            kimiK2TokenStore: InMemoryKimiK2TokenStore(),
            augmentCookieStore: InMemoryCookieHeaderStore(),
            ampCookieStore: InMemoryCookieHeaderStore(),
            copilotTokenStore: InMemoryCopilotTokenStore(),
            tokenAccountStore: InMemoryTokenAccountStore())
        settings.historicalTrackingEnabled = true

        let planHistoryStore = testPlanUtilizationHistoryStore(
            suiteName: "HistoricalUsagePaceTests-\(UUID().uuidString)")
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            historicalUsageHistoryStore: HistoricalUsageHistoryStore(fileURL: Self.makeTempURL()),
            planUtilizationHistoryStore: planHistoryStore)

        let now = Date(timeIntervalSince1970: 0)
        let window = RateWindow(
            usedPercent: 50,
            windowMinutes: 10080,
            resetsAt: now.addingTimeInterval(4 * 24 * 60 * 60),
            resetDescription: nil)

        let twoWeeksDataset = CodexHistoricalDataset(weeks: [
            HistoricalWeekProfile(
                resetsAt: now.addingTimeInterval(-7 * 24 * 60 * 60),
                windowMinutes: 10080,
                curve: Self.linearCurve(end: 100)),
            HistoricalWeekProfile(
                resetsAt: now.addingTimeInterval(-14 * 24 * 60 * 60),
                windowMinutes: 10080,
                curve: Self.linearCurve(end: 100)),
        ])
        store._setCodexHistoricalDatasetForTesting(twoWeeksDataset)

        let computed = store.weeklyPace(provider: .codex, window: window, now: now)
        let linear = UsagePace.weekly(window: window, now: now, defaultWindowMinutes: 10080)
        #expect(computed != nil)
        #expect(abs((computed?.deltaPercent ?? 0) - (linear?.deltaPercent ?? 0)) < 0.001)
    }
}
