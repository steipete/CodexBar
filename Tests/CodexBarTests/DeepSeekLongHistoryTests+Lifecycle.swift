import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
extension DeepSeekLongHistoryTests {
    // MARK: - Wide worker active-slot retirement and generation isolation

    @Test(arguments: [1, 2])
    func `optional detail toggle off then on retires dead worker slot and launches fresh 90-day worker`(
        pausedChunkIndex: Int) async throws
    {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-06-15T12:00:00Z"))
        let plan = try DeepSeekHistoryPlan.make(period: .rolling(days: 90), now: now, calendar: Self.calendar("UTC"))
        let pausedWindow = plan.chunks[pausedChunkIndex]
        let firstGate = DeepSeekTestChunkGate()
        let secondGate = DeepSeekTestChunkGate()
        let firstFetchCounter = DeepSeekTestCounterBox()
        let secondFetchCounter = DeepSeekTestCounterBox()

        let store = self.makeStore(period: .rolling(days: 90), timeZoneIdentifier: "UTC")
        defer { store.stopSharedSpendDashboardPublication() }
        store._test_deepseekNowProvider = { now }

        let headFold = Self.makeFold(window: plan.chunks[0], day: plan.anchorDayKey, tokens: 100, cost: 1.0, req: 2)
        let chunk1 = Self.makeChunkFold(plan.chunks[1], tokens: 200, cost: 2.0, req: 4)
        let chunk2 = Self.makeChunkFold(plan.chunks[2], tokens: 300, cost: 3.0, req: 6)

        store._test_providerFetchOutcomeOverride = { _ in
            Self.makeWideOutcome(updatedAt: now, plan: plan, recentFold: headFold) { window in
                await firstFetchCounter.increment()
                if window == pausedWindow {
                    await firstGate.waitForReleaseIgnoringCancellation(window: window)
                }
                return window == plan.chunks[1] ? chunk1 : chunk2
            }
        }

        await store.refreshProvider(.deepseek)
        await firstGate.waitUntilPaused(window: pausedWindow)
        let firstGeneration = store.deepseekHistoryGeneration
        let firstTask = try #require(store.deepseekHistoryTask)
        #expect(store.deepseekHistoryState?.activeScope != nil)
        #expect(store.deepseekHistoryState?.activeProjection != nil)
        #expect(await firstFetchCounter.value == pausedChunkIndex)

        // Turning optional detail off invalidates the active scope; releasing lets the worker exit early.
        store.settings.showOptionalCreditsAndExtraUsage = false
        await firstGate.releaseAll()
        await firstTask.value

        #expect(store.deepseekHistoryTask == nil)
        #expect(store.deepseekHistoryState?.activeScope == nil)
        #expect(store.deepseekHistoryState?.activeProjection == nil)
        #expect(store.deepseekHistoryState?.completedScope == nil)
        #expect(await firstFetchCounter.value == pausedChunkIndex)
        #expect(store.snapshots[.deepseek]?.costUsage?.historyLabel == "Last 30 of 90 days")
        #expect(store.snapshots[.deepseek]?.costUsage?.last30DaysTokens == 100)

        // Turning optional detail back on and refreshing the same scope must launch a fresh worker, not coalesce.
        store.settings.showOptionalCreditsAndExtraUsage = true
        store._test_providerFetchOutcomeOverride = { _ in
            Self.makeWideOutcome(updatedAt: now, plan: plan, recentFold: headFold) { window in
                await secondFetchCounter.increment()
                await secondGate.waitForRelease(window: window)
                return window == plan.chunks[1] ? chunk1 : chunk2
            }
        }

        await store.refreshProvider(.deepseek)
        await secondGate.waitUntilPaused(window: plan.chunks[1])
        let secondGeneration = store.deepseekHistoryGeneration
        let secondTask = try #require(store.deepseekHistoryTask)
        #expect(secondGeneration > firstGeneration)
        #expect(store.deepseekHistoryState?.activeScope != nil)
        #expect(await secondFetchCounter.value == 1)

        await secondGate.releaseAll()
        await secondTask.value

        let finalCost = try #require(store.snapshots[.deepseek]?.costUsage)
        #expect(finalCost.last30DaysTokens == 600)
        #expect(finalCost.last30DaysCostUSD == 6.0)
        #expect(finalCost.last30DaysRequests == 12)
        #expect(finalCost.historyDays == 90)
        #expect(finalCost.historyScanIsPartial == false)
        #expect(await secondFetchCounter.value == 2)
        #expect(store.deepseekHistoryTask == nil)
        #expect(store.deepseekHistoryState?.activeScope == nil)
        #expect(store.deepseekHistoryState?.activeProjection == nil)
    }

    @Test
    func `missing live snapshot at publication retires active slot and allows clean same-scope recovery`()
        async throws
    {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-06-15T12:00:00Z"))
        let plan = try DeepSeekHistoryPlan.make(period: .rolling(days: 90), now: now, calendar: Self.calendar("UTC"))
        let firstGate = DeepSeekTestChunkGate()
        let secondGate = DeepSeekTestChunkGate()
        let firstFetchCounter = DeepSeekTestCounterBox()
        let secondFetchCounter = DeepSeekTestCounterBox()

        let store = self.makeStore(period: .rolling(days: 90), timeZoneIdentifier: "UTC")
        defer { store.stopSharedSpendDashboardPublication() }
        store._test_deepseekNowProvider = { now }

        let headFold = Self.makeFold(window: plan.chunks[0], day: plan.anchorDayKey, tokens: 100, cost: 1.0, req: 2)
        let chunk1 = Self.makeChunkFold(plan.chunks[1], tokens: 200, cost: 2.0, req: 4)
        let chunk2 = Self.makeChunkFold(plan.chunks[2], tokens: 300, cost: 3.0, req: 6)

        store._test_providerFetchOutcomeOverride = { _ in
            Self.makeWideOutcome(updatedAt: now, plan: plan, recentFold: headFold) { window in
                await firstFetchCounter.increment()
                await firstGate.waitForRelease(window: window)
                return window == plan.chunks[1] ? chunk1 : chunk2
            }
        }

        await store.refreshProvider(.deepseek)
        await firstGate.waitUntilPaused(window: plan.chunks[1])
        let firstGeneration = store.deepseekHistoryGeneration
        let firstTask = try #require(store.deepseekHistoryTask)
        #expect(store.deepseekHistoryState?.activeScope != nil)
        #expect(store.deepseekHistoryState?.activeProjection != nil)

        // Clear live snapshot while keeping history state and generation intact, forcing publication early return.
        store.snapshots[.deepseek] = nil
        await firstGate.releaseAll()
        await firstTask.value

        #expect(await firstFetchCounter.value == 2)
        #expect(store.snapshots[.deepseek] == nil)
        #expect(store.deepseekHistoryTask == nil)
        #expect(store.deepseekHistoryState?.activeScope == nil)
        #expect(store.deepseekHistoryState?.activeProjection == nil)
        #expect(store.deepseekHistoryState?.completedScope == nil)

        // Subsequent same-scope refresh launches a new worker with a raised generation and publishes 90-day totals.
        store._test_providerFetchOutcomeOverride = { _ in
            Self.makeWideOutcome(updatedAt: now, plan: plan, recentFold: headFold) { window in
                await secondFetchCounter.increment()
                await secondGate.waitForRelease(window: window)
                return window == plan.chunks[1] ? chunk1 : chunk2
            }
        }

        await store.refreshProvider(.deepseek)
        await secondGate.waitUntilPaused(window: plan.chunks[1])
        let secondGeneration = store.deepseekHistoryGeneration
        let secondTask = try #require(store.deepseekHistoryTask)
        #expect(secondGeneration > firstGeneration)
        #expect(store.deepseekHistoryState?.activeScope != nil)
        #expect(await secondFetchCounter.value == 1)

        await secondGate.releaseAll()
        await secondTask.value

        let finalCost = try #require(store.snapshots[.deepseek]?.costUsage)
        #expect(finalCost.last30DaysTokens == 600)
        #expect(finalCost.last30DaysCostUSD == 6.0)
        #expect(finalCost.last30DaysRequests == 12)
        #expect(finalCost.historyDays == 90)
        #expect(finalCost.historyScanIsPartial == false)
        #expect(await secondFetchCounter.value == 2)
        #expect(store.deepseekHistoryTask == nil)
        #expect(store.deepseekHistoryState?.activeScope == nil)
        #expect(store.deepseekHistoryState?.activeProjection == nil)
    }

    @Test
    func `late non-cooperative predecessor exit cannot clear successor active slot or publish stale data`()
        async throws
    {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-06-15T12:00:00Z"))
        let utc = try Self.calendar("UTC")
        let planA = DeepSeekHistoryPlan.make(period: .rolling(days: 90), now: now, calendar: utc)
        let planB = DeepSeekHistoryPlan.make(period: .rolling(days: 365), now: now, calendar: utc)
        let gateA = DeepSeekTestChunkGate()
        let gateB = DeepSeekTestChunkGate()
        let fetchCounterB = DeepSeekTestCounterBox()

        let store = self.makeStore(period: .rolling(days: 90), timeZoneIdentifier: "UTC")
        defer { store.stopSharedSpendDashboardPublication() }
        store._test_deepseekNowProvider = { now }

        let headA = Self.makeFold(window: planA.chunks[0], day: planA.anchorDayKey, tokens: 100, cost: 1.0, req: 2)
        let poisonA = Self.makeChunkFold(planA.chunks[1], tokens: 9999, cost: 99.0, req: 99)

        store._test_providerFetchOutcomeOverride = { _ in
            Self.makeWideOutcome(balance: 10.0, updatedAt: now, plan: planA, recentFold: headA) { window in
                // Non-cooperative transport ignores cancellation and resolves only after successor is active.
                await gateA.waitForReleaseIgnoringCancellation(window: window)
                return poisonA
            }
        }

        await store.refreshProvider(.deepseek)
        await gateA.waitUntilPaused(window: planA.chunks[1])
        let generationA = store.deepseekHistoryGeneration
        let taskA = try #require(store.deepseekHistoryTask)

        // Switch period 90d -> 365d to start successor Worker B while Worker A is still suspended.
        let headB = Self.makeFold(window: planB.chunks[0], day: planB.anchorDayKey, tokens: 250, cost: 2.5, req: 5)
        store.settings.costReportingPeriod = .rolling(days: 365)
        store._test_providerFetchOutcomeOverride = { _ in
            Self.makeWideOutcome(balance: 12.0, updatedAt: now, plan: planB, recentFold: headB) { window in
                await fetchCounterB.increment()
                await gateB.waitForRelease(window: window)
                return Self.makeChunkFold(window, tokens: 100, cost: 1.0, req: 2)
            }
        }

        await store.refreshProvider(.deepseek)
        await gateB.waitUntilPaused(window: planB.chunks[1])
        let generationB = store.deepseekHistoryGeneration
        let taskB = try #require(store.deepseekHistoryTask)
        let activeScopeB = try #require(store.deepseekHistoryState?.activeScope)
        #expect(generationB > generationA)
        #expect(activeScopeB.period == .rolling(days: 365))
        #expect(store.deepseekHistoryState?.activeProjection != nil)
        #expect(await fetchCounterB.value == 1)

        // Release Worker A while Worker B is active; Worker A's cleanup must NOT touch Worker B's slot or snapshot.
        await gateA.releaseAll()
        await taskA.value

        #expect(store.deepseekHistoryGeneration == generationB)
        #expect(store.deepseekHistoryTask != nil)
        #expect(store.deepseekHistoryState?.activeScope == activeScopeB)
        #expect(store.deepseekHistoryState?.activeProjection != nil)
        #expect(store.snapshots[.deepseek]?.costUsage?.last30DaysTokens == 250)
        #expect(store.snapshots[.deepseek]?.costUsage?.last30DaysCostUSD == 2.5)

        // Release Worker B and verify exact 365-day totals and clean slot retirement.
        await gateB.releaseAll()
        await taskB.value

        let finalCost = try #require(store.snapshots[.deepseek]?.costUsage)
        #expect(finalCost.last30DaysTokens == 1450)
        #expect(finalCost.last30DaysCostUSD == 14.5)
        #expect(finalCost.last30DaysRequests == 29)
        #expect(finalCost.historyDays == 365)
        #expect(finalCost.historyScanIsPartial == false)
        #expect(await fetchCounterB.value == 12)
        #expect(store.deepseekHistoryGeneration == generationB)
        #expect(store.deepseekHistoryGeneration > generationA)
        #expect(store.deepseekHistoryTask == nil)
        #expect(store.deepseekHistoryState?.activeScope == nil)
        #expect(store.deepseekHistoryState?.activeProjection == nil)
    }

    @Test
    func `transient poll across midnight retires prior-day summary and cross-day detail rows stay explicitly dated`()
        async throws
    {
        let iso = ISO8601DateFormatter()
        let day1 = try #require(iso.date(from: "2026-06-15T23:55:00Z"))
        let day2 = try #require(iso.date(from: "2026-06-16T00:05:00Z"))
        let utc = try Self.calendar("UTC")
        let plan1 = DeepSeekHistoryPlan.make(period: .rolling(days: 90), now: day1, calendar: utc)
        let clock = DeepSeekTestClockBox(day1)

        let store = self.makeStore(period: .rolling(days: 90), timeZoneIdentifier: "UTC")
        defer { store.stopSharedSpendDashboardPublication() }
        store._test_deepseekNowProvider = { clock.current }

        let d1Head = Self.makeFold(window: plan1.chunks[0], day: plan1.anchorDayKey, tokens: 100, cost: 1.0, req: 1)
        let d1Mid = Self.makeChunkFold(plan1.chunks[1], tokens: 200, cost: 2.0, req: 2)
        let d1Old = Self.makeChunkFold(plan1.chunks[2], tokens: 300, cost: 3.0, req: 3)
        let d1Full = DeepSeekUsageCostParser.mergeByAPIKeyChunks([d1Head, d1Mid, d1Old], plan: plan1)

        store._test_providerFetchOutcomeOverride = { _ in
            Self.makeWideOutcome(
                balance: 10.0,
                updatedAt: day1,
                digest: "digest-lifecycle-owner",
                plan: plan1,
                recentFold: d1Head)
            { window in
                window == plan1.chunks[1] ? d1Mid : d1Old
            }
        }
        await store.refreshProvider(.deepseek)
        await store.deepseekHistoryTask?.value
        #expect(store.snapshots[.deepseek]?.costUsage?.sessionTokens == 100)
        #expect(store.snapshots[.deepseek]?.detailRow(label: "Today")?.value == "$1.0000 · 100 tokens")

        // A transient poll after midnight must retire day 1's completed state and never show day 1 as "Today".
        clock.set(day2)
        let transientScope = try Self.makeTransientScope(profileID: "chrome:Default", digest: "digest-lifecycle-owner")
        store._test_providerFetchOutcomeOverride = { _ in
            Self.makeDeepSeekOutcome(
                balance: 7.25,
                updatedAt: day2,
                detailedUsageState: .unavailable,
                disposition: .transientOptionalDetailUnavailable(transientScope))
        }
        await store.refreshProvider(.deepseek)

        let transientSnapshot = try #require(store.snapshots[.deepseek])
        #expect(transientSnapshot.primary?.resetDescription?.contains("$7.25") == true)
        #expect(transientSnapshot.updatedAt == day2)
        #expect(transientSnapshot.costUsage == nil)
        #expect(transientSnapshot.detailRow(label: "Today") == nil)
        #expect(store.deepseekHistoryState == nil)

        // Defense-in-depth: attaching a prior-day summary to a newer snapshot dates the row instead of "Today".
        let crossDayAttached = Self.makeDeepSeekBalance(8.0, updatedAt: day2)
            .toUsageSnapshot()
            .withDeepSeekUsageSummary(d1Full)
        #expect(crossDayAttached.detailRow(label: "Today") == nil)
        #expect(crossDayAttached.detailRow(label: "2026-06-15")?.value == "$1.0000 · 100 tokens")
        #expect(crossDayAttached.detailRow(label: "Last 90 days")?.value == "$6.0000 · 600 tokens")

        // Non-UTC fixed offset rollover (UTC+9): same UTC day, next local Tokyo civil day.
        let tokyoDay1 = try #require(iso.date(from: "2026-06-15T14:55:00Z"))
        let tokyoDay2 = try #require(iso.date(from: "2026-06-15T15:05:00Z"))
        let tokyoPlan = try DeepSeekHistoryPlan.make(
            period: .rolling(days: 1),
            now: tokyoDay1,
            calendar: Self.calendar("Asia/Tokyo"))
        let tokyoFold = Self.makeFold(
            window: tokyoPlan.chunks[0],
            day: tokyoPlan.anchorDayKey,
            tokens: 40,
            cost: 0.4,
            req: 2)
        let tokyoSummary = DeepSeekUsageCostParser.mergeByAPIKeyChunks([tokyoFold], plan: tokyoPlan)
        let tokyoCrossDay = DeepSeekUsageSnapshot.detailSections(for: tokyoSummary, referenceDate: tokyoDay2)
        let tokyoRows = try #require(tokyoCrossDay.first { $0.title == "Usage" }?.rows)
        #expect(!tokyoRows.contains { $0.label == "Today" })
        #expect(tokyoRows.first { $0.label == "2026-06-15" }?.value == "$0.4000 · 40 tokens")
    }

    // MARK: - Off-main head projection, identical-head fast path, coalescing, and invalidation

    @Test
    func `identical 365-day head polls skip rebuild and widget saves while changed head projects off main`()
        async throws
    {
        let iso = ISO8601DateFormatter()
        let t0 = try #require(iso.date(from: "2026-06-15T12:00:00Z"))
        let t1 = t0.addingTimeInterval(60)
        let t2 = t0.addingTimeInterval(120)
        let t3 = t0.addingTimeInterval(180)
        let t4 = t0.addingTimeInterval(240)
        let utc = try Self.calendar("UTC")
        let plan0 = DeepSeekHistoryPlan.make(period: .rolling(days: 365), now: t0, calendar: utc)

        let store = self.makeStore(period: .rolling(days: 365), timeZoneIdentifier: "UTC")
        defer { store.stopSharedSpendDashboardPublication() }
        let clock = DeepSeekTestClockBox(t0)
        let widgetCounter = DeepSeekTestCounterBox()
        let projectionObserver = DeepSeekTestProjectionObserverBox()
        let olderFetchCounter = DeepSeekTestCounterBox()
        store._test_deepseekNowProvider = { clock.current }
        store._test_widgetSnapshotSaveOverride = { _ in await widgetCounter.increment() }
        store._test_deepseekProjectionObserver = { isMainThread in
            await projectionObserver.recordAndWaitIfPaused(isMainThread: isMainThread)
        }

        let headV1 = Self.makeFold(window: plan0.chunks[0], day: plan0.anchorDayKey, tokens: 100, cost: 1.0, req: 2)
        let fetchOlder: @Sendable (DeepSeekUsageWindow) async throws -> DeepSeekChunkFoldResult = { window in
            await olderFetchCounter.increment()
            return Self.makeChunkFold(window, tokens: 100, cost: 1.0, req: 2)
        }

        store._test_providerFetchOutcomeOverride = { _ in
            Self.makeWideOutcome(balance: 25.0, updatedAt: t0, plan: plan0, recentFold: headV1) { window in
                try await fetchOlder(window)
            }
        }
        await store.refreshProvider(.deepseek)
        await store.deepseekHistoryTask?.value
        await store.widgetSnapshotPersistTask?.value

        #expect(await olderFetchCounter.value == 12)
        #expect(await projectionObserver.callCount == 1)
        #expect(await projectionObserver.allOffMainThread == true)
        #expect(await widgetCounter.value == 1)
        #expect(store.snapshots[.deepseek]?.costUsage?.last30DaysTokens == 1300)
        #expect(store.snapshots[.deepseek]?.costUsage?.updatedAt == t0)

        // 3 consecutive routine polls with identical head fold and changing balances:
        // 0 merges/projections, 0 additional widget saves, fresh balance, honest t0 usage freshness.
        let identicalPolls: [(Date, Double, String)] = [
            (t1, 24.50, "$24.50"),
            (t2, 24.25, "$24.25"),
            (t3, 24.00, "$24.00"),
        ]
        for (tickTime, balance, formattedBalance) in identicalPolls {
            clock.set(tickTime)
            let tickPlan = DeepSeekHistoryPlan.make(period: .rolling(days: 365), now: tickTime, calendar: utc)
            store._test_providerFetchOutcomeOverride = { _ in
                Self.makeWideOutcome(
                    balance: balance,
                    updatedAt: tickTime,
                    plan: tickPlan,
                    recentFold: headV1)
                { window in
                    try await fetchOlder(window)
                }
            }
            await store.refreshProvider(.deepseek)
            await store.widgetSnapshotPersistTask?.value

            let snap = try #require(store.snapshots[.deepseek])
            #expect(store.deepseekHeadProjectionTask == nil)
            #expect(snap.primary?.resetDescription?.contains(formattedBalance) == true)
            #expect(snap.updatedAt == tickTime)
            #expect(snap.costUsage?.updatedAt == t0)
            #expect(snap.costUsage?.last30DaysTokens == 1300)
            #expect(snap.costUsage?.last30DaysCostUSD == 13.0)
            #expect(await projectionObserver.callCount == 1)
            #expect(await widgetCounter.value == 1)
            #expect(await olderFetchCounter.value == 12)
        }

        // Actual changed head poll returns immediately on MainActor and projects updated 365d totals off-main.
        clock.set(t4)
        let plan4 = DeepSeekHistoryPlan.make(period: .rolling(days: 365), now: t4, calendar: utc)
        let headV2 = Self.makeFold(window: plan4.chunks[0], day: plan4.anchorDayKey, tokens: 250, cost: 2.5, req: 5)
        await projectionObserver.armPause(onCallIndex: 2)
        store._test_providerFetchOutcomeOverride = { _ in
            Self.makeWideOutcome(balance: 23.50, updatedAt: t4, plan: plan4, recentFold: headV2) { window in
                try await fetchOlder(window)
            }
        }

        await store.refreshProvider(.deepseek)
        await projectionObserver.waitUntilPaused(callIndex: 2)
        #expect(store.deepseekHeadProjectionTask != nil)
        #expect(store.snapshots[.deepseek]?.primary?.resetDescription?.contains("$23.50") == true)
        #expect(store.snapshots[.deepseek]?.updatedAt == t4)
        #expect(store.snapshots[.deepseek]?.costUsage?.updatedAt == t0)
        #expect(store.snapshots[.deepseek]?.costUsage?.last30DaysTokens == 1300)

        await projectionObserver.releaseAll()
        await store.deepseekHeadProjectionTask?.value
        await store.widgetSnapshotPersistTask?.value

        let updated = try #require(store.snapshots[.deepseek])
        #expect(store.deepseekHeadProjectionTask == nil)
        #expect(await projectionObserver.callCount == 2)
        #expect(await projectionObserver.allOffMainThread == true)
        #expect(await widgetCounter.value == 2)
        #expect(await olderFetchCounter.value == 12)
        #expect(updated.primary?.resetDescription?.contains("$23.50") == true)
        #expect(updated.updatedAt == t4)
        #expect(updated.costUsage?.updatedAt == t4)
        #expect(updated.costUsage?.last30DaysTokens == 1450)
        #expect(updated.costUsage?.last30DaysCostUSD == 14.5)
        #expect(updated.costUsage?.last30DaysRequests == 29)
        #expect(updated.costUsage?.historyDays == 365)
        #expect(updated.costUsage?.historyScanIsPartial == false)
    }

    @Test
    func `overlapping changed heads coalesce off main and superseded projection never overwrites latest`()
        async throws
    {
        let iso = ISO8601DateFormatter()
        let t0 = try #require(iso.date(from: "2026-06-15T12:00:00Z"))
        let t1 = t0.addingTimeInterval(60)
        let t2 = t0.addingTimeInterval(120)
        let utc = try Self.calendar("UTC")
        let plan0 = DeepSeekHistoryPlan.make(period: .rolling(days: 365), now: t0, calendar: utc)
        let plan1 = DeepSeekHistoryPlan.make(period: .rolling(days: 365), now: t1, calendar: utc)
        let plan2 = DeepSeekHistoryPlan.make(period: .rolling(days: 365), now: t2, calendar: utc)

        let store = self.makeStore(period: .rolling(days: 365), timeZoneIdentifier: "UTC")
        defer { store.stopSharedSpendDashboardPublication() }
        let clock = DeepSeekTestClockBox(t0)
        let widgetCounter = DeepSeekTestCounterBox()
        let projectionObserver = DeepSeekTestProjectionObserverBox()
        store._test_deepseekNowProvider = { clock.current }
        store._test_widgetSnapshotSaveOverride = { _ in await widgetCounter.increment() }
        store._test_deepseekProjectionObserver = { isMainThread in
            await projectionObserver.recordAndWaitIfPaused(isMainThread: isMainThread)
        }

        let headV1 = Self.makeFold(window: plan0.chunks[0], day: plan0.anchorDayKey, tokens: 100, cost: 1.0, req: 2)
        let headV2 = Self.makeFold(window: plan1.chunks[0], day: plan1.anchorDayKey, tokens: 300, cost: 3.0, req: 6)
        let headV3 = Self.makeFold(window: plan2.chunks[0], day: plan2.anchorDayKey, tokens: 450, cost: 4.5, req: 9)

        store._test_providerFetchOutcomeOverride = { _ in
            Self.makeWideOutcome(balance: 25.0, updatedAt: t0, plan: plan0, recentFold: headV1) { window in
                Self.makeChunkFold(window, tokens: 100, cost: 1.0, req: 2)
            }
        }
        await store.refreshProvider(.deepseek)
        await store.deepseekHistoryTask?.value
        await store.widgetSnapshotPersistTask?.value
        #expect(await widgetCounter.value == 1)
        #expect(await projectionObserver.callCount == 1)

        // Pause head merge #1 in flight; send changed head #2 while #1 is still suspended.
        await projectionObserver.armPause(onCallIndex: 2)
        clock.set(t1)
        store._test_providerFetchOutcomeOverride = { _ in
            Self.makeWideOutcome(balance: 23.50, updatedAt: t1, plan: plan1, recentFold: headV2) { window in
                Self.makeChunkFold(window, tokens: 100, cost: 1.0, req: 2)
            }
        }
        await store.refreshProvider(.deepseek)
        await projectionObserver.waitUntilPaused(callIndex: 2)
        let task1 = try #require(store.deepseekHeadProjectionTask)

        clock.set(t2)
        store._test_providerFetchOutcomeOverride = { _ in
            Self.makeWideOutcome(balance: 23.00, updatedAt: t2, plan: plan2, recentFold: headV3) { window in
                Self.makeChunkFold(window, tokens: 100, cost: 1.0, req: 2)
            }
        }
        await store.refreshProvider(.deepseek)
        let task2 = try #require(store.deepseekHeadProjectionTask)
        await task2.value
        await store.widgetSnapshotPersistTask?.value

        #expect(store.snapshots[.deepseek]?.costUsage?.last30DaysTokens == 1650)
        #expect(store.snapshots[.deepseek]?.costUsage?.last30DaysCostUSD == 16.5)
        #expect(store.snapshots[.deepseek]?.costUsage?.updatedAt == t2)
        #expect(store.snapshots[.deepseek]?.primary?.resetDescription?.contains("$23.00") == true)
        #expect(await widgetCounter.value == 2)

        // Release superseded head #1; it must neither overwrite head #2 nor trigger an extra widget save.
        await projectionObserver.releaseAll()
        await task1.value
        await store.widgetSnapshotPersistTask?.value

        let finalSnapshot = try #require(store.snapshots[.deepseek])
        #expect(store.deepseekHeadProjectionTask == nil)
        #expect(finalSnapshot.costUsage?.last30DaysTokens == 1650)
        #expect(finalSnapshot.costUsage?.last30DaysCostUSD == 16.5)
        #expect(finalSnapshot.costUsage?.last30DaysRequests == 33)
        #expect(finalSnapshot.costUsage?.updatedAt == t2)
        #expect(finalSnapshot.primary?.resetDescription?.contains("$23.00") == true)
        #expect(await widgetCounter.value == 2)
        #expect(await projectionObserver.callCount == 3)
        #expect(await projectionObserver.allOffMainThread == true)
    }

    @Test
    func `newer head during active wide load projects strictly off main without double counting`() async throws {
        let iso = ISO8601DateFormatter()
        let t0 = try #require(iso.date(from: "2026-06-15T12:00:00Z"))
        let t1 = t0.addingTimeInterval(60)
        let utc = try Self.calendar("UTC")
        let plan0 = DeepSeekHistoryPlan.make(period: .rolling(days: 90), now: t0, calendar: utc)
        let plan1 = DeepSeekHistoryPlan.make(period: .rolling(days: 90), now: t1, calendar: utc)

        let store = self.makeStore(period: .rolling(days: 90), timeZoneIdentifier: "UTC")
        defer { store.stopSharedSpendDashboardPublication() }
        let clock = DeepSeekTestClockBox(t0)
        let chunkGate = DeepSeekTestChunkGate()
        let widgetCounter = DeepSeekTestCounterBox()
        let projectionObserver = DeepSeekTestProjectionObserverBox()
        store._test_deepseekNowProvider = { clock.current }
        store._test_widgetSnapshotSaveOverride = { _ in await widgetCounter.increment() }
        store._test_deepseekProjectionObserver = { isMainThread in
            await projectionObserver.recordAndWaitIfPaused(isMainThread: isMainThread)
        }

        let headV1 = Self.makeFold(window: plan0.chunks[0], day: plan0.anchorDayKey, tokens: 100, cost: 1.0, req: 2)
        let headV2 = Self.makeFold(window: plan1.chunks[0], day: plan1.anchorDayKey, tokens: 150, cost: 1.5, req: 3)
        let chunk1 = Self.makeChunkFold(plan0.chunks[1], tokens: 200, cost: 2.0, req: 4)
        let chunk2 = Self.makeChunkFold(plan0.chunks[2], tokens: 300, cost: 3.0, req: 6)

        store._test_providerFetchOutcomeOverride = { _ in
            Self.makeWideOutcome(balance: 10.0, updatedAt: t0, plan: plan0, recentFold: headV1) { window in
                await chunkGate.waitForRelease(window: window)
                return window == plan0.chunks[1] ? chunk1 : chunk2
            }
        }
        await store.refreshProvider(.deepseek)
        await chunkGate.waitUntilPaused(window: plan0.chunks[1])

        // Routine tick arrives with newer head while wide worker is paused on chunk 1.
        clock.set(t1)
        store._test_providerFetchOutcomeOverride = { _ in
            Self.makeWideOutcome(balance: 9.50, updatedAt: t1, plan: plan1, recentFold: headV2) { window in
                window == plan1.chunks[1] ? chunk1 : chunk2
            }
        }
        await store.refreshProvider(.deepseek)
        #expect(store.snapshots[.deepseek]?.primary?.resetDescription?.contains("$9.50") == true)

        await chunkGate.releaseAll()
        await store.deepseekHistoryTask?.value
        await store.deepseekHeadProjectionTask?.value
        await store.widgetSnapshotPersistTask?.value

        let finalSnapshot = try #require(store.snapshots[.deepseek])
        let finalCost = try #require(finalSnapshot.costUsage)
        #expect(store.deepseekHistoryTask == nil)
        #expect(store.deepseekHeadProjectionTask == nil)
        #expect(store.deepseekHistoryState?.activeScope == nil)
        #expect(store.deepseekHistoryState?.activeProjection == nil)
        #expect(finalSnapshot.primary?.resetDescription?.contains("$9.50") == true)
        #expect(finalSnapshot.updatedAt == t1)
        #expect(finalCost.updatedAt == t1)
        #expect(finalCost.last30DaysTokens == 650)
        #expect(finalCost.last30DaysCostUSD == 6.5)
        #expect(finalCost.last30DaysRequests == 13)
        #expect(finalCost.historyDays == 90)
        #expect(finalCost.historyScanIsPartial == false)
        #expect(await widgetCounter.value == 1)
        #expect(await projectionObserver.callCount == 2)
        #expect(await projectionObserver.allOffMainThread == true)
    }

    @Test(arguments: ["periodNarrowing", "optionalUsageOff"])
    func `scope invalidation during off-main head merge rejects stale projection and retires slot`(
        scenario: String) async throws
    {
        let iso = ISO8601DateFormatter()
        let t0 = try #require(iso.date(from: "2026-06-15T12:00:00Z"))
        let t1 = t0.addingTimeInterval(60)
        let utc = try Self.calendar("UTC")
        let plan0 = DeepSeekHistoryPlan.make(period: .rolling(days: 90), now: t0, calendar: utc)
        let plan1 = DeepSeekHistoryPlan.make(period: .rolling(days: 90), now: t1, calendar: utc)

        let store = self.makeStore(period: .rolling(days: 90), timeZoneIdentifier: "UTC")
        defer { store.stopSharedSpendDashboardPublication() }
        let clock = DeepSeekTestClockBox(t0)
        let widgetCounter = DeepSeekTestCounterBox()
        let projectionObserver = DeepSeekTestProjectionObserverBox()
        store._test_deepseekNowProvider = { clock.current }
        store._test_widgetSnapshotSaveOverride = { _ in await widgetCounter.increment() }
        store._test_deepseekProjectionObserver = { isMainThread in
            await projectionObserver.recordAndWaitIfPaused(isMainThread: isMainThread)
        }

        let headV1 = Self.makeFold(window: plan0.chunks[0], day: plan0.anchorDayKey, tokens: 100, cost: 1.0, req: 2)
        let headV2 = Self.makeFold(window: plan1.chunks[0], day: plan1.anchorDayKey, tokens: 999, cost: 9.99, req: 9)
        let chunk1 = Self.makeChunkFold(plan0.chunks[1], tokens: 200, cost: 2.0, req: 4)
        let chunk2 = Self.makeChunkFold(plan0.chunks[2], tokens: 300, cost: 3.0, req: 6)

        store._test_providerFetchOutcomeOverride = { _ in
            Self.makeWideOutcome(balance: 10.0, updatedAt: t0, plan: plan0, recentFold: headV1) { window in
                window == plan0.chunks[1] ? chunk1 : chunk2
            }
        }
        await store.refreshProvider(.deepseek)
        await store.deepseekHistoryTask?.value
        await store.widgetSnapshotPersistTask?.value
        #expect(store.snapshots[.deepseek]?.costUsage?.last30DaysTokens == 600)
        #expect(await widgetCounter.value == 1)

        // Pause head merge #2 off-main and invalidate scope before releasing it.
        await projectionObserver.armPause(onCallIndex: 2)
        clock.set(t1)
        store._test_providerFetchOutcomeOverride = { _ in
            Self.makeWideOutcome(balance: 9.25, updatedAt: t1, plan: plan1, recentFold: headV2) { window in
                window == plan1.chunks[1] ? chunk1 : chunk2
            }
        }
        await store.refreshProvider(.deepseek)
        await projectionObserver.waitUntilPaused(callIndex: 2)
        let headTask = try #require(store.deepseekHeadProjectionTask)

        switch scenario {
        case "periodNarrowing":
            store.settings.costReportingPeriod = .rolling(days: 7)
        case "optionalUsageOff":
            store.settings.showOptionalCreditsAndExtraUsage = false
        default:
            Issue.record("Unexpected scenario \(scenario)")
        }

        await projectionObserver.releaseAll()
        await headTask.value
        await store.widgetSnapshotPersistTask?.value

        #expect(store.deepseekHeadProjectionTask == nil)
        #expect(store.snapshots[.deepseek]?.costUsage?.last30DaysTokens == 600)
        #expect(store.snapshots[.deepseek]?.costUsage?.updatedAt == t0)
        #expect(await widgetCounter.value == 1)
        #expect(await projectionObserver.allOffMainThread == true)

        if scenario == "periodNarrowing" {
            // Short 7-day window uses snapshot's existing off-main projection with zero extra store rebuilds.
            let plan7 = DeepSeekHistoryPlan.make(period: .rolling(days: 7), now: t1, calendar: utc)
            let fold7 = Self.makeFold(window: plan7.chunks[0], day: plan7.anchorDayKey, tokens: 40, cost: 0.4, req: 1)
            let callsBeforeShort = await projectionObserver.callCount
            store._test_providerFetchOutcomeOverride = { _ in
                Self.makeWideOutcome(balance: 9.25, updatedAt: t1, plan: plan7, recentFold: fold7) { _ in fold7 }
            }
            await store.refreshProvider(.deepseek)
            #expect(await projectionObserver.callCount == callsBeforeShort)
            #expect(store.snapshots[.deepseek]?.costUsage?.historyDays == 7)
            #expect(store.snapshots[.deepseek]?.costUsage?.last30DaysTokens == 40)
        } else {
            // Re-enabling optional usage recovers the previously aborted headV2 cleanly off-main.
            store.settings.showOptionalCreditsAndExtraUsage = true
            await store.refreshProvider(.deepseek)
            await store.deepseekHeadProjectionTask?.value
            #expect(store.deepseekHeadProjectionTask == nil)
            #expect(store.snapshots[.deepseek]?.costUsage?.last30DaysTokens == 1499)
            #expect(store.snapshots[.deepseek]?.costUsage?.updatedAt == t1)
            #expect(await projectionObserver.allOffMainThread == true)
        }
    }

    // MARK: - Midnight rollover fold reuse with real JSON payloads

    private struct DeepSeekRolloverFixture: Sendable {
        let timeZoneSeconds: Int
        let expiredSpikeDayKey: String
        let day2OnlyDayKey: String
        let extraDay2Tokens: Int

        init(
            timeZoneSeconds: Int = 0,
            expiredSpikeDayKey: String,
            day2OnlyDayKey: String,
            extraDay2Tokens: Int = 0)
        {
            self.timeZoneSeconds = timeZoneSeconds
            self.expiredSpikeDayKey = expiredSpikeDayKey
            self.day2OnlyDayKey = day2OnlyDayKey
            self.extraDay2Tokens = extraDay2Tokens
        }

        private var fixedCalendar: Calendar {
            CostUsageLocalDay.fixedOffsetGregorianCalendar(secondsFromGMT: self.timeZoneSeconds)
        }

        func makeTransport(
            statusOverride: DeepSeekTestScriptedTransport.StatusOverride? = nil) -> DeepSeekTestScriptedTransport
        {
            let fixture = self
            return DeepSeekTestScriptedTransport(statusOverride: statusOverride) { url, start, end in
                fixture.body(isAmount: url.path.hasSuffix("/amount"), start: start, end: end)
            }
        }

        func fetchFresh365(now: Date, calendar: Calendar) async throws -> DeepSeekUsageSummary {
            try await DeepSeekUsageFetcher.fetchUsageSummary(
                platformToken: "synthetic-rollover-token",
                period: .rolling(days: 365),
                now: now,
                localCalendar: calendar,
                transport: self.makeTransport())
        }

        private func body(isAmount: Bool, start: Int, end: Int) -> Data {
            let calendar = self.fixedCalendar
            let dayCount = max(0, (end - start) / 86400)
            // Include out-of-window decoy buckets to verify strict [start, end) boundary exclusion.
            var chatAmount: [(time: Int, tokens: Int, requests: Int)] = [
                (start - 1, 999_999, 999),
                (end, 888_888, 888),
            ]
            var reasonerAmount: [(time: Int, tokens: Int, requests: Int)] = []
            var expiredOnly: [(time: Int, tokens: Int, requests: Int)] = []
            var day2Only: [(time: Int, tokens: Int, requests: Int)] = []
            var functionBuckets: [(time: Int, calls: Int)] = [(end, 777)]
            var chatCost: [(time: Int, cost: String)] = [(end, "999.99")]
            var reasonerCost: [(time: Int, cost: String)] = []
            var cnyDecoy: [(time: Int, cost: String)] = []

            for offset in 0..<dayCount {
                let dayStart = start + offset * 86400
                let bucketTime = dayStart + 43200
                let dayKey = CostUsageLocalDay.key(
                    from: Date(timeIntervalSince1970: TimeInterval(dayStart)),
                    calendar: calendar)
                let ordinal = abs(dayStart / 86400) % 17 + 1
                let chatTokens = 200 + ordinal * 10 + (dayKey == self.day2OnlyDayKey ? self.extraDay2Tokens : 0)
                chatAmount.append((bucketTime, chatTokens, 2 + (ordinal % 3)))
                chatCost.append((bucketTime, String(format: "%.2f", Double(ordinal) * 0.05)))
                cnyDecoy.append((bucketTime, "0.01"))
                functionBuckets.append((bucketTime, 1 + (ordinal % 2)))

                if dayKey == self.expiredSpikeDayKey {
                    // Large Day 1 oldest-day spike makes Day 1 topModel deepseek-reasoner; Day 2 flips to chat.
                    reasonerAmount.append((bucketTime, 400_000, 15))
                    reasonerCost.append((bucketTime, "12.50"))
                    expiredOnly.append((bucketTime, 50, 1))
                } else if dayKey == self.day2OnlyDayKey {
                    day2Only.append((bucketTime, 300 + self.extraDay2Tokens, 4))
                    reasonerAmount.append((bucketTime, 50, 1))
                    reasonerCost.append((bucketTime, "0.10"))
                } else {
                    reasonerAmount.append((bucketTime, 50 + ordinal, 1))
                    reasonerCost.append((bucketTime, "0.02"))
                }
            }

            if isAmount {
                var series: [[String: Any]] = [
                    Self.amt("key-shared", "deepseek-chat", chatAmount),
                    Self.amt("key-reasoner", "deepseek-reasoner", reasonerAmount),
                ]
                if !expiredOnly.isEmpty {
                    series.append(Self.amt("key-expired-only", "deepseek-reasoner", expiredOnly))
                }
                if !day2Only.isEmpty {
                    series.append(Self.amt("key-day2-only", "deepseek-chat", day2Only))
                }
                return DeepSeekLongHistoryTests.amountJSON(series: series, functionBuckets: functionBuckets)
            }
            let usd = [
                Self.cst("key-shared", "deepseek-chat", chatCost),
                Self.cst("key-reasoner", "deepseek-reasoner", reasonerCost),
            ]
            let cny = [Self.cst("key-shared", "deepseek-chat", cnyDecoy)]
            return DeepSeekLongHistoryTests.costJSON(blocks: [("CNY", cny), ("USD", usd)])
        }

        private static func amt(
            _ keyID: String,
            _ model: String,
            _ buckets: [(time: Int, tokens: Int, requests: Int)]) -> [String: Any]
        {
            DeepSeekLongHistoryTests.amountSeries(keyID: keyID, model: model, buckets: buckets)
        }

        private static func cst(
            _ keyID: String,
            _ model: String,
            _ buckets: [(time: Int, cost: String)]) -> [String: Any]
        {
            DeepSeekLongHistoryTests.costSeries(keyID: keyID, model: model, buckets: buckets)
        }
    }

    private func refreshRollover(
        _ store: UsageStore,
        now: Date,
        calendar: Calendar,
        balance: Double = 39.0,
        transport: DeepSeekTestScriptedTransport,
        gate: DeepSeekTestChunkGate? = nil,
        interaction: ProviderInteraction = .background) async
    {
        store._test_providerFetchOutcomeOverride = { _ in
            do {
                let recent = try await DeepSeekUsageFetcher.fetchRecentUsageSummary(
                    platformToken: "synthetic-rollover-token",
                    profileID: "chrome:Default",
                    period: .rolling(days: 365),
                    now: now,
                    localCalendar: calendar,
                    transport: transport)
                let continuation: DeepSeekWideHistoryContinuation? = if let base = recent.continuation, let gate {
                    DeepSeekWideHistoryContinuation(metadata: base.metadata) { window in
                        await gate.waitForRelease(window: window)
                        return try await base.fetchChunk(window)
                    }
                } else {
                    recent.continuation
                }
                return Self.makeDeepSeekOutcome(
                    balance: balance,
                    updatedAt: now,
                    summary: recent.summary,
                    continuation: continuation)
            } catch {
                return ProviderFetchOutcome(result: .failure(error), attempts: [])
            }
        }
        await ProviderInteractionContext.$current.withValue(interaction) {
            await store.refreshProvider(.deepseek)
        }
    }

    private static func assertSnapshotMatchesFresh(
        _ snapshot: UsageSnapshot?,
        expectedSummary: DeepSeekUsageSummary,
        calendar: Calendar) throws
    {
        let snapshot = try #require(snapshot)
        let expectedCost = expectedSummary.toCostUsageTokenSnapshot(calendar: calendar)
        let actualCost = try #require(snapshot.costUsage)
        #expect(actualCost.last30DaysTokens == expectedCost.last30DaysTokens)
        #expect(actualCost.last30DaysRequests == expectedCost.last30DaysRequests)
        #expect(actualCost.sessionTokens == expectedCost.sessionTokens)
        #expect(actualCost.sessionRequests == expectedCost.sessionRequests)
        #expect(actualCost.currencyCode == expectedCost.currencyCode)
        #expect(actualCost.historyDays == expectedCost.historyDays)
        #expect(actualCost.historyScanIsPartial == expectedCost.historyScanIsPartial)
        #expect(actualCost.historyLabel == expectedCost.historyLabel)
        #expect(actualCost.coveredDayIntervals == expectedCost.coveredDayIntervals)
        #expect(actualCost.daily.count == expectedCost.daily.count)
        #expect(Set(actualCost.daily.map(\.date)).count == actualCost.daily.count)
        #expect(try abs(#require(actualCost.last30DaysCostUSD) - #require(expectedCost.last30DaysCostUSD)) < 1e-9)
        #expect(try abs(#require(actualCost.sessionCostUSD) - #require(expectedCost.sessionCostUSD)) < 1e-9)
        #expect(snapshot.detailRow(label: "Top model")?.value == expectedSummary.topModel)
        #expect(snapshot.detailRow(label: "API keys")?.value == "\(expectedSummary.apiKeyCount)")
        #expect(snapshot.detailRow(label: "Requests")?.value == "\(expectedSummary.currentMonthRequestCount)")
    }

    @Test
    func `365-day midnight rollover reuses 11 real-JSON chunks, matches fresh fetch, and keeps day-2 ticks cheap`()
        async throws
    {
        let iso = ISO8601DateFormatter()
        let day1 = try #require(iso.date(from: "2026-06-15T23:55:00Z"))
        let day2 = try #require(iso.date(from: "2026-06-16T00:05:00Z"))
        let utc = try Self.calendar("UTC")
        let plan1 = DeepSeekHistoryPlan.make(period: .rolling(days: 365), now: day1, calendar: utc)
        let plan2 = DeepSeekHistoryPlan.make(period: .rolling(days: 365), now: day2, calendar: utc)
        let adapted2 = plan2.adaptingToReusableWindows(Set(plan1.chunks))
        let fixture = DeepSeekRolloverFixture(
            expiredSpikeDayKey: plan1.requestedStartDayKey,
            day2OnlyDayKey: plan2.anchorDayKey)

        let store = self.makeStore(period: .rolling(days: 365), timeZoneIdentifier: "UTC")
        defer { store.stopSharedSpendDashboardPublication() }
        let clock = DeepSeekTestClockBox(day1)
        let widgetSaves = DeepSeekTestCounterBox()
        let observer = DeepSeekTestProjectionObserverBox()
        store._test_deepseekNowProvider = { clock.current }
        store._test_widgetSnapshotSaveOverride = { _ in await widgetSaves.increment() }
        store._test_deepseekProjectionObserver = { await observer.recordAndWaitIfPaused(isMainThread: $0) }

        // 1. Cold Day 1 (365d): 13 pairs = 26 HTTP requests (2 recent + 24 older).
        let day1Transport = fixture.makeTransport()
        await self.refreshRollover(store, now: day1, calendar: utc, balance: 40.0, transport: day1Transport)
        await store.deepseekHistoryTask?.value
        await store.widgetSnapshotPersistTask?.value

        #expect(await day1Transport.requests.count == 26 && store.deepseekHistoryState?.chunksByWindow.count == 13)
        let freshDay1 = try await fixture.fetchFresh365(now: day1, calendar: utc)
        #expect(freshDay1.topModel == "deepseek-reasoner" && freshDay1.apiKeyCount == 3)
        try Self.assertSnapshotMatchesFresh(store.snapshots[.deepseek], expectedSummary: freshDay1, calendar: utc)

        // 2. Day 1 -> Day 2 rollover: immediate I02 Day-2 Today + partial 30/365, then only 2 older pairs (4 reqs).
        clock.set(day2)
        let day2Gate = DeepSeekTestChunkGate()
        let day2Transport = fixture.makeTransport()
        await self.refreshRollover(
            store,
            now: day2,
            calendar: utc,
            balance: 38.5,
            transport: day2Transport,
            gate: day2Gate)
        await day2Gate.waitUntilPaused(window: adapted2.chunks[1])

        let pausedSnap = try #require(store.snapshots[.deepseek])
        let freshDay2 = try await fixture.fetchFresh365(now: day2, calendar: utc)
        #expect(pausedSnap.costUsage?.historyLabel == "Last 30 of 365 days")
        #expect(pausedSnap.costUsage?.sessionTokens == freshDay2.todayTokens)
        #expect(pausedSnap.costUsage?.sessionRequests == freshDay2.requestCount)
        #expect(pausedSnap.detailRow(label: "Today") != nil && store.deepseekHistoryState?.completedScope == nil)

        // Coalesced second Day 2 tick while paused must not duplicate older work.
        let coalescedTransport = fixture.makeTransport()
        await self.refreshRollover(store, now: day2, calendar: utc, balance: 38.5, transport: coalescedTransport)
        #expect(await coalescedTransport.requests.count == 2)

        await day2Gate.releaseAll()
        await store.deepseekHistoryTask?.value
        await store.widgetSnapshotPersistTask?.value

        // Day 2 executed 2 recent + 4 older HTTP requests (1d bridge + 4d tail) and reused all 11 x 30d chunks!
        #expect(await day2Transport.requests.count == 6 && store.deepseekHistoryState?.chunksByWindow.count == 14)
        #expect(freshDay2.topModel == "deepseek-chat" && freshDay2.apiKeyCount == 3)
        #expect(store.snapshots[.deepseek]?.costUsage?.daily
            .contains { $0.date == plan1.requestedStartDayKey } == false)
        try Self.assertSnapshotMatchesFresh(store.snapshots[.deepseek], expectedSummary: freshDay2, calendar: utc)

        // 3. Subsequent Day 2 identical-head tick: 0 older reqs, 0 projections, 0 widget saves.
        let projectionsAfterDay2 = await observer.callCount
        let widgetSavesAfterDay2 = await widgetSaves.value
        let day2Tick1 = day2.addingTimeInterval(60)
        clock.set(day2Tick1)
        let identicalTransport = fixture.makeTransport()
        await self.refreshRollover(store, now: day2Tick1, calendar: utc, balance: 38.0, transport: identicalTransport)
        await store.widgetSnapshotPersistTask?.value
        #expect(await identicalTransport.requests.count == 2)
        #expect(await observer.callCount == projectionsAfterDay2)
        #expect(await widgetSaves.value == widgetSavesAfterDay2)
        #expect(store.snapshots[.deepseek]?.primary?.resetDescription?.contains("$38.00") == true)

        // 4. Subsequent Day 2 changed-head tick: 0 older reqs, off-main merge preserves all 14 adapted chunks.
        let day2Tick2 = day2.addingTimeInterval(120)
        clock.set(day2Tick2)
        let updatedFixture = DeepSeekRolloverFixture(
            expiredSpikeDayKey: plan1.requestedStartDayKey,
            day2OnlyDayKey: plan2.anchorDayKey,
            extraDay2Tokens: 1200)
        let changedHeadTransport = updatedFixture.makeTransport()
        await self.refreshRollover(store, now: day2Tick2, calendar: utc, balance: 37.5, transport: changedHeadTransport)
        await store.deepseekHeadProjectionTask?.value
        await store.widgetSnapshotPersistTask?.value

        #expect(await changedHeadTransport.requests.count == 2)
        #expect(store.deepseekHistoryState?.chunksByWindow.count == 14)
        #expect(await observer.callCount == projectionsAfterDay2 + 1)
        #expect(await observer.allOffMainThread == true)
        let freshDay2Updated = try await updatedFixture.fetchFresh365(now: day2Tick2, calendar: utc)
        try Self.assertSnapshotMatchesFresh(
            store.snapshots[.deepseek],
            expectedSummary: freshDay2Updated,
            calendar: utc)
    }

    @Test
    func `day-2 bridge 503 stays 364 of 365 across routine ticks and explicit reload retries only the bridge pair`()
        async throws
    {
        let iso = ISO8601DateFormatter()
        let day1 = try #require(iso.date(from: "2026-06-15T23:55:00Z"))
        let day2 = try #require(iso.date(from: "2026-06-16T00:05:00Z"))
        let utc = try Self.calendar("UTC")
        let plan1 = DeepSeekHistoryPlan.make(period: .rolling(days: 365), now: day1, calendar: utc)
        let plan2 = DeepSeekHistoryPlan.make(period: .rolling(days: 365), now: day2, calendar: utc)
        let bridgeWindow = plan2.adaptingToReusableWindows(Set(plan1.chunks)).chunks[1]
        let fixture = DeepSeekRolloverFixture(
            expiredSpikeDayKey: plan1.requestedStartDayKey,
            day2OnlyDayKey: plan2.anchorDayKey)

        let store = self.makeStore(period: .rolling(days: 365), timeZoneIdentifier: "UTC")
        defer { store.stopSharedSpendDashboardPublication() }
        let clock = DeepSeekTestClockBox(day1)
        store._test_deepseekNowProvider = { clock.current }

        await self.refreshRollover(store, now: day1, calendar: utc, transport: fixture.makeTransport())
        await store.deepseekHistoryTask?.value

        // Day 2 rollover with HTTP 503 on 1d bridge: 4 older requests (bridge fails, tail succeeds, 11x30d reused).
        clock.set(day2)
        let partialTransport = fixture.makeTransport { _, start, end in
            start == bridgeWindow.startSeconds && end == bridgeWindow.endSeconds ? 503 : 200
        }
        await self.refreshRollover(store, now: day2, calendar: utc, transport: partialTransport)
        await store.deepseekHistoryTask?.value

        #expect(await partialTransport.requests.count == 6) // 2 recent + 2 failed bridge + 2 tail
        let partialCost = try #require(store.snapshots[.deepseek]?.costUsage)
        #expect(partialCost.historyLabel == "Last 364 of 365 days" && partialCost.historyScanIsPartial == true)
        #expect(partialCost.coveredDayIntervals?.count == 2)
        #expect(partialCost.daily.contains { $0.date == bridgeWindow.startDayKey } == false)

        // Routine background tick must NOT retry the failed bridge.
        let routineTransport = fixture.makeTransport()
        await self.refreshRollover(store, now: day2.addingTimeInterval(60), calendar: utc, transport: routineTransport)
        await store.deepseekHistoryTask?.value
        #expect(await routineTransport.requests.count == 2)
        #expect(store.snapshots[.deepseek]?.costUsage?.historyLabel == "Last 364 of 365 days")

        // Explicit reload retries ONLY the 1 failed bridge pair (2 older HTTP requests) and completes 365/365.
        let retryNow = day2.addingTimeInterval(120)
        clock.set(retryNow)
        let retryTransport = fixture.makeTransport()
        await self.refreshRollover(
            store,
            now: retryNow,
            calendar: utc,
            transport: retryTransport,
            interaction: .userInitiated)
        await store.deepseekHistoryTask?.value

        #expect(await retryTransport.requests.count == 4) // 2 recent + 2 bridge only (tail + 11x30d reused!)
        let freshDay2 = try await fixture.fetchFresh365(now: retryNow, calendar: utc)
        try Self.assertSnapshotMatchesFresh(store.snapshots[.deepseek], expectedSummary: freshDay2, calendar: utc)
    }

    @Test(arguments: [401, 429])
    func `day-2 rollover auth or rate limit on bridge stops immediately without touching tail`(
        statusCode: Int) async throws
    {
        let iso = ISO8601DateFormatter()
        let day1 = try #require(iso.date(from: "2026-06-15T23:55:00Z"))
        let day2 = try #require(iso.date(from: "2026-06-16T00:05:00Z"))
        let utc = try Self.calendar("UTC")
        let plan1 = DeepSeekHistoryPlan.make(period: .rolling(days: 365), now: day1, calendar: utc)
        let plan2 = DeepSeekHistoryPlan.make(period: .rolling(days: 365), now: day2, calendar: utc)
        let adapted2 = plan2.adaptingToReusableWindows(Set(plan1.chunks))
        let bridgeWindow = adapted2.chunks[1]
        let tailWindow = try #require(adapted2.chunks.last)
        let fixture = DeepSeekRolloverFixture(
            expiredSpikeDayKey: plan1.requestedStartDayKey,
            day2OnlyDayKey: plan2.anchorDayKey)

        let store = self.makeStore(period: .rolling(days: 365), timeZoneIdentifier: "UTC")
        defer { store.stopSharedSpendDashboardPublication() }
        let clock = DeepSeekTestClockBox(day1)
        store._test_deepseekNowProvider = { clock.current }

        await self.refreshRollover(store, now: day1, calendar: utc, transport: fixture.makeTransport())
        await store.deepseekHistoryTask?.value

        clock.set(day2)
        let stopTransport = fixture.makeTransport { _, start, end in
            start == bridgeWindow.startSeconds && end == bridgeWindow.endSeconds ? statusCode : 200
        }
        await self.refreshRollover(store, now: day2, calendar: utc, transport: stopTransport)
        await store.deepseekHistoryTask?.value

        let requests = await stopTransport.requests
        // 2 recent + 2 failed bridge = 4 total; tail is never requested, and unvisited 30d chunks are excluded.
        #expect(requests.count == 4)
        for request in requests {
            #expect(try #require(Self.query(request)["start"].flatMap(Int.init)) != tailWindow.startSeconds)
        }
        let cost = try #require(store.snapshots[.deepseek]?.costUsage)
        #expect(cost.historyLabel == "Last 30 of 365 days" && cost.historyScanIsPartial == true)
        #expect(cost.coveredDayIntervals == [
            CostUsageDayInterval(startDay: plan2.chunks[0].startDayKey, endDay: plan2.chunks[0].endDayKey),
        ])
    }

    @Test(arguments: ["dstTransition", "zoneSwitch"])
    func `timezone offset change across midnight clears cached folds and fetches fresh 365-day windows`(
        scenario: String) async throws
    {
        let iso = ISO8601DateFormatter()
        let isDST = scenario == "dstTransition"
        // US spring-forward DST transition in America/Los_Angeles: PST (-28800) -> PDT (-25200).
        let day1 = try #require(iso.date(from: isDST ? "2026-03-08T07:30:00Z" : "2026-06-15T23:55:00Z"))
        let day2 = try #require(iso.date(from: isDST ? "2026-03-09T07:30:00Z" : "2026-06-16T00:05:00Z"))
        let zone1ID = isDST ? "America/Los_Angeles" : "UTC"
        let zone2ID = isDST ? "America/Los_Angeles" : "Asia/Tokyo"
        let cal1 = try Self.calendar(zone1ID)
        let cal2 = try Self.calendar(zone2ID)
        let plan1 = DeepSeekHistoryPlan.make(period: .rolling(days: 365), now: day1, calendar: cal1)
        let plan2 = DeepSeekHistoryPlan.make(period: .rolling(days: 365), now: day2, calendar: cal2)
        #expect(plan1.timeZoneSeconds != plan2.timeZoneSeconds)

        let fixture1 = DeepSeekRolloverFixture(
            timeZoneSeconds: plan1.timeZoneSeconds,
            expiredSpikeDayKey: plan1.requestedStartDayKey,
            day2OnlyDayKey: plan2.anchorDayKey)
        let fixture2 = DeepSeekRolloverFixture(
            timeZoneSeconds: plan2.timeZoneSeconds,
            expiredSpikeDayKey: plan1.requestedStartDayKey,
            day2OnlyDayKey: plan2.anchorDayKey)

        let store = self.makeStore(period: .rolling(days: 365), timeZoneIdentifier: zone1ID)
        defer { store.stopSharedSpendDashboardPublication() }
        let clock = DeepSeekTestClockBox(day1)
        store._test_deepseekNowProvider = { clock.current }

        await self.refreshRollover(store, now: day1, calendar: cal1, transport: fixture1.makeTransport())
        await store.deepseekHistoryTask?.value
        #expect(store.deepseekHistoryState?.chunksByWindow.count == 13)

        clock.set(day2)
        store.settings.costUsageBucketTimeZoneIdentifier = zone2ID
        let day2Transport = fixture2.makeTransport()
        await self.refreshRollover(store, now: day2, calendar: cal2, transport: day2Transport)
        await store.deepseekHistoryTask?.value

        // Zero old-offset reuse: full 13 pairs = 26 requests fetched in the new UTC offset.
        #expect(await day2Transport.requests.count == 26 && store.deepseekHistoryState?.chunksByWindow.count == 13)
        #expect(store.deepseekHistoryState?.chunksTimeZoneSeconds == plan2.timeZoneSeconds)
        let freshDay2 = try await fixture2.fetchFresh365(now: day2, calendar: cal2)
        try Self.assertSnapshotMatchesFresh(store.snapshots[.deepseek], expectedSummary: freshDay2, calendar: cal2)
    }

    @Test
    func `consecutive 365-day midnight rollovers stay bounded at most 14 chunks and match fresh day-6 totals`()
        async throws
    {
        let day1 = try #require(ISO8601DateFormatter().date(from: "2026-06-15T12:00:00Z"))
        let utc = try Self.calendar("UTC")
        let plan1 = DeepSeekHistoryPlan.make(period: .rolling(days: 365), now: day1, calendar: utc)
        let day6 = day1.addingTimeInterval(5 * 86400)
        let plan6 = DeepSeekHistoryPlan.make(period: .rolling(days: 365), now: day6, calendar: utc)
        let fixture = DeepSeekRolloverFixture(
            expiredSpikeDayKey: plan1.requestedStartDayKey,
            day2OnlyDayKey: plan6.anchorDayKey)

        let store = self.makeStore(period: .rolling(days: 365), timeZoneIdentifier: "UTC")
        defer { store.stopSharedSpendDashboardPublication() }
        let clock = DeepSeekTestClockBox(day1)
        store._test_deepseekNowProvider = { clock.current }

        var totalRequestsPerDay: [Int] = []
        for dayOffset in 0..<6 {
            let currentNow = day1.addingTimeInterval(Double(dayOffset) * 86400)
            clock.set(currentNow)
            if dayOffset == 2 {
                // Token refresh after midnight before provider poll retires Day 2 scope without wiping reuse.
                await store.refreshTokenUsage(.deepseek, force: false)
                #expect(store.deepseekHistoryState?.completedScope == nil)
            }
            let transport = fixture.makeTransport()
            await self.refreshRollover(store, now: currentNow, calendar: utc, transport: transport)
            await store.deepseekHistoryTask?.value

            await totalRequestsPerDay.append(transport.requests.count)
            #expect(try #require(store.deepseekHistoryState?.chunksByWindow.count) <= 14)
        }

        // Total HTTP requests (including 2 recent): Day 1 = 26 (24 older), Day 2..5 = 6 (4 older), Day 6 = 4 (2 older)!
        #expect(totalRequestsPerDay == [26, 6, 6, 6, 6, 4])
        #expect(store.deepseekHistoryState?.chunksByWindow.count == 13)

        let freshDay6 = try await fixture.fetchFresh365(now: day6, calendar: utc)
        try Self.assertSnapshotMatchesFresh(store.snapshots[.deepseek], expectedSummary: freshDay6, calendar: utc)
    }
}

actor DeepSeekTestProjectionObserverBox {
    private(set) var calls: [Bool] = []
    private var armedPauseCallIndex: Int?
    private var pausedCallIndices: Set<Int> = []
    private var pauseWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    var callCount: Int {
        self.calls.count
    }

    var allOffMainThread: Bool {
        !self.calls.isEmpty && self.calls.allSatisfy { !$0 }
    }

    func armPause(onCallIndex index: Int) {
        self.armedPauseCallIndex = index
    }

    func recordAndWaitIfPaused(isMainThread: Bool) async {
        self.calls.append(isMainThread)
        let currentIndex = self.calls.count
        guard self.armedPauseCallIndex == currentIndex else { return }
        self.pausedCallIndices.insert(currentIndex)
        for waiter in self.pauseWaiters.removeValue(forKey: currentIndex) ?? [] {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            self.releaseWaiters.append(continuation)
        }
    }

    func waitUntilPaused(callIndex: Int) async {
        if self.pausedCallIndices.contains(callIndex) { return }
        await withCheckedContinuation { continuation in
            self.pauseWaiters[callIndex, default: []].append(continuation)
        }
    }

    func releaseAll() {
        self.armedPauseCallIndex = nil
        let waiters = self.releaseWaiters
        self.releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}
