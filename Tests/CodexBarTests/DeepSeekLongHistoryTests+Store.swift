import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore
@testable import CodexBarWidget

@MainActor
extension DeepSeekLongHistoryTests {
    // MARK: - UsageStore lifecycle, concurrency guards, minute ticks, and widget save budget

    @Test
    func `wide history tolerates minute ticks, replaces head without double counting, and saves widget at most twice`()
        async throws
    {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-06-15T12:00:00Z"))
        let utc = try Self.calendar("UTC")
        let plan = DeepSeekHistoryPlan.make(period: .rolling(days: 90), now: now, calendar: utc)
        let gate = DeepSeekTestChunkGate()
        let widgetCounter = DeepSeekTestCounterBox()

        let store = self.makeStore(period: .rolling(days: 90), timeZoneIdentifier: "UTC")
        defer { store.stopSharedSpendDashboardPublication() }
        store._test_deepseekNowProvider = { now }
        store._test_widgetSnapshotSaveOverride = { _ in
            await widgetCounter.increment()
        }

        let headFoldV1 = Self.makeFold(window: plan.chunks[0], day: plan.anchorDayKey, tokens: 100, cost: 1.0, req: 2)
        let headFoldV2 = Self.makeFold(window: plan.chunks[0], day: plan.anchorDayKey, tokens: 150, cost: 1.5, req: 3)
        let chunk1Fold = Self.makeChunkFold(plan.chunks[1], tokens: 200, cost: 2.0, req: 4)
        let chunk2Fold = Self.makeChunkFold(plan.chunks[2], tokens: 300, cost: 3.0, req: 6)

        let olderFetchCounter = DeepSeekTestCounterBox()
        let executedOnMainThread = DeepSeekTestFlagBox(false)
        let makeOutcome: (Double, Date, DeepSeekChunkFoldResult) -> ProviderFetchOutcome = { balance, at, headFold in
            Self.makeWideOutcome(balance: balance, updatedAt: at, plan: plan, recentFold: headFold) { window in
                if Self.isExecutingOnMainThread() {
                    await executedOnMainThread.set(true)
                }
                await olderFetchCounter.increment()
                await gate.waitForRelease(window: window)
                return window == plan.chunks[1] ? chunk1Fold : chunk2Fold
            }
        }

        // 1. Initial cold load publishes recent 30/90 partial and launches 1 wide task.
        store._test_providerFetchOutcomeOverride = { _ in makeOutcome(10.0, now, headFoldV1) }

        await store.refreshProvider(.deepseek)
        await gate.waitUntilPaused(window: plan.chunks[1])
        #expect(store.snapshots[.deepseek]?.costUsage?.historyLabel == "Last 30 of 90 days")
        #expect(await olderFetchCounter.value == 1)

        // 2. Routine minute tick arrives while wide backfill is paused on chunk 1.
        store._test_providerFetchOutcomeOverride = { _ in
            makeOutcome(9.5, now.addingTimeInterval(60), headFoldV2)
        }
        await store.refreshProvider(.deepseek)
        // Fresh balance is immediately visible and active wide job was NOT cancelled or duplicated.
        #expect(store.snapshots[.deepseek]?.primary?.resetDescription?.contains("$9.50") == true)
        #expect(await olderFetchCounter.value == 1)

        // Release both older chunks and wait for completion.
        await gate.releaseAll()
        await store.deepseekHistoryTask?.value
        await store.deepseekHeadProjectionTask?.value
        await store.widgetSnapshotPersistTask?.value

        // Final snapshot combines latest balance ($9.50) + replaced head (150/$1.50, not double-counted) + older
        // chunks.
        let finalSnapshot = try #require(store.snapshots[.deepseek])
        let finalCost = try #require(finalSnapshot.costUsage)
        #expect(finalSnapshot.primary?.resetDescription?.contains("$9.50") == true)
        #expect(finalCost.last30DaysTokens == 650) // 150 + 200 + 300
        #expect(finalCost.last30DaysCostUSD == 6.5) // 1.5 + 2.0 + 3.0
        #expect(finalCost.last30DaysRequests == 13) // 3 + 4 + 6
        #expect(finalCost.historyDays == 90)
        #expect(finalCost.historyScanIsPartial == false)
        #expect(await olderFetchCounter.value == 2) // exactly 2 older chunks, never duplicated
        #expect(await executedOnMainThread.value == false) // decode/fold executes off the main actor
        #expect(await widgetCounter.value == 1) // single final widget save from wide completion, zero per-page saves!

        // 3. Routine minute tick AFTER completion refreshes head only; zero older chunk fetches.
        let headFoldV3 = Self.makeFold(window: plan.chunks[0], day: plan.anchorDayKey, tokens: 175, cost: 1.75, req: 5)
        store._test_providerFetchOutcomeOverride = { _ in
            makeOutcome(9.25, now.addingTimeInterval(120), headFoldV3)
        }
        await store.refreshProvider(.deepseek)
        await store.deepseekHeadProjectionTask?.value
        #expect(await olderFetchCounter.value == 2) // still 2!
        #expect(store.snapshots[.deepseek]?.costUsage?.last30DaysTokens == 675) // 175 + 200 + 300
        #expect(store.snapshots[.deepseek]?.costUsage?.last30DaysCostUSD == 6.75) // 1.75 + 2.0 + 3.0
    }

    @Test(arguments: [
        "profileSwitch",
        "periodNarrowing90To7",
        "optionalUsageOff",
        "midnightRollover",
        "offsetChange",
    ])
    func `delayed late wide result is rejected after scope invalidation`(scenario: String) async throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-06-15T23:55:00Z"))
        let utc = try Self.calendar("UTC")
        let plan = DeepSeekHistoryPlan.make(period: .rolling(days: 90), now: now, calendar: utc)
        let gate = DeepSeekTestChunkGate()
        let clock = DeepSeekTestClockBox(now)

        let store = self.makeStore(period: .rolling(days: 90), timeZoneIdentifier: "UTC")
        defer { store.stopSharedSpendDashboardPublication() }
        store._test_deepseekNowProvider = { clock.current }

        let headFold = Self.makeFold(window: plan.chunks[0], day: plan.anchorDayKey, tokens: 100, cost: 1.0, req: 2)
        let staleOlderFold = Self.makeChunkFold(plan.chunks[1], tokens: 9999, cost: 99.0, req: 99)

        store._test_providerFetchOutcomeOverride = { _ in
            Self.makeWideOutcome(updatedAt: now, plan: plan, recentFold: headFold) { window in
                // Non-cooperative transport ignores cancellation and resolves late after release.
                await gate.waitForReleaseIgnoringCancellation(window: window)
                return staleOlderFold
            }
        }

        await store.refreshProvider(.deepseek)
        await gate.waitUntilPaused(window: plan.chunks[1])
        let activeTask = store.deepseekHistoryTask

        switch scenario {
        case "profileSwitch":
            store.beginDeepSeekProfileTransition()
        case "periodNarrowing90To7":
            store.settings.costReportingPeriod = .rolling(days: 7)
        case "optionalUsageOff":
            store.settings.showOptionalCreditsAndExtraUsage = false
        case "midnightRollover":
            clock.set(now.addingTimeInterval(600)) // 2026-06-16 00:05:00Z
        case "offsetChange":
            store.settings.costUsageBucketTimeZoneIdentifier = "Asia/Tokyo"
        default:
            Issue.record("Unexpected scenario \(scenario)")
        }

        await gate.releaseAll()
        await activeTask?.value

        // Exact surviving snapshot, slot retirement, and scenario-specific owner/settings invariants.
        let survivingSnapshot = try #require(store.snapshots[.deepseek])
        let survivingCost = try #require(survivingSnapshot.costUsage)
        #expect(survivingSnapshot.updatedAt == now)
        #expect(survivingSnapshot.primary?.resetDescription?.contains("$10.00") == true)
        #expect(survivingCost.last30DaysTokens == 100 && survivingCost.last30DaysCostUSD == 1.0)
        #expect(survivingCost.last30DaysRequests == 2 && survivingCost.historyLabel == "Last 30 of 90 days")
        #expect(survivingCost.historyScanIsPartial == true)
        #expect(store.deepseekHistoryTask == nil && store.deepseekHistoryState?.activeScope == nil)
        #expect(store.deepseekHistoryState?.completedScope == nil)
        #expect(store.deepseekHistoryState?.chunksByWindow[plan.chunks[1]] == nil)
        switch scenario {
        case "profileSwitch":
            #expect(store.deepseekProfileTransition != nil && store.deepseekHistoryState == nil)
            #expect(store.presentationSnapshot(for: .deepseek)?.costUsage == nil)
        case "periodNarrowing90To7":
            #expect(store.settings.costReportingPeriod == .rolling(days: 7))
            #expect(store.deepseekHistoryState?.owner.profileID == "chrome:Default")
        case "optionalUsageOff":
            #expect(store.settings.showOptionalCreditsAndExtraUsage == false)
            #expect(store.deepseekHistoryState?.owner.profileID == "chrome:Default")
        case "midnightRollover":
            #expect(clock.current == now.addingTimeInterval(600))
            #expect(store.deepseekHistoryState?.owner.profileID == "chrome:Default")
        case "offsetChange":
            #expect(store.settings.costUsageBucketTimeZoneIdentifier == "Asia/Tokyo")
            #expect(store.deepseekHistoryState?.owner.profileID == "chrome:Default")
        default:
            Issue.record("Unexpected scenario \(scenario)")
        }
    }

    @Test
    func `midnight rollover publishes fresh day-2 recent metrics immediately and coalesces one wide backfill`()
        async throws
    {
        let iso = ISO8601DateFormatter()
        let day1 = try #require(iso.date(from: "2026-06-15T23:55:00Z"))
        let day2 = try #require(iso.date(from: "2026-06-16T00:05:00Z"))
        let utc = try Self.calendar("UTC")
        let plan1 = DeepSeekHistoryPlan.make(period: .rolling(days: 90), now: day1, calendar: utc)
        let plan2 = DeepSeekHistoryPlan.make(period: .rolling(days: 90), now: day2, calendar: utc)
        let clock = DeepSeekTestClockBox(day1)
        let day2Gate = DeepSeekTestChunkGate()
        let day2FetchCount = DeepSeekTestCounterBox()

        let store = self.makeStore(period: .rolling(days: 90), timeZoneIdentifier: "UTC")
        defer { store.stopSharedSpendDashboardPublication() }
        store._test_deepseekNowProvider = { clock.current }

        let d1Head = Self.makeFold(window: plan1.chunks[0], day: plan1.anchorDayKey, tokens: 100, cost: 1.0, req: 1)
        let d1Mid = Self.makeChunkFold(plan1.chunks[1], tokens: 200, cost: 2.0, req: 2)
        let d1Old = Self.makeChunkFold(plan1.chunks[2], tokens: 300, cost: 3.0, req: 3)

        store._test_providerFetchOutcomeOverride = { _ in
            Self.makeWideOutcome(updatedAt: day1, plan: plan1, recentFold: d1Head) { window in
                window == plan1.chunks[1] ? d1Mid : d1Old
            }
        }
        await store.refreshProvider(.deepseek)
        await store.deepseekHistoryTask?.value
        let day1Cost = try #require(store.snapshots[.deepseek]?.costUsage)
        #expect(day1Cost.updatedAt == day1 && day1Cost.last30DaysTokens == 600 && day1Cost.last30DaysCostUSD == 6.0)
        #expect(day1Cost.sessionTokens == 100 && day1Cost.sessionCostUSD == 1.0 && day1Cost.sessionRequests == 1)

        // Advance past midnight; fresh day-2 recent data publishes immediately with honest partial coverage,
        // and the coalesced rollover worker reuses day 1's complete 30-day chunk instead of refetching it.
        clock.set(day2)
        let adaptedPlan2 = plan2.adaptingToReusableWindows(Set(plan1.chunks))
        #expect(adaptedPlan2.chunks.count == 4 && adaptedPlan2.chunks[2] == plan1.chunks[1])
        let d2Head = Self.makeFold(window: plan2.chunks[0], day: plan2.anchorDayKey, tokens: 50, cost: 0.5, req: 7)
        let d2Bridge = Self.makeChunkFold(adaptedPlan2.chunks[1], tokens: 40, cost: 0.4, req: 1)
        let d2Tail = Self.makeChunkFold(adaptedPlan2.chunks[3], tokens: 210, cost: 2.1, req: 2)

        store._test_providerFetchOutcomeOverride = { _ in
            Self.makeWideOutcome(balance: 8.0, updatedAt: day2, plan: plan2, recentFold: d2Head) { window in
                #expect(window != plan1.chunks[1])
                await day2FetchCount.increment()
                await day2Gate.waitForRelease(window: window)
                return window == adaptedPlan2.chunks[1] ? d2Bridge : d2Tail
            }
        }

        await store.refreshProvider(.deepseek)
        await day2Gate.waitUntilPaused(window: adaptedPlan2.chunks[1])

        let pausedSnapshot = try #require(store.snapshots[.deepseek])
        let pausedCost = try #require(pausedSnapshot.costUsage)
        #expect(pausedSnapshot.primary?.resetDescription?.contains("$8.00") == true)
        #expect(pausedSnapshot.updatedAt == day2 && pausedCost.updatedAt == day2)
        #expect(pausedCost.sessionTokens == 50 && pausedCost.sessionCostUSD == 0.5 && pausedCost.sessionRequests == 7)
        #expect(pausedSnapshot.detailRow(label: "Today")?.value == "$0.5000 · 50 tokens")
        #expect(pausedCost.historyLabel == "Last 30 of 90 days" && pausedCost.historyScanIsPartial == true)
        #expect(pausedSnapshot.detailRow(label: "Last 30 of 90 days") != nil)
        #expect(pausedCost.coveredDayIntervals?.last?.endDay == "2026-06-16")
        #expect(store.deepseekHistoryState?.completedScope == nil)

        // Second day-2 tick coalesces into the single active rollover backfill without restoring day 1.
        await store.refreshProvider(.deepseek)
        #expect(await day2FetchCount.value == 1)
        #expect(store.snapshots[.deepseek]?.costUsage?.sessionRequests == 7)
        #expect(store.snapshots[.deepseek]?.detailRow(label: "Today")?.value == "$0.5000 · 50 tokens")

        await day2Gate.releaseAll()
        await store.deepseekHistoryTask?.value

        let finalSnapshot = try #require(store.snapshots[.deepseek])
        let finalCost = try #require(finalSnapshot.costUsage)
        #expect(await day2FetchCount.value == 2)
        #expect(finalCost.updatedAt == day2 && finalCost.historyScanIsPartial == false)
        #expect(finalCost.last30DaysTokens == 500 && finalCost.last30DaysCostUSD == 5.0)
        #expect(finalCost.last30DaysRequests == 12 && finalCost.coveredDayIntervals?.last?.endDay == "2026-06-16")
        #expect(finalCost.sessionTokens == 50 && finalCost.sessionCostUSD == 0.5 && finalCost.sessionRequests == 7)
        #expect(finalSnapshot.detailRow(label: "Today")?.value == "$0.5000 · 50 tokens")
    }

    @Test
    func `explicit reload retries missing middle page while routine ticks do not, and 90 to 7 prunes old chunks`()
        async throws
    {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-06-15T12:00:00Z"))
        let utc = try Self.calendar("UTC")
        let plan90 = DeepSeekHistoryPlan.make(period: .rolling(days: 90), now: now, calendar: utc)
        let plan7 = DeepSeekHistoryPlan.make(period: .rolling(days: 7), now: now, calendar: utc)

        let store = self.makeStore(period: .rolling(days: 90), timeZoneIdentifier: "UTC")
        defer { store.stopSharedSpendDashboardPublication() }
        store._test_deepseekNowProvider = { now }

        let headFold = Self.makeFold(window: plan90.chunks[0], day: plan90.anchorDayKey, tokens: 100, cost: 1.0, req: 1)
        let midFold = Self.makeChunkFold(plan90.chunks[1], tokens: 200, cost: 2.0, req: 2)
        let oldFold = Self.makeChunkFold(plan90.chunks[2], tokens: 300, cost: 3.0, req: 3)

        let shouldFailMiddle = DeepSeekTestFlagBox(true)
        let fetchCounts = DeepSeekTestWindowCounterBox()
        store._test_providerFetchOutcomeOverride = { _ in
            Self.makeWideOutcome(updatedAt: now, plan: plan90, recentFold: headFold) { window in
                await fetchCounts.increment(window)
                if window == plan90.chunks[1] {
                    if await shouldFailMiddle.value {
                        throw DeepSeekUsageError.apiError("HTTP 503")
                    }
                    return midFold
                }
                return oldFold
            }
        }

        // Cold load fails middle chunk -> 60/90 partial.
        await ProviderInteractionContext.$current.withValue(.background) {
            await store.refreshProvider(.deepseek)
        }
        await store.deepseekHistoryTask?.value
        #expect(store.snapshots[.deepseek]?.costUsage?.historyLabel == "Last 60 of 90 days")
        #expect(await fetchCounts.count(plan90.chunks[1]) == 1)
        #expect(await fetchCounts.count(plan90.chunks[2]) == 1)

        // Routine background tick must NOT retry the missing middle page.
        await shouldFailMiddle.set(false)
        await ProviderInteractionContext.$current.withValue(.background) {
            await store.refreshProvider(.deepseek)
        }
        await store.deepseekHistoryTask?.value
        #expect(await fetchCounts.count(plan90.chunks[1]) == 1)
        #expect(await fetchCounts.count(plan90.chunks[2]) == 1)
        #expect(store.snapshots[.deepseek]?.costUsage?.historyLabel == "Last 60 of 90 days")

        // Explicit user-initiated reload retries ONLY the missing middle page and reuses chunk 2.
        await ProviderInteractionContext.$current.withValue(.userInitiated) {
            await store.refreshProvider(.deepseek)
        }
        await store.deepseekHistoryTask?.value
        #expect(await fetchCounts.count(plan90.chunks[1]) == 2)
        #expect(await fetchCounts.count(plan90.chunks[2]) == 1) // reused!
        #expect(store.snapshots[.deepseek]?.costUsage?.historyScanIsPartial == false)
        #expect(store.snapshots[.deepseek]?.costUsage?.last30DaysCostUSD == 6.0)

        // Switching 90d -> 7d replaces with exact 7d summary and releases older chunks from state.
        store.settings.costReportingPeriod = .rolling(days: 7)
        let fold7 = DeepSeekChunkFoldResult(
            window: plan7.chunks[0],
            dayTokens: [plan7.anchorDayKey: 40],
            dayModelRequests: [plan7.anchorDayKey: 1],
            dayFunctionRequests: [:],
            categoryTotals: [.responseToken: 40],
            modelTokens: ["deepseek-reasoner": 40],
            apiKeyIDs: ["key-7d"],
            currencyTotals: [
                DeepSeekCurrencyContribution(
                    currency: "USD",
                    dayCosts: [plan7.anchorDayKey: 0.4],
                    modelCosts: ["deepseek-reasoner": 0.4],
                    apiKeyIDs: ["key-7d"]),
            ])
        store._test_providerFetchOutcomeOverride = { _ in
            Self.makeWideOutcome(updatedAt: now, plan: plan7, recentFold: fold7) { _ in fold7 }
        }
        await store.refreshProvider(.deepseek)
        #expect(store.deepseekHistoryState?.chunksByWindow.count == 1)
        #expect(store.snapshots[.deepseek]?.costUsage?.historyDays == 7)
        #expect(store.snapshots[.deepseek]?.detailRow(label: "Top model")?.value == "deepseek-reasoner")
        #expect(store.snapshots[.deepseek]?.detailRow(label: "Last 7 days") != nil)
    }

    private nonisolated static func makeDeepSeekDescriptorContext(
        env: [String: String],
        mode: ProviderSourceMode,
        includeOptionalUsage: Bool) -> ProviderFetchContext
    {
        let detection = BrowserDetection(homeDirectory: "/nonexistent/deepseek-disposition", cacheTTL: 0)
        return ProviderFetchContext(
            runtime: .app,
            sourceMode: mode,
            includeCredits: false,
            includeOptionalUsage: includeOptionalUsage,
            webTimeout: 60,
            webDebugDumpHTML: false,
            verbose: false,
            env: env,
            settings: nil,
            fetcher: UsageFetcher(environment: [:]),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: detection),
            browserDetection: detection,
            costReportingPeriod: .rolling(days: 90),
            costUsageBucketTimeZoneIdentifier: "UTC")
    }

    @Test
    func `suspended wide worker survives transient recent poll and publishes merged report with latest balance`()
        async throws
    {
        let t0 = try #require(ISO8601DateFormatter().date(from: "2026-06-15T12:00:00Z"))
        let t1 = t0.addingTimeInterval(60)
        let plan = try DeepSeekHistoryPlan.make(period: .rolling(days: 90), now: t0, calendar: Self.calendar("UTC"))
        let gate = DeepSeekTestChunkGate()
        let olderFetchCounter = DeepSeekTestCounterBox()
        let clock = DeepSeekTestClockBox(t0)
        let store = self.makeStore(period: .rolling(days: 90), timeZoneIdentifier: "UTC")
        defer { store.stopSharedSpendDashboardPublication() }
        store._test_deepseekNowProvider = { clock.current }

        let headFold = Self.makeFold(window: plan.chunks[0], day: plan.anchorDayKey, tokens: 100, cost: 1.0, req: 2)
        let chunk1 = Self.makeChunkFold(plan.chunks[1], tokens: 200, cost: 2.0, req: 4)
        let chunk2 = Self.makeChunkFold(plan.chunks[2], tokens: 300, cost: 3.0, req: 6)

        store._test_providerFetchOutcomeOverride = { _ in
            Self.makeWideOutcome(updatedAt: t0, plan: plan, recentFold: headFold) { window in
                await olderFetchCounter.increment()
                await gate.waitForRelease(window: window)
                return window == plan.chunks[1] ? chunk1 : chunk2
            }
        }
        await store.refreshProvider(.deepseek)
        await gate.waitUntilPaused(window: plan.chunks[1])
        let generationBeforeTransient = store.deepseekHistoryGeneration
        #expect(await olderFetchCounter.value == 1)

        // Transient poll (5s automatic browser join timeout for verified profileID) updates balance
        // without cancelling or restarting the wide worker and keeps prior usage freshness at t0.
        clock.set(t1)
        let transientScope = try Self.makeTransientScope(profileID: "chrome:Default", digest: nil)
        store._test_providerFetchOutcomeOverride = { _ in
            Self.makeDeepSeekOutcome(
                balance: 9.25,
                updatedAt: t1,
                detailedUsageState: .unavailable,
                disposition: .transientOptionalDetailUnavailable(transientScope))
        }
        await store.refreshProvider(.deepseek)
        #expect(store.deepseekHistoryGeneration == generationBeforeTransient && store.deepseekHistoryTask != nil)
        #expect(await olderFetchCounter.value == 1)
        #expect(store.snapshots[.deepseek]?.primary?.resetDescription?.contains("$9.25") == true)
        #expect(store.snapshots[.deepseek]?.updatedAt == t1 && store.snapshots[.deepseek]?.costUsage?.updatedAt == t0)
        #expect(store.snapshots[.deepseek]?.costUsage?.historyLabel == "Last 30 of 90 days")

        await gate.releaseAll()
        await store.deepseekHistoryTask?.value

        let finalSnapshot = try #require(store.snapshots[.deepseek])
        let finalCost = try #require(finalSnapshot.costUsage)
        #expect(finalSnapshot.primary?.resetDescription?.contains("$9.25") == true && finalSnapshot.updatedAt == t1)
        #expect(finalCost.last30DaysTokens == 600 && finalCost.last30DaysCostUSD == 6.0)
        #expect(finalCost.last30DaysRequests == 12 && finalCost.historyDays == 90)
        #expect(finalCost.historyScanIsPartial == false)
        #expect(await olderFetchCounter.value == 2)
    }

    @Test
    func `completed 365-day report survives transient poll with honest freshness and zero repeated older fetches`()
        async throws
    {
        let t0 = try #require(ISO8601DateFormatter().date(from: "2026-06-15T12:00:00Z"))
        let t1 = t0.addingTimeInterval(60)
        let t2 = t0.addingTimeInterval(120)
        let utc = try Self.calendar("UTC")
        let plan0 = DeepSeekHistoryPlan.make(period: .rolling(days: 365), now: t0, calendar: utc)
        let plan2 = DeepSeekHistoryPlan.make(period: .rolling(days: 365), now: t2, calendar: utc)
        let olderFetchCounter = DeepSeekTestCounterBox()
        let clock = DeepSeekTestClockBox(t0)
        let store = self.makeStore(period: .rolling(days: 365), timeZoneIdentifier: "UTC")
        defer { store.stopSharedSpendDashboardPublication() }
        store._test_deepseekNowProvider = { clock.current }

        let headV1 = Self.makeFold(window: plan0.chunks[0], day: plan0.anchorDayKey, tokens: 100, cost: 1.0, req: 2)
        let headV2 = Self.makeFold(window: plan2.chunks[0], day: plan2.anchorDayKey, tokens: 250, cost: 2.5, req: 5)
        func make365Outcome(
            _ balance: Double,
            _ at: Date,
            _ plan: DeepSeekHistoryPlan,
            _ head: DeepSeekChunkFoldResult) -> ProviderFetchOutcome
        {
            Self.makeWideOutcome(
                balance: balance,
                updatedAt: at,
                profileID: nil,
                digest: "digest-scoped-365",
                plan: plan,
                recentFold: head)
            { window in
                await olderFetchCounter.increment()
                return Self.makeChunkFold(window, tokens: 100, cost: 1.0, req: 2)
            }
        }

        store._test_providerFetchOutcomeOverride = { _ in make365Outcome(25.0, t0, plan0, headV1) }
        await store.refreshProvider(.deepseek)
        await store.deepseekHistoryTask?.value
        #expect(await olderFetchCounter.value == 12)
        #expect(store.deepseekHistoryState?.chunksByWindow.count == 13)
        #expect(store.snapshots[.deepseek]?.costUsage?.updatedAt == t0)

        // Transient poll updates balance at t1 while keeping usage freshness honestly at t0 and all 13 chunks intact.
        clock.set(t1)
        let transientScope = try Self.makeTransientScope(profileID: nil, digest: "digest-scoped-365", days: 365)
        store._test_providerFetchOutcomeOverride = { _ in
            Self.makeDeepSeekOutcome(
                balance: 24.25,
                updatedAt: t1,
                detailedUsageState: .unavailable,
                disposition: .transientOptionalDetailUnavailable(transientScope))
        }
        await store.refreshProvider(.deepseek)
        #expect(store.deepseekHistoryTask == nil && store.deepseekHistoryState?.chunksByWindow.count == 13)
        #expect(store.snapshots[.deepseek]?.primary?.resetDescription?.contains("$24.25") == true)
        #expect(store.snapshots[.deepseek]?.updatedAt == t1 && store.snapshots[.deepseek]?.costUsage?.updatedAt == t0)
        #expect(store.snapshots[.deepseek]?.costUsage?.historyDays == 365)
        #expect(store.snapshots[.deepseek]?.costUsage?.historyScanIsPartial == false)
        #expect(store.snapshots[.deepseek]?.costUsage?.last30DaysTokens == 1300)

        // Valid head poll replaces head in place with zero repeated older chunk fetches.
        clock.set(t2)
        store._test_providerFetchOutcomeOverride = { _ in make365Outcome(24.0, t2, plan2, headV2) }
        await store.refreshProvider(.deepseek)
        await store.deepseekHeadProjectionTask?.value
        #expect(store.deepseekHistoryTask == nil)
        #expect(await olderFetchCounter.value == 12)
        #expect(store.snapshots[.deepseek]?.primary?.resetDescription?.contains("$24.00") == true)
        #expect(store.snapshots[.deepseek]?.costUsage?.updatedAt == t2)
        #expect(store.snapshots[.deepseek]?.costUsage?.last30DaysTokens == 1450)
        #expect(store.snapshots[.deepseek]?.costUsage?.last30DaysCostUSD == 14.5)
        #expect(store.snapshots[.deepseek]?.costUsage?.historyScanIsPartial == false)
    }

    @Test(arguments: ["authLost", "optOut", "profileSwitch", "monthlyFallback", "unverifiedNil", "digestMismatch"])
    func `definitive retirement and unverified nil continuation cancel wide work and block late publication`(
        scenario: String) async throws
    {
        let t0 = try #require(ISO8601DateFormatter().date(from: "2026-06-15T12:00:00Z"))
        let t1 = t0.addingTimeInterval(60)
        let plan = try DeepSeekHistoryPlan.make(period: .rolling(days: 90), now: t0, calendar: Self.calendar("UTC"))
        let gate = DeepSeekTestChunkGate()
        let store = self.makeStore(period: .rolling(days: 90), timeZoneIdentifier: "UTC")
        defer { store.stopSharedSpendDashboardPublication() }
        store._test_deepseekNowProvider = { t0 }

        let headFold = Self.makeFold(window: plan.chunks[0], day: plan.anchorDayKey, tokens: 100, cost: 1.0, req: 2)
        let poisonFold = Self.makeChunkFold(plan.chunks[1], tokens: 9999, cost: 99.0, req: 99)
        store._test_providerFetchOutcomeOverride = { _ in
            Self.makeWideOutcome(updatedAt: t0, plan: plan, recentFold: headFold) { window in
                await gate.waitForReleaseIgnoringCancellation(window: window)
                return poisonFold
            }
        }
        await store.refreshProvider(.deepseek)
        await gate.waitUntilPaused(window: plan.chunks[1])
        let activeTask = store.deepseekHistoryTask
        #expect(activeTask != nil)

        let followUp: ProviderFetchOutcome
        switch scenario {
        case "authLost":
            followUp = Self.makeDeepSeekOutcome(
                balance: 9.0,
                updatedAt: t1,
                detailedUsageState: .webSessionRequired,
                disposition: .authLost)
        case "optOut":
            store.settings.showOptionalCreditsAndExtraUsage = false
            followUp = Self.makeDeepSeekOutcome(
                balance: 9.0,
                updatedAt: t1,
                detailedUsageState: .notRequested,
                disposition: .optOut)
        case "profileSwitch":
            store.beginDeepSeekProfileTransition()
            let otherScope = try Self.makeTransientScope(profileID: "chrome:Profile 2", digest: nil)
            followUp = Self.makeDeepSeekOutcome(
                balance: 9.0,
                updatedAt: t1,
                detailedUsageState: .unavailable,
                disposition: .transientOptionalDetailUnavailable(otherScope))
        case "monthlyFallback":
            let monthly = DeepSeekUsageSummary(
                todayTokens: 50,
                currentMonthTokens: 50,
                todayCost: 0.5,
                currentMonthCost: 0.5,
                requestCount: 1,
                currentMonthRequestCount: 1,
                topModel: "deepseek-chat",
                categoryBreakdown: [],
                daily: [DeepSeekDailyUsage(date: plan.anchorDayKey, totalTokens: 50, cost: 0.5, requestCount: 1)],
                currency: "USD",
                period: .currentMonth,
                updatedAt: t1)
            followUp = Self.makeDeepSeekOutcome(
                balance: 9.0,
                updatedAt: t1,
                summary: monthly,
                detailedUsageState: .available,
                disposition: .monthlyFallback)
        case "unverifiedNil":
            followUp = Self.makeDeepSeekOutcome(balance: 9.0, updatedAt: t1, detailedUsageState: .unavailable)
        case "digestMismatch":
            let badScope = try Self.makeTransientScope(profileID: "chrome:Default", digest: "digest-different-owner")
            followUp = Self.makeDeepSeekOutcome(
                balance: 9.0,
                updatedAt: t1,
                detailedUsageState: .unavailable,
                disposition: .transientOptionalDetailUnavailable(badScope))
        default:
            Issue.record("Unexpected scenario \(scenario)")
            return
        }

        store._test_providerFetchOutcomeOverride = { _ in followUp }
        await store.refreshProvider(.deepseek)
        #expect(store.deepseekHistoryTask == nil && store.deepseekHistoryState == nil)
        #expect(store.snapshots[.deepseek]?.primary?.resetDescription?.contains("$9.00") == true)
        if scenario == "monthlyFallback" {
            #expect(store.snapshots[.deepseek]?.costUsage?.historyLabel == "This month")
            #expect(store.snapshots[.deepseek]?.costUsage?.last30DaysTokens == 50)
        } else {
            #expect(store.snapshots[.deepseek]?.costUsage == nil && store.snapshots[.deepseek]?.details.isEmpty == true)
        }
        if scenario == "authLost" {
            #expect(store.snapshots[.deepseek]?.deepseekDetailedUsageState == .webSessionRequired)
        } else if scenario == "optOut" {
            #expect(store.snapshots[.deepseek]?.deepseekDetailedUsageState == .notRequested)
        }

        await gate.releaseAll()
        await activeTask?.value
        #expect(store.deepseekHistoryState == nil)
        if scenario == "monthlyFallback" {
            #expect(store.snapshots[.deepseek]?.costUsage?.historyLabel == "This month")
            #expect(store.snapshots[.deepseek]?.costUsage?.last30DaysTokens == 50)
            #expect(store.snapshots[.deepseek]?.costUsage?.last30DaysCostUSD == 0.5)
        } else {
            #expect(store.snapshots[.deepseek]?.costUsage == nil)
        }
    }

    @Test
    func `token account outcome preserves wide history on transient poll and retires on account switch`() async throws {
        let t0 = try #require(ISO8601DateFormatter().date(from: "2026-06-15T12:00:00Z"))
        let t1 = t0.addingTimeInterval(60)
        let plan = try DeepSeekHistoryPlan.make(period: .rolling(days: 90), now: t0, calendar: Self.calendar("UTC"))
        let gate = DeepSeekTestChunkGate()
        let olderFetchCounter = DeepSeekTestCounterBox()
        let store = self.makeStore(period: .rolling(days: 90), timeZoneIdentifier: "UTC")
        defer { store.stopSharedSpendDashboardPublication() }
        store._test_deepseekNowProvider = { t0 }
        store.settings.addTokenAccount(provider: .deepseek, label: "Primary", token: "sk-primary-test")
        store.settings.addTokenAccount(provider: .deepseek, label: "Secondary", token: "sk-secondary-test")
        store.settings.setActiveTokenAccountIndex(0, for: .deepseek)
        let primary = try #require(store.settings.tokenAccounts(for: .deepseek).first)
        let secondary = try #require(store.settings.tokenAccounts(for: .deepseek).last)

        let headFold = Self.makeFold(window: plan.chunks[0], day: plan.anchorDayKey, tokens: 100, cost: 1.0, req: 2)
        let chunk1 = Self.makeChunkFold(plan.chunks[1], tokens: 200, cost: 2.0, req: 4)
        let chunk2 = Self.makeChunkFold(plan.chunks[2], tokens: 300, cost: 3.0, req: 6)
        let initialOutcome = Self.makeWideOutcome(
            balance: 15.0,
            updatedAt: t0,
            digest: "digest-account-1",
            plan: plan,
            recentFold: headFold)
        { window in
            await olderFetchCounter.increment()
            await gate.waitForRelease(window: window)
            return window == plan.chunks[1] ? chunk1 : chunk2
        }

        await store.applySelectedOutcome(initialOutcome, provider: .deepseek, account: primary, fallbackSnapshot: nil)
        await gate.waitUntilPaused(window: plan.chunks[1])

        let transientScope = try Self.makeTransientScope(profileID: "chrome:Default", digest: "digest-account-1")
        let transientOutcome = Self.makeDeepSeekOutcome(
            balance: 14.5,
            updatedAt: t1,
            detailedUsageState: .unavailable,
            disposition: .transientOptionalDetailUnavailable(transientScope))
        await store.applySelectedOutcome(transientOutcome, provider: .deepseek, account: primary, fallbackSnapshot: nil)
        #expect(store.deepseekHistoryTask != nil)
        #expect(await olderFetchCounter.value == 1)
        #expect(store.snapshots[.deepseek]?.primary?.resetDescription?.contains("$14.50") == true)
        #expect(store.snapshots[.deepseek]?.costUsage?.updatedAt == t0)
        let cachedPrimary = store.accountSnapshots[.deepseek]?.first { $0.account.id == primary.id }?.snapshot
        #expect(cachedPrimary?.costUsage?.updatedAt == t0)

        await gate.releaseAll()
        await store.deepseekHistoryTask?.value
        #expect(store.snapshots[.deepseek]?.costUsage?.last30DaysTokens == 600)
        #expect(await olderFetchCounter.value == 2)

        store.settings.setActiveTokenAccountIndex(1, for: .deepseek)
        store.activateCachedTokenAccountSnapshot(provider: .deepseek, accountID: secondary.id)
        #expect(store.deepseekHistoryState == nil && store.deepseekHistoryTask == nil)
    }

    @Test
    func `descriptor and importer emit positive transient scope only for verified owners`() async throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-06-15T12:00:00Z"))
        let balance = Self.makeDeepSeekBalance(updatedAt: now)
        let unavailable = Self.makeDeepSeekBalance(state: .unavailable, updatedAt: now)
        let emptyUnavailable = DeepSeekPlatformTokenImporter.Resolution(
            profiles: [],
            selectedSummary: nil,
            detailedUsageState: .unavailable)
        #expect(DeepSeekTransientOptionalDetailScope(
            profileID: nil,
            ownerTokenDigest: nil,
            period: .rolling(days: 90),
            bucketTimeZoneIdentifier: "UTC") == nil)

        let apiKey = "sk-verified-api-key"
        let validScope = try #require(DeepSeekSettingsReader.profileScope(selectedTokenAccountID: nil, apiKey: apiKey))
        let scopedProfileEnv = [
            DeepSeekSettingsReader.profileIDEnvironmentKey: "chrome:Default",
            DeepSeekSettingsReader.profileScopeEnvironmentKey: validScope,
        ]
        let slowOps = DeepSeekProviderDescriptor.FetchOperations(
            fetchUsage: { _, _, _ in balance },
            resolveAutomaticSession: { _, _, _, _, _, _ in
                try? await Task.sleep(for: .seconds(5))
                return emptyUnavailable
            })

        let expectedProfileScope = try Self.makeTransientScope(profileID: "chrome:Default", digest: nil)
        let timedOutVerified = try await DeepSeekProviderDescriptor._loadUsageResultForTesting(
            apiKey: apiKey,
            context: Self.makeDeepSeekDescriptorContext(env: scopedProfileEnv, mode: .api, includeOptionalUsage: true),
            optionalResolutionJoinGrace: .milliseconds(15),
            operations: slowOps)
        #expect(timedOutVerified.deepseekHistoryRefreshDisposition
            == .transientOptionalDetailUnavailable(expectedProfileScope))

        let timedOutUnscoped = try await DeepSeekProviderDescriptor._loadUsageResultForTesting(
            apiKey: apiKey,
            context: Self.makeDeepSeekDescriptorContext(env: [:], mode: .api, includeOptionalUsage: true),
            optionalResolutionJoinGrace: .milliseconds(15),
            operations: slowOps)
        #expect(timedOutUnscoped.deepseekHistoryRefreshDisposition == .requiresProfileSelection)

        let optedOut = try await DeepSeekProviderDescriptor._loadUsageResultForTesting(
            apiKey: apiKey,
            context: Self.makeDeepSeekDescriptorContext(env: scopedProfileEnv, mode: .api, includeOptionalUsage: false),
            optionalResolutionJoinGrace: .seconds(1),
            operations: slowOps)
        #expect(optedOut.deepseekHistoryRefreshDisposition == .optOut)

        let sessionToken = "synthetic-scoped-platform-token-123456"
        let tokenDigest = try #require(DeepSeekPlatformBalanceOwner(profileID: "explicit", token: sessionToken)?
            .tokenDigest)
        let expectedTokenScope = try Self.makeTransientScope(profileID: nil, digest: tokenDigest)
        let scopedTokenEnv = [
            DeepSeekSettingsReader.platformTokenEnvironmentKey: sessionToken,
            DeepSeekSettingsReader.profileScopeEnvironmentKey: validScope,
        ]
        let scopedTransientAPI = try await DeepSeekProviderDescriptor._loadUsageResultForTesting(
            apiKey: apiKey,
            context: Self.makeDeepSeekDescriptorContext(env: scopedTokenEnv, mode: .api, includeOptionalUsage: true),
            optionalResolutionJoinGrace: .seconds(1),
            operations: .init(
                fetchUsage: { _, _, _ in unavailable },
                resolveAutomaticSession: { _, _, _, _, _, _ in emptyUnavailable }))
        #expect(scopedTransientAPI.deepseekHistoryRefreshDisposition
            == .transientOptionalDetailUnavailable(expectedTokenScope))

        let scopedTransientWeb = try await DeepSeekProviderDescriptor._loadPlatformUsageResultForTesting(
            context: Self.makeDeepSeekDescriptorContext(
                env: [DeepSeekSettingsReader.platformTokenEnvironmentKey: sessionToken],
                mode: .web,
                includeOptionalUsage: true),
            operations: .init(
                fetchUsage: { _, _, _ in unavailable },
                resolveAutomaticSession: { _, _, _, _, _, _ in emptyUnavailable },
                fetchPlatformUsage: { _, _ in unavailable }))
        #expect(scopedTransientWeb.deepseekHistoryRefreshDisposition
            == .transientOptionalDetailUnavailable(expectedTokenScope))

        let scopedAuthLost = try await DeepSeekProviderDescriptor._loadUsageResultForTesting(
            apiKey: apiKey,
            context: Self.makeDeepSeekDescriptorContext(env: scopedTokenEnv, mode: .api, includeOptionalUsage: true),
            optionalResolutionJoinGrace: .seconds(1),
            operations: .init(
                fetchUsage: { _, _, _ in Self.makeDeepSeekBalance(state: .webSessionRequired, updatedAt: now) },
                resolveAutomaticSession: { _, _, _, _, _, _ in emptyUnavailable }))
        #expect(scopedAuthLost.deepseekHistoryRefreshDisposition == .authLost)
    }

    @Test
    func `token importer preserves verified browser owner on transient 503 and clears on invalid token`() async throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-06-15T12:00:00Z"))
        let apiKey = "sk-verified-api-key"
        let validScope = try #require(DeepSeekSettingsReader.profileScope(selectedTokenAccountID: nil, apiKey: apiKey))
        let scopedProfileEnv = [
            DeepSeekSettingsReader.profileIDEnvironmentKey: "chrome:Default",
            DeepSeekSettingsReader.profileScopeEnvironmentKey: validScope,
        ]
        let balance = Self.makeDeepSeekBalance(updatedAt: now)
        let unavailable = Self.makeDeepSeekBalance(state: .unavailable, updatedAt: now)
        let candidateA = DeepSeekPlatformTokenImporter.TokenInfo(
            id: "chrome:Default",
            token: "tok-a-12345678901234567890",
            sourceLabel: "Default")
        let candidateB = DeepSeekPlatformTokenImporter.TokenInfo(
            id: "chrome:Profile 2",
            token: "tok-b-12345678901234567890",
            sourceLabel: "Work")
        let browserOwner = try #require(DeepSeekPlatformBalanceOwner(profileID: candidateA.id, token: candidateA.token))
        let browserScope = try Self.makeTransientScope(
            profileID: browserOwner.profileID,
            digest: browserOwner.tokenDigest)
        let transientRes = await DeepSeekPlatformTokenImporter._resolveForTesting(
            candidates: [candidateA, candidateB],
            selectedProfileID: candidateA.id,
            validate: { token in
                if token == candidateA.token { throw DeepSeekUsageError.apiError("HTTP 503") }
                return DeepSeekUsageSummary(
                    todayTokens: 1,
                    currentMonthTokens: 1,
                    todayCost: nil,
                    currentMonthCost: nil,
                    requestCount: 1,
                    currentMonthRequestCount: 1,
                    topModel: nil,
                    categoryBreakdown: [],
                    daily: [],
                    currency: "USD",
                    updatedAt: now)
            })
        #expect(transientRes.detailedUsageState == .unavailable)
        #expect(transientRes.transientUnavailableOwner == browserOwner)

        let autoTransient = try await DeepSeekProviderDescriptor._loadUsageResultForTesting(
            apiKey: apiKey,
            context: Self.makeDeepSeekDescriptorContext(env: scopedProfileEnv, mode: .api, includeOptionalUsage: true),
            optionalResolutionJoinGrace: .seconds(1),
            operations: .init(
                fetchUsage: { _, _, _ in balance },
                resolveAutomaticSession: { _, _, _, _, _, _ in transientRes }))
        #expect(autoTransient.deepseekHistoryRefreshDisposition == .transientOptionalDetailUnavailable(browserScope))

        let expiredRes = await DeepSeekPlatformTokenImporter._resolveForTesting(
            candidates: [candidateA],
            selectedProfileID: candidateA.id,
            validate: { _ in throw DeepSeekUsageError.invalidPlatformToken })
        #expect(expiredRes.detailedUsageState == .webSessionRequired && expiredRes.transientUnavailableOwner == nil)

        let webTransientRes = await DeepSeekPlatformTokenImporter._resolvePlatformBalanceForTesting(
            candidates: [candidateA],
            selectedProfileID: candidateA.id,
            cache: DeepSeekPlatformValidationCache(validityTTL: 0),
            validate: { _ in unavailable })
        let webAutoTransient = try await DeepSeekProviderDescriptor._loadPlatformUsageResultForTesting(
            context: Self.makeDeepSeekDescriptorContext(env: [:], mode: .web, includeOptionalUsage: true),
            operations: .init(
                fetchUsage: { _, _, _ in balance },
                resolveAutomaticSession: { _, _, _, _, _, _ in webTransientRes }))
        #expect(webAutoTransient.deepseekHistoryRefreshDisposition == .transientOptionalDetailUnavailable(browserScope))
    }
}

extension DeepSeekLongHistoryTests {
    // MARK: - Menu, Settings preview, Spend Dashboard, Widget projection parity, and synthetic perf

    @MainActor
    @Test
    func `menu, settings preview, spend dashboard, and widget agree on 60 of 90 partial coverage and gap semantics`()
        throws
    {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-06-15T12:00:00Z"))
        let utc = try Self.calendar("UTC")
        let plan = DeepSeekHistoryPlan.make(period: .rolling(days: 90), now: now, calendar: utc)

        let headFold = Self.makeFold(window: plan.chunks[0], day: plan.anchorDayKey, tokens: 1000, cost: 1.5, req: 10)
        let oldestFold = Self.makeChunkFold(plan.chunks[2], tokens: 2000, cost: 2.5, req: 20)
        let partialSummary = DeepSeekUsageCostParser.mergeByAPIKeyChunks(
            [headFold, oldestFold],
            plan: plan,
            failedChunkCount: 1)

        let store = self.makeStore(period: .rolling(days: 90), timeZoneIdentifier: "UTC")
        defer { store.stopSharedSpendDashboardPublication() }
        let usage = Self.makeDeepSeekBalance(12.0, summary: partialSummary, updatedAt: now).toUsageSnapshot()
        store.snapshots[.deepseek] = usage
        store.publishProviderDerivedTokenSnapshot(from: usage, for: .deepseek)

        // Menu card and Settings preview use identical period semantics.
        let menuModel = store.menuCardModel(for: .deepseek, context: .menu, now: now)
        let settingsModel = store.menuCardModel(for: .deepseek, context: .settings, now: now)
        let menuUsageSection = try #require(menuModel.providerDetails.first { $0.title == "Usage" })
        let settingsUsageSection = try #require(settingsModel.providerDetails.first { $0.title == "Usage" })
        #expect(menuUsageSection.rows.contains { $0.label == "Last 60 of 90 days" })
        #expect(settingsUsageSection.rows.contains { $0.label == "Last 60 of 90 days" })
        #expect(settingsModel.tokenUsage?.monthLine.hasPrefix("Last 60 of 90 days:") == true)

        // Spend Dashboard respects disjoint intervals: 60/90 under 90d filter, 30/30 under 30d filter, middle gap
        // unknown!
        let costSnapshot = try #require(usage.costUsage)
        let dashboard90 = SpendDashboardModel.build(
            inputs: [.init(provider: .deepseek, displayName: "DeepSeek", snapshot: costSnapshot)],
            requestedDays: 90,
            now: now,
            calendar: utc)
        let group90 = try #require(dashboard90.groups.first)
        #expect(group90.coveredDayCount == 60)
        #expect(group90.totalCost == 4.0)
        #expect(group90.totalTokens == 3000)
        #expect(group90.providers.first?.costIsLowerBound == true)
        #expect(group90.providers.first?.tokensAreLowerBound == true)
        let middleGapDate = try #require(CostUsageLocalDay.date(fromKey: plan.chunks[1].startDayKey, calendar: utc))
        let middleGapSummary = try #require(group90.dailySummaries.first { $0.day == middleGapDate })
        #expect(middleGapSummary.providers.first?.totalCost == nil)
        #expect(middleGapSummary.providers.first?.totalTokens == nil)
        #expect(middleGapSummary.providers.first?.requestCount == nil)

        // Matched 30d filter sees complete 30/30 coverage without false partial flags.
        let dashboard30 = SpendDashboardModel.build(
            inputs: [.init(provider: .deepseek, displayName: "DeepSeek", snapshot: costSnapshot)],
            requestedDays: 30,
            now: now,
            calendar: utc)
        let group30 = try #require(dashboard30.groups.first)
        #expect(group30.coveredDayCount == 30)
        #expect(group30.totalCost == 1.5)
        #expect(group30.totalTokens == 1000)
        #expect(group30.providers.first?.costIsLowerBound == false)

        // Widget projection caps bars <= 45, keeps exact totals, preserves date span, and stays in cost mode across
        // gap.
        let projection = UsageStore.deepSeekWidgetChartProjection(from: costSnapshot)
        #expect(projection.points.count <= 45)
        #expect(projection.bucketDays == 2)
        #expect(projection.chartTitle == "Last 60 of 90 days")
        #expect(projection.compactPeriodLabel == "60/90d")
        #expect(projection.startDayKey == plan.requestedStartDayKey)
        #expect(projection.endDayKey == plan.requestedEndDayKey)
        #expect(projection.prefersCostMode == true)
        #expect(projection.points.compactMap(\.costUSD).reduce(0, +) == 4.0)
        #expect(projection.points.compactMap(\.totalTokens).reduce(0, +) == 3000)
        #expect(projection.points.contains { $0.costUSD == nil }) // middle gap bucket stays nil, not fake zero!
    }

    @Test
    func `365-day widget projection caps to at most 45 calendar groups and legacy widget JSON still decodes`() throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-06-15T12:00:00Z"))
        let utc = try Self.calendar("UTC")
        let plan = DeepSeekHistoryPlan.make(period: .allTime, now: now, calendar: utc)

        var daily: [DeepSeekDailyUsage] = []
        var expectedCost = 0.0
        var expectedTokens = 0
        for index in 0..<365 {
            let date = try #require(utc.date(byAdding: .day, value: -index, to: utc.startOfDay(for: now)))
            let key = CostUsageLocalDay.key(from: date, calendar: utc)
            let cost = Double((index % 5) + 1) * 0.25
            let tokens = (index + 1) * 10
            expectedCost += cost
            expectedTokens += tokens
            daily.append(DeepSeekDailyUsage(date: key, totalTokens: tokens, cost: cost, requestCount: 1))
        }
        daily.sort { $0.date < $1.date }

        let summary = DeepSeekUsageSummary(
            todayTokens: 10,
            currentMonthTokens: expectedTokens,
            todayCost: 0.25,
            currentMonthCost: expectedCost,
            requestCount: 1,
            currentMonthRequestCount: 365,
            topModel: "deepseek-chat",
            categoryBreakdown: [],
            daily: daily,
            currency: "USD",
            period: .last30Days,
            coverage: DeepSeekUsageCoverage(
                requestedPeriod: .allTime,
                requestedStartDay: plan.requestedStartDayKey,
                requestedEndDay: plan.requestedEndDayKey,
                requestedDays: 365,
                coveredIntervals: [CostUsageDayInterval(
                    startDay: plan.requestedStartDayKey,
                    endDay: plan.requestedEndDayKey)],
                coveredDays: 365),
            timeZoneSeconds: 0,
            updatedAt: now)
        let tokenSnapshot = summary.toCostUsageTokenSnapshot(calendar: utc)
        let projection = UsageStore.deepSeekWidgetChartProjection(from: tokenSnapshot)

        #expect(projection.points.count <= 45)
        #expect(projection.bucketDays == 14)
        #expect(projection.chartTitle == "Last 365 days")
        #expect(projection.compactPeriodLabel == "365d")
        #expect(projection.startDayKey == plan.requestedStartDayKey)
        #expect(projection.endDayKey == plan.requestedEndDayKey)
        #expect(abs(projection.points.compactMap(\.costUSD).reduce(0, +) - expectedCost) < 1e-6)
        #expect(projection.points.compactMap(\.totalTokens).reduce(0, +) == expectedTokens)

        // Legacy WidgetSnapshot JSON without the additive chart metadata fields decodes cleanly.
        let legacyJSON = """
        {
          "entries": [{
            "provider": "deepseek",
            "updatedAt": 0,
            "dailyUsage": [{"dayKey": "2026-06-15", "totalTokens": 100, "costUSD": 1.25}],
            "tokenUsage": {
              "sessionCostUSD": 1.25,
              "sessionTokens": 100,
              "last30DaysCostUSD": 1.25,
              "last30DaysTokens": 100,
              "currencyCode": "USD",
              "sessionLabel": "Today",
              "last30DaysLabel": "30d"
            }
          }],
          "enabledProviders": ["deepseek"],
          "usageBarsShowUsed": false,
          "generatedAt": 0
        }
        """
        let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: Data(legacyJSON.utf8))
        let entry = try #require(decoded.entries.first)
        #expect(entry.tokenUsage?.last30DaysLabel == "30d")
        #expect(entry.tokenUsage?.chartTitle == nil)
        #expect(entry.tokenUsage?.chartStartDayKey == nil)
        #expect(entry.tokenUsage?.chartEndDayKey == nil)
        #expect(entry.tokenUsage?.chartBucketDays == nil)
        #expect(entry.tokenUsage?.chartPrefersCostMode == nil)

        // Grouped chart copy labels title from explicit span, peak per group, and original date span.
        #expect(UsageHistoryChartCopy.title(
            dayCount: projection.points.count,
            explicitTitle: projection.chartTitle) == "Last 365 days")
        #expect(UsageHistoryChartCopy.peak(
            maximum: 12.5,
            isCostMode: true,
            currencyCode: "USD",
            bucketDays: 14) == "Peak $12/14d")
        #expect(UsageHistoryChartCopy.peak(
            maximum: 12.5,
            isCostMode: true,
            currencyCode: "USD",
            bucketDays: 7) == "Peak $12/wk")
        #expect(UsageHistoryChartCopy.peak(
            maximum: 12.5,
            isCostMode: true,
            currencyCode: "USD",
            bucketDays: 2) == "Peak $12/2d")
        let range = try #require(UsageHistoryChartCopy.range(
            points: projection.points,
            explicitStartDayKey: projection.startDayKey,
            explicitEndDayKey: projection.endDayKey))
        #expect(range.start == WidgetFormat.dayLabel(plan.requestedStartDayKey))
        #expect(range.end == WidgetFormat.dayLabel(plan.requestedEndDayKey))
    }

    private struct SyntheticWindowResult {
        let elapsedMs: Double
        let requests: Int
        let coveredDays: Int
        let dailyCount: Int
        let payloadBytes: Int
    }

    private static func runSyntheticWindow(
        days: Int,
        now: Date,
        calendar: Calendar) async throws -> SyntheticWindowResult
    {
        let clock = ContinuousClock()
        let transport = DeepSeekTestScriptedTransport(bodyBuilder: { url, start, end in
            let dayCount = max(1, (end - start) / 86400)
            if url.path.hasSuffix("/amount") {
                var series: [[String: Any]] = []
                for keyIdx in 0..<3 {
                    for model in ["deepseek-chat", "deepseek-reasoner"] {
                        var buckets: [(time: Int, tokens: Int, requests: Int)] = []
                        buckets.reserveCapacity(dayCount)
                        for d in 0..<dayCount {
                            buckets.append((start + d * 86400 + 3600, 1000 + d, 2))
                        }
                        series.append(Self.amountSeries(keyID: "key-\(keyIdx)", model: model, buckets: buckets))
                    }
                }
                let fnBuckets = (0..<dayCount).map { (start + $0 * 86400 + 3600, 1) }
                return Self.amountJSON(series: series, functionBuckets: fnBuckets)
            }
            var usdSeries: [[String: Any]] = []
            for keyIdx in 0..<3 {
                for model in ["deepseek-chat", "deepseek-reasoner"] {
                    let buckets = (0..<dayCount).map { (start + $0 * 86400 + 3600, "0.05") }
                    usdSeries.append(Self.costSeries(keyID: "key-\(keyIdx)", model: model, buckets: buckets))
                }
            }
            return Self.costJSON(blocks: [("USD", usdSeries)])
        })

        let startTick = clock.now
        let summary = try await DeepSeekUsageFetcher.fetchUsageSummary(
            platformToken: "synthetic-platform-token",
            period: .rolling(days: days),
            now: now,
            localCalendar: calendar,
            transport: transport)
        let elapsed = startTick.duration(to: clock.now)
        let ms = Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) / 1e15
        return await SyntheticWindowResult(
            elapsedMs: ms,
            requests: transport.requests.count,
            coveredDays: summary.coverage?.coveredDays ?? 0,
            dailyCount: summary.daily.count,
            payloadBytes: transport.totalResponseBytes)
    }

    @MainActor
    @Test
    func `synthetic 30, 90, and 365 day streaming folds keep bounded state and off-main execution`() async throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-06-15T12:00:00Z"))
        let utc = try Self.calendar("UTC")
        let clock = ContinuousClock()

        let rssStart = Self.residentMemoryBytes()
        let r30 = try await Self.runSyntheticWindow(days: 30, now: now, calendar: utc)
        let r90 = try await Self.runSyntheticWindow(days: 90, now: now, calendar: utc)
        let r365 = try await Self.runSyntheticWindow(days: 365, now: now, calendar: utc)

        #expect(r30.requests == 2 && r30.coveredDays == 30 && r30.dailyCount == 30)
        #expect(r90.requests == 6 && r90.coveredDays == 90 && r90.dailyCount == 90)
        #expect(r365.requests == 26 && r365.coveredDays == 365 && r365.dailyCount == 365)

        // Store 365d -> 7d transition releases older folded chunks and limits widget saves to <= 2.
        let plan365 = DeepSeekHistoryPlan.make(period: .rolling(days: 365), now: now, calendar: utc)
        let plan7 = DeepSeekHistoryPlan.make(period: .rolling(days: 7), now: now, calendar: utc)
        let store = self.makeStore(period: .rolling(days: 365), timeZoneIdentifier: "UTC")
        defer { store.stopSharedSpendDashboardPublication() }
        store._test_deepseekNowProvider = { now }
        let widgetSaves = DeepSeekTestCounterBox()
        let onMain = DeepSeekTestFlagBox(false)
        store._test_widgetSnapshotSaveOverride = { _ in await widgetSaves.increment() }

        let head365 = Self.makeFold(
            window: plan365.chunks[0],
            day: plan365.anchorDayKey,
            tokens: 100,
            cost: 1.0,
            req: 2)
        let recentStart = clock.now
        store._test_providerFetchOutcomeOverride = { _ in
            Self.makeWideOutcome(
                balance: 25.0,
                updatedAt: now,
                digest: "digest-perf",
                plan: plan365,
                recentFold: head365)
            { window in
                if Self.isExecutingOnMainThread() {
                    await onMain.set(true)
                }
                return Self.makeChunkFold(window, tokens: 100, cost: 1.0, req: 2)
            }
        }
        await store.refreshProvider(.deepseek)
        let timeToRecent = recentStart.duration(to: clock.now)
        await store.deepseekHistoryTask?.value
        await store.widgetSnapshotPersistTask?.value
        let timeToFull365 = recentStart.duration(to: clock.now)
        let rssAfter365 = Self.residentMemoryBytes()

        #expect(await onMain.value == false)
        #expect(store.deepseekHistoryState?.chunksByWindow.count == 13)
        #expect(await widgetSaves.value == 1)

        // Narrow 365 -> 7 and confirm older chunks are pruned immediately.
        store.settings.costReportingPeriod = .rolling(days: 7)
        let head7 = Self.makeFold(window: plan7.chunks[0], day: plan7.anchorDayKey, tokens: 50, cost: 0.5, req: 1)
        store._test_providerFetchOutcomeOverride = { _ in
            Self.makeWideOutcome(
                balance: 25.0,
                updatedAt: now,
                digest: "digest-perf",
                plan: plan7,
                recentFold: head7)
            { _ in head7 }
        }
        await store.refreshProvider(.deepseek)
        let rssAfter7 = Self.residentMemoryBytes()
        #expect(store.deepseekHistoryState?.chunksByWindow.count == 1)
        let recentMs = Double(timeToRecent.components.seconds) * 1000
            + Double(timeToRecent.components.attoseconds) / 1e15
        let fullMs = Double(timeToFull365.components.seconds) * 1000
            + Double(timeToFull365.components.attoseconds) / 1e15
        let toMB: (UInt64) -> Double = { Double($0) / (1024 * 1024) }
        let line = await String(
            format: "[deepseek-perf] 30d=%.2fms(%dreq,%dB) 90d=%.2fms(%dreq,%dB) 365d=%.2fms(%dreq,%dB) "
                + "storeRecent=%.2fms store365=%.2fms chunks=13->1 widgetSaves=%d offMain=%@ "
                + "rssMB=%.1f->%.1f->%.1f",
            r30.elapsedMs,
            r30.requests,
            r30.payloadBytes,
            r90.elapsedMs,
            r90.requests,
            r90.payloadBytes,
            r365.elapsedMs,
            r365.requests,
            r365.payloadBytes,
            recentMs,
            fullMs,
            widgetSaves.value,
            (onMain.value) ? "false" : "true",
            toMB(rssStart),
            toMB(rssAfter365),
            toMB(rssAfter7))
        print(line)
    }
}
