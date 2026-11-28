import Foundation
import os
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
extension DeepSeekLongHistoryTests {
    // MARK: - Production-seam UsageStore pagination tests (scripted HTTP -> fetcher -> unified pager -> store)

    private func refreshThroughProductionSeam(
        _ store: UsageStore,
        now: Date,
        balance: Double = 10.0,
        apiKey: String = "sk-prod-seam-test",
        sessionToken: String = "synthetic-prod-seam-token",
        transport: DeepSeekTestScriptedTransport,
        interaction: ProviderInteraction = .background) async throws
    {
        let period = store.settings.costReportingPeriod
        let timeZoneID = store.settings.costUsageBucketTimeZoneIdentifier
        let scope = try #require(DeepSeekSettingsReader.profileScope(selectedTokenAccountID: nil, apiKey: apiKey))
        let detection = BrowserDetection(homeDirectory: "/nonexistent/deepseek-prod-seam", cacheTTL: 0)
        let context = ProviderFetchContext(
            runtime: .app,
            sourceMode: .api,
            includeCredits: false,
            includeOptionalUsage: store.settings.showOptionalCreditsAndExtraUsage,
            webTimeout: 60,
            webDebugDumpHTML: false,
            verbose: false,
            env: [
                DeepSeekSettingsReader.platformTokenEnvironmentKey: sessionToken,
                DeepSeekSettingsReader.profileScopeEnvironmentKey: scope,
            ],
            settings: nil,
            fetcher: UsageFetcher(environment: [:]),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: detection),
            browserDetection: detection,
            costReportingPeriod: period,
            costUsageBucketTimeZoneIdentifier: timeZoneID)
        let operations = DeepSeekProviderDescriptor.FetchOperations(
            fetchUsage: { _, platformToken, includeOptional, requestedPeriod, requestedTimeZoneID in
                let recent: DeepSeekUsageFetcher.RecentUsageFetchResult? = if includeOptional, let platformToken {
                    try await DeepSeekUsageFetcher.fetchRecentUsageSummary(
                        platformToken: platformToken,
                        profileID: nil,
                        period: requestedPeriod,
                        now: now,
                        localCalendar: DeepSeekUsageFetcher.resolvedCalendar(
                            bucketTimeZoneIdentifier: requestedTimeZoneID),
                        transport: transport)
                } else {
                    nil
                }
                return DeepSeekUsageSnapshot(
                    isAvailable: true,
                    currency: "USD",
                    totalBalance: balance,
                    grantedBalance: 0,
                    toppedUpBalance: balance,
                    usageSummary: recent?.summary,
                    detailedUsageState: includeOptional ? (recent == nil ? .unavailable : .available) : .notRequested,
                    historyContinuation: recent?.continuation,
                    updatedAt: now)
            },
            fetchPlatformUsage: { _, _, _, _ in
                throw DeepSeekUsageError.apiError("Unexpected platform fetch")
            },
            resolveAutomaticSession: { _ in
                DeepSeekPlatformTokenImporter.Resolution(
                    profiles: [],
                    selectedSummary: nil,
                    detailedUsageState: .unavailable)
            })
        store._test_providerFetchOutcomeOverride = { _ in
            do {
                let result = try await DeepSeekProviderDescriptor._loadUsageResultForTesting(
                    apiKey: apiKey,
                    context: context,
                    optionalResolutionJoinGrace: .seconds(1),
                    operations: operations)
                return ProviderFetchOutcome(result: .success(result), attempts: [])
            } catch {
                return ProviderFetchOutcome(result: .failure(error), attempts: [])
            }
        }
        await ProviderInteractionContext.$current.withValue(interaction) {
            await store.refreshProvider(.deepseek)
        }
    }

    private nonisolated static func requestsMatching(
        _ requests: [URLRequest],
        window: DeepSeekUsageWindow) throws -> [URLRequest]
    {
        try requests.filter { request in
            guard request.url?.path.contains("by_api_key") == true else { return false }
            let items = try Self.query(request)
            return items["start"] == "\(window.startSeconds)" && items["end"] == "\(window.endSeconds)"
        }
    }

    @Test(arguments: [401, 403, 429])
    func `production seam older chunk auth or rate limit stops pagination immediately in UsageStore`(
        statusCode: Int) async throws
    {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-06-15T12:00:00Z"))
        let utc = try Self.calendar("UTC")
        let plan = DeepSeekHistoryPlan.make(period: .rolling(days: 90), now: now, calendar: utc)
        let (chunk0, chunk1, chunk2) = (plan.chunks[0], plan.chunks[1], plan.chunks[2])

        let transport = DeepSeekTestScriptedTransport(
            statusOverride: { _, start, end in
                start == chunk1.startSeconds && end == chunk1.endSeconds ? statusCode : 200
            },
            bodyBuilder: Self.edgePagesWithEmptyMiddle(chunk0: chunk0, chunk2: chunk2, newestRequests: 2))

        let store = self.makeStore(period: .rolling(days: 90), timeZoneIdentifier: "UTC")
        defer { store.stopSharedSpendDashboardPublication() }
        store._test_deepseekNowProvider = { now }

        try await self.refreshThroughProductionSeam(store, now: now, transport: transport)
        await store.deepseekHistoryTask?.value

        let requests = await transport.requests
        #expect(requests.allSatisfy { $0.url?.path.contains("by_api_key") == true })
        #expect(try Self.requestsMatching(requests, window: chunk0).count == 2)
        #expect(try Self.requestsMatching(requests, window: chunk1).isEmpty == false)
        #expect(try Self.requestsMatching(requests, window: chunk2).isEmpty)

        let cost = try #require(store.snapshots[.deepseek]?.costUsage)
        #expect(cost.last30DaysTokens == 100 && cost.last30DaysCostUSD == 1.0 && cost.last30DaysRequests == 2)
        #expect(cost.historyDays == 90 && cost.historyScanIsPartial == true)
        #expect(cost.historyLabel == "Last 30 of 90 days")
        #expect(cost.coveredDayIntervals == [
            CostUsageDayInterval(startDay: chunk0.startDayKey, endDay: chunk0.endDayKey),
        ])
        #expect(store.deepseekHistoryTask == nil)
        #expect(store.deepseekHistoryState?.completedFailedChunkCount == 2)
    }

    @Test
    func `production seam valid empty interior page stays complete while 503 interior page publishes 60 of 90`()
        async throws
    {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-06-15T12:00:00Z"))
        let utc = try Self.calendar("UTC")
        let plan = DeepSeekHistoryPlan.make(period: .rolling(days: 90), now: now, calendar: utc)
        let (chunk0, chunk1, chunk2) = (plan.chunks[0], plan.chunks[1], plan.chunks[2])

        let bodyBuilder = Self.edgePagesWithEmptyMiddle(chunk0: chunk0, chunk2: chunk2)

        // Case 1: Empty interior page (HTTP 200 with empty series) stays complete 90/90 in UsageStore.
        let emptyStore = self.makeStore(period: .rolling(days: 90), timeZoneIdentifier: "UTC")
        defer { emptyStore.stopSharedSpendDashboardPublication() }
        emptyStore._test_deepseekNowProvider = { now }
        let emptyTransport = DeepSeekTestScriptedTransport(bodyBuilder: bodyBuilder)

        try await self.refreshThroughProductionSeam(emptyStore, now: now, transport: emptyTransport)
        await emptyStore.deepseekHistoryTask?.value

        let emptyRequests = await emptyTransport.requests
        #expect(emptyRequests.count == 6 && emptyRequests.allSatisfy { $0.url?.path.contains("by_api_key") == true })
        let completeCost = try #require(emptyStore.snapshots[.deepseek]?.costUsage)
        #expect(completeCost.last30DaysTokens == 300 && completeCost.last30DaysCostUSD == 3.0)
        #expect(completeCost.last30DaysRequests == 3 && completeCost.historyDays == 90)
        #expect(completeCost.historyScanIsPartial == false && completeCost.historyLabel == nil)
        #expect(emptyStore.snapshots[.deepseek]?.detailRow(label: "Last 90 days") != nil)
        #expect(completeCost.coveredDayIntervals == [
            CostUsageDayInterval(startDay: plan.requestedStartDayKey, endDay: plan.requestedEndDayKey),
        ])

        // Case 2: Failed interior page (HTTP 503) publishes truthful 60/90 partial with 2 disjoint intervals.
        let failedStore = self.makeStore(period: .rolling(days: 90), timeZoneIdentifier: "UTC")
        defer { failedStore.stopSharedSpendDashboardPublication() }
        failedStore._test_deepseekNowProvider = { now }
        let failedTransport = DeepSeekTestScriptedTransport(
            statusOverride: { _, start, end in
                start == chunk1.startSeconds && end == chunk1.endSeconds ? 503 : 200
            },
            bodyBuilder: bodyBuilder)

        try await self.refreshThroughProductionSeam(failedStore, now: now, transport: failedTransport)
        await failedStore.deepseekHistoryTask?.value

        let failedRequests = await failedTransport.requests
        #expect(failedRequests.allSatisfy { $0.url?.path.contains("by_api_key") == true })
        #expect(try Self.requestsMatching(failedRequests, window: chunk0).count == 2)
        #expect(try Self.requestsMatching(failedRequests, window: chunk1).isEmpty == false)
        #expect(try Self.requestsMatching(failedRequests, window: chunk2).count == 2)

        let partialCost = try #require(failedStore.snapshots[.deepseek]?.costUsage)
        #expect(partialCost.last30DaysTokens == 300 && partialCost.last30DaysCostUSD == 3.0)
        #expect(partialCost.last30DaysRequests == 3 && partialCost.historyDays == 90)
        #expect(partialCost.historyScanIsPartial == true && partialCost.historyLabel == "Last 60 of 90 days")
        #expect(partialCost.coveredDayIntervals == [
            CostUsageDayInterval(startDay: chunk2.startDayKey, endDay: chunk2.endDayKey),
            CostUsageDayInterval(startDay: chunk0.startDayKey, endDay: chunk0.endDayKey),
        ])
        #expect(partialCost.daily.contains { $0.date >= chunk1.startDayKey && $0.date <= chunk1.endDayKey } == false)

        let dashboard = SpendDashboardModel.build(
            inputs: [.init(provider: .deepseek, displayName: "DeepSeek", snapshot: partialCost)],
            requestedDays: 90,
            now: now,
            calendar: utc)
        let gapDate = try #require(CostUsageLocalDay.date(fromKey: chunk1.startDayKey, calendar: utc))
        let gapSummary = try #require(dashboard.groups.first?.dailySummaries.first { $0.day == gapDate })
        #expect(gapSummary.providers.first?.totalCost == nil && gapSummary.providers.first?.totalTokens == nil)
    }

    @Test
    func `production seam recent 503 falls back to UTC monthly and retires prior wide history in UsageStore`()
        async throws
    {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-06-15T12:00:00Z"))
        let later = now.addingTimeInterval(60)
        let calendar = try Self.calendar("America/Los_Angeles")
        let plan = DeepSeekHistoryPlan.make(period: .rolling(days: 90), now: now, calendar: calendar)
        let (chunk0, chunk1, chunk2) = (plan.chunks[0], plan.chunks[1], plan.chunks[2])

        let store = self.makeStore(period: .rolling(days: 90), timeZoneIdentifier: "America/Los_Angeles")
        defer { store.stopSharedSpendDashboardPublication() }
        let clock = DeepSeekTestClockBox(now)
        store._test_deepseekNowProvider = { clock.current }

        // 1. Complete a real 90-day wide fetch first so prior wide history state exists.
        let initialTransport = DeepSeekTestScriptedTransport(bodyBuilder: { url, start, end in
            if start == chunk0.startSeconds, end == chunk0.endSeconds {
                return Self.chunkPayload(
                    url: url,
                    time: chunk0.endSeconds - 43200,
                    tokens: 100,
                    cost: "1.0",
                    requests: 2)
            }
            if start == chunk1.startSeconds, end == chunk1.endSeconds {
                return Self.chunkPayload(
                    url: url,
                    time: chunk1.startSeconds + 43200,
                    tokens: 200,
                    cost: "2.0",
                    requests: 4)
            }
            return Self.chunkPayload(
                url: url,
                time: chunk2.startSeconds + 43200,
                tokens: 300,
                cost: "3.0",
                requests: 6)
        })
        try await self.refreshThroughProductionSeam(store, now: now, balance: 10.0, transport: initialTransport)
        await store.deepseekHistoryTask?.value
        #expect(store.snapshots[.deepseek]?.costUsage?.last30DaysTokens == 600)
        #expect(store.deepseekHistoryState?.completedScope != nil)

        // 2. Recent by_api_key 503 falls back to UTC monthly, retires prior wide history, and queries 0 older chunks.
        clock.set(later)
        let fallbackTransport = DeepSeekTestScriptedTransport(
            statusOverride: { url, _, _ in
                url.path.contains("by_api_key") ? 503 : 200
            },
            bodyBuilder: { url, _, _ in
                Self.monthlyFallbackPayload(url: url, date: "2026-06-15", tokens: 456, cost: "0.75")
            })
        try await self.refreshThroughProductionSeam(store, now: later, balance: 9.0, transport: fallbackTransport)
        await store.deepseekHistoryTask?.value

        let requests = await fallbackTransport.requests
        let byKey = requests.filter { $0.url?.path.contains("by_api_key") == true }
        let monthly = requests.filter { $0.url?.path.contains("by_api_key") == false }
        #expect(byKey.isEmpty == false && byKey.count <= 2)
        #expect(try Self.requestsMatching(requests, window: chunk1).isEmpty)
        #expect(try Self.requestsMatching(requests, window: chunk2).isEmpty)
        #expect(monthly.count == 2)

        #expect(store.deepseekHistoryState == nil && store.deepseekHistoryTask == nil)
        let fallbackSnapshot = try #require(store.snapshots[.deepseek])
        let fallbackCost = try #require(fallbackSnapshot.costUsage)
        #expect(fallbackSnapshot.primary?.resetDescription?.contains("$9.00") == true)
        #expect(fallbackCost.historyLabel == "This month" && fallbackCost.coveredDayIntervals == nil)
        #expect(fallbackCost.last30DaysTokens == 456 && fallbackCost.last30DaysCostUSD == 0.75)
        #expect(fallbackCost.sessionTokens == 456 && fallbackCost.sessionCostUSD == 0.75)
        #expect(fallbackSnapshot.detailRow(label: "This month") != nil)
    }

    @Test
    func `production seam cancelling in-flight wide worker stops via unified pager and retires active slot`()
        async throws
    {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-06-15T12:00:00Z"))
        let utc = try Self.calendar("UTC")
        let plan = DeepSeekHistoryPlan.make(period: .rolling(days: 90), now: now, calendar: utc)
        let (chunk0, chunk1, chunk2) = (plan.chunks[0], plan.chunks[1], plan.chunks[2])
        let gate = DeepSeekTestChunkGate()

        let transport = DeepSeekTestScriptedTransport(
            bodyBuilder: { url, start, end in
                if start == chunk0.startSeconds, end == chunk0.endSeconds {
                    return Self.chunkPayload(
                        url: url,
                        time: chunk0.endSeconds - 43200,
                        tokens: 100,
                        cost: "1.0",
                        requests: 2)
                }
                if start == chunk1.startSeconds, end == chunk1.endSeconds {
                    return Self.chunkPayload(
                        url: url,
                        time: chunk1.startSeconds + 43200,
                        tokens: 999,
                        cost: "9.99",
                        requests: 9)
                }
                return Self.chunkPayload(
                    url: url,
                    time: chunk2.startSeconds + 43200,
                    tokens: 300,
                    cost: "3.0",
                    requests: 6)
            },
            beforeResponse: { _, start, end in
                if start == chunk1.startSeconds, end == chunk1.endSeconds {
                    try await gate.waitForReleaseOrCancel(window: chunk1)
                }
            })

        let store = self.makeStore(period: .rolling(days: 90), timeZoneIdentifier: "UTC")
        defer { store.stopSharedSpendDashboardPublication() }
        store._test_deepseekNowProvider = { now }

        try await self.refreshThroughProductionSeam(store, now: now, transport: transport)
        await gate.waitUntilPaused(window: chunk1)
        let workerTask = try #require(store.deepseekHistoryTask)
        #expect(store.deepseekHistoryState?.activeScope != nil)

        workerTask.cancel()
        await workerTask.value

        let requests = await transport.requests
        #expect(try Self.requestsMatching(requests, window: chunk0).count == 2)
        #expect(try Self.requestsMatching(requests, window: chunk1).isEmpty == false)
        #expect(try Self.requestsMatching(requests, window: chunk2).isEmpty)

        #expect(store.deepseekHistoryTask == nil)
        #expect(store.deepseekHistoryState?.activeScope == nil)
        #expect(store.deepseekHistoryState?.completedScope == nil)
        #expect(store.deepseekHistoryState?.chunksByWindow.keys.contains(chunk1) == false)
        #expect(store.deepseekHistoryState?.chunksByWindow.keys.contains(chunk2) == false)

        let cost = try #require(store.snapshots[.deepseek]?.costUsage)
        #expect(cost.last30DaysTokens == 100 && cost.last30DaysCostUSD == 1.0 && cost.last30DaysRequests == 2)
        #expect(cost.historyLabel == "Last 30 of 90 days" && cost.historyScanIsPartial == true)
    }

    @Test
    func `production seam freshest head during wide load merges without double counting or extra older requests`()
        async throws
    {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-06-15T12:00:00Z"))
        let tick2 = now.addingTimeInterval(60)
        let utc = try Self.calendar("UTC")
        let plan = DeepSeekHistoryPlan.make(period: .rolling(days: 90), now: now, calendar: utc)
        let (chunk0, chunk1, chunk2) = (plan.chunks[0], plan.chunks[1], plan.chunks[2])
        let gate = DeepSeekTestChunkGate()
        let clock = DeepSeekTestClockBox(now)
        let useV2Head = OSAllocatedUnfairLock(initialState: false)

        let transport = DeepSeekTestScriptedTransport(
            bodyBuilder: { url, start, end in
                if start == chunk0.startSeconds, end == chunk0.endSeconds {
                    let isV2 = useV2Head.withLock { $0 }
                    return Self.chunkPayload(
                        url: url,
                        time: chunk0.endSeconds - 43200,
                        tokens: isV2 ? 150 : 100,
                        cost: isV2 ? "1.5" : "1.0",
                        requests: isV2 ? 3 : 2)
                }
                if start == chunk1.startSeconds, end == chunk1.endSeconds {
                    return Self.chunkPayload(
                        url: url,
                        time: chunk1.startSeconds + 43200,
                        tokens: 200,
                        cost: "2.0",
                        requests: 4)
                }
                return Self.chunkPayload(
                    url: url,
                    time: chunk2.startSeconds + 43200,
                    tokens: 300,
                    cost: "3.0",
                    requests: 6)
            },
            beforeResponse: { _, start, end in
                if start == chunk1.startSeconds, end == chunk1.endSeconds {
                    try await gate.waitForReleaseOrCancel(window: chunk1)
                }
            })

        let store = self.makeStore(period: .rolling(days: 90), timeZoneIdentifier: "UTC")
        defer { store.stopSharedSpendDashboardPublication() }
        store._test_deepseekNowProvider = { clock.current }

        // 1. Cold load publishes head v1 (100 tokens / $1.00 / 2 reqs) and pauses on chunk 1.
        try await self.refreshThroughProductionSeam(store, now: now, balance: 10.0, transport: transport)
        await gate.waitUntilPaused(window: chunk1)
        #expect(store.snapshots[.deepseek]?.costUsage?.last30DaysTokens == 100)
        #expect(store.snapshots[.deepseek]?.costUsage?.historyLabel == "Last 30 of 90 days")

        // 2. Routine tick refreshes head JSON to v2 (150 tokens / $1.50 / 3 reqs) while chunk 1 is paused.
        useV2Head.withLock { $0 = true }
        clock.set(tick2)
        try await self.refreshThroughProductionSeam(store, now: tick2, balance: 9.5, transport: transport)
        #expect(store.snapshots[.deepseek]?.primary?.resetDescription?.contains("$9.50") == true)
        let pausedRequests = await transport.requests
        #expect(try Self.requestsMatching(pausedRequests, window: chunk0).count == 4)
        #expect(try Self.requestsMatching(pausedRequests, window: chunk2).isEmpty)

        // 3. Release older chunks and confirm merged 90d report uses freshest head v2 without double counting.
        await gate.releaseAll()
        await store.deepseekHistoryTask?.value
        await store.deepseekHeadProjectionTask?.value

        let finalRequests = await transport.requests
        #expect(finalRequests.count == 8)
        #expect(try Self.requestsMatching(finalRequests, window: chunk0).count == 4)
        #expect(try Self.requestsMatching(finalRequests, window: chunk1).count == 2)
        #expect(try Self.requestsMatching(finalRequests, window: chunk2).count == 2)

        let finalSnapshot = try #require(store.snapshots[.deepseek])
        let finalCost = try #require(finalSnapshot.costUsage)
        #expect(finalSnapshot.primary?.resetDescription?.contains("$9.50") == true)
        #expect(finalCost.sessionTokens == 150 && finalCost.sessionCostUSD == 1.5 && finalCost.sessionRequests == 3)
        #expect(finalCost.last30DaysTokens == 650 && finalCost.last30DaysCostUSD == 6.5)
        #expect(finalCost.last30DaysRequests == 13 && finalCost.historyDays == 90)
        #expect(finalCost.historyScanIsPartial == false && finalCost.historyLabel == nil)
        #expect(finalSnapshot.detailRow(label: "Last 90 days") != nil)
    }

    @Test
    func `unified pager supports graceful shouldContinue invalidation and cancellation in fetchUsageSummary`()
        async throws
    {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-06-15T12:00:00Z"))
        let utc = try Self.calendar("UTC")
        let plan = DeepSeekHistoryPlan.make(period: .rolling(days: 90), now: now, calendar: utc)
        let (chunk0, chunk1, chunk2) = (plan.chunks[0], plan.chunks[1], plan.chunks[2])

        // 1. shouldContinue returning false after chunk 1 merges chunk 0 + chunk 1 without touching chunk 2.
        let checks = DeepSeekTestCounterBox()
        let stopTransport = DeepSeekTestScriptedTransport(bodyBuilder: { url, start, end in
            if start == chunk0.startSeconds, end == chunk0.endSeconds {
                return Self.chunkPayload(
                    url: url,
                    time: chunk0.endSeconds - 43200,
                    tokens: 100,
                    cost: "1.0",
                    requests: 1)
            }
            if start == chunk1.startSeconds, end == chunk1.endSeconds {
                return Self.chunkPayload(
                    url: url,
                    time: chunk1.startSeconds + 43200,
                    tokens: 200,
                    cost: "2.0",
                    requests: 2)
            }
            return Self.chunkPayload(url: url, time: chunk2.startSeconds + 43200, tokens: 300, cost: "3.0", requests: 3)
        })
        let partialSummary = try await DeepSeekUsageFetcher.fetchUsageSummary(
            platformToken: "synthetic-platform-token",
            period: .rolling(days: 90),
            now: now,
            localCalendar: utc,
            transport: stopTransport,
            shouldContinue: {
                await checks.increment()
                return await checks.value == 1
            })
        let stopRequests = await stopTransport.requests
        #expect(try Self.requestsMatching(stopRequests, window: chunk0).count == 2)
        #expect(try Self.requestsMatching(stopRequests, window: chunk1).count == 2)
        #expect(try Self.requestsMatching(stopRequests, window: chunk2).isEmpty)
        #expect(partialSummary.currentMonthTokens == 300 && partialSummary.currentMonthCost == 3.0)
        #expect(partialSummary.coverage?.coveredDays == 60 && partialSummary.coverage?.isPartial == true)

        // 2. Task cancellation inside fetchUsageSummary throws CancellationError without touching chunk 2.
        let gate = DeepSeekTestChunkGate()
        let cancelTransport = DeepSeekTestScriptedTransport(beforeResponse: { _, start, end in
            if start == chunk1.startSeconds, end == chunk1.endSeconds {
                try await gate.waitForReleaseOrCancel(window: chunk1)
            }
        })
        let summaryTask = Task {
            try await DeepSeekUsageFetcher.fetchUsageSummary(
                platformToken: "synthetic-platform-token",
                period: .rolling(days: 90),
                now: now,
                localCalendar: utc,
                transport: cancelTransport)
        }
        await gate.waitUntilPaused(window: chunk1)
        summaryTask.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await summaryTask.value
        }
        #expect(try await Self.requestsMatching(cancelTransport.requests, window: chunk2).isEmpty)
    }
}
