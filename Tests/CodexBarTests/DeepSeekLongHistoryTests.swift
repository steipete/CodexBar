import Darwin
import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore
@testable import CodexBarWidget

struct DeepSeekLongHistoryTests {
    // MARK: - Chunk planning and recorded HTTP query contracts

    @Test(arguments: [
        (1, [1]),
        (7, [7]),
        (30, [30]),
        (31, [30, 1]),
        (32, [30, 2]),
        (90, [30, 30, 30]),
        (365, [30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 5]),
    ])
    func `recorded queries partition rolling windows newest-first with exact disjoint bounds`(
        days: Int,
        expectedChunkDays: [Int]) async throws
    {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-06-15T15:30:00Z"))
        let calendar = try Self.calendar("America/Los_Angeles")
        let transport = DeepSeekTestScriptedTransport()

        let summary = try await DeepSeekUsageFetcher.fetchUsageSummary(
            platformToken: "synthetic-platform-token",
            period: .rolling(days: days),
            now: now,
            localCalendar: calendar,
            transport: transport)

        let requests = await transport.requests
        #expect(requests.allSatisfy { $0.url?.path.contains("by_api_key") == true })
        #expect(requests.count == expectedChunkDays.count * 2)

        let amountRequests = requests.filter { $0.url?.path.hasSuffix("/by_api_key/amount") == true }
        let costRequests = requests.filter { $0.url?.path.hasSuffix("/by_api_key/cost") == true }
        #expect(amountRequests.count == expectedChunkDays.count)
        #expect(costRequests.count == expectedChunkDays.count)

        let expectedOffset = calendar.timeZone.secondsFromGMT(for: now)
        var previousStart: Int?
        var totalCoveredSeconds = 0
        for (index, request) in amountRequests.enumerated() {
            let query = try Self.query(request)
            let start = try #require(query["start"].flatMap(Int.init))
            let end = try #require(query["end"].flatMap(Int.init))
            let offset = try #require(query["tz"].flatMap(Int.init))
            #expect(offset == expectedOffset)
            #expect((start + offset) % 86400 == 0)
            #expect((end + offset) % 86400 == 0)
            #expect(end - start == expectedChunkDays[index] * 86400)
            if let previousStart {
                // Newest-first adjacent disjoint intervals: older.end == newer.start.
                #expect(end == previousStart)
            }
            previousStart = start
            totalCoveredSeconds += (end - start)
        }
        #expect(totalCoveredSeconds == days * 86400)
        #expect(summary.coverage?.requestedDays == days)
        #expect(summary.coverage?.coveredDays == days)
        #expect(summary.coverage?.isComplete == true)
        #expect(summary.coverage?.coveredIntervals.count == 1)
    }

    @Test
    func `month-to-date uses civil month bounds and bounded all never stamps All`() async throws {
        let jan31 = try #require(ISO8601DateFormatter().date(from: "2026-01-31T20:00:00Z"))
        let calendar = try Self.calendar("America/Los_Angeles")

        let mtdTransport = DeepSeekTestScriptedTransport()
        let mtdSummary = try await DeepSeekUsageFetcher.fetchUsageSummary(
            platformToken: "synthetic-platform-token",
            period: .monthToDate,
            now: jan31,
            localCalendar: calendar,
            transport: mtdTransport)
        let mtdAmountRequests = await mtdTransport.requests.filter {
            $0.url?.path.hasSuffix("/by_api_key/amount") == true
        }
        // Jan 31 has 31 civil days -> [30, 1] chunks under the 30-day chunk cap.
        #expect(mtdAmountRequests.count == 2)
        #expect(mtdSummary.coverage?.requestedDays == 31)
        #expect(mtdSummary.coverage?.coveredDays == 31)
        #expect(mtdSummary.periodLabel == "Month to date")
        #expect(mtdSummary.toCostUsageTokenSnapshot(calendar: calendar).historyLabel == "Month to date")

        let allTransport = DeepSeekTestScriptedTransport()
        let allSummary = try await DeepSeekUsageFetcher.fetchUsageSummary(
            platformToken: "synthetic-platform-token",
            period: .allTime,
            now: jan31,
            localCalendar: calendar,
            transport: allTransport)
        let allAmountRequests = await allTransport.requests.filter {
            $0.url?.path.hasSuffix("/by_api_key/amount") == true
        }
        #expect(allAmountRequests.count == 13)
        #expect(allSummary.periodLabel == "Last 365 days")
        #expect(allSummary.periodLabel != "All")
        let allCostSnapshot = allSummary.toCostUsageTokenSnapshot(calendar: calendar)
        #expect(allCostSnapshot.reporting(.allTime).historyLabel == "Last 365 days")
        #expect(allCostSnapshot.reporting(.allTime).periodLabel == "Last 365 days")

        // Non-DeepSeek snapshots preserve existing CostReportingPeriod.reporting(.allTime) semantics.
        let genericIncomplete = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: 10,
            last30DaysCostUSD: 1.0,
            historyDays: 30,
            historyCoverageIsEstablished: false,
            historyLabel: "Last 30 days (partial)",
            daily: [],
            updatedAt: jan31)
        #expect(genericIncomplete.reporting(.allTime).historyLabel == "All")
        #expect(genericIncomplete.reporting(.allTime).reportingPeriod == .allTime)
    }

    // MARK: - Multi-chunk merge, currency selection, FUNCTION_CALL, key dedupe, and short-window exactness

    @Test
    func `90-day merge deduplicates keys, chooses one currency, keeps FUNCTION_CALL, and rejects boundary overlap`()
        async throws
    {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-06-15T12:00:00Z"))
        let utc = try Self.calendar("UTC")
        let plan = DeepSeekHistoryPlan.make(period: .rolling(days: 90), now: now, calendar: utc)
        #expect(plan.chunks.count == 3)

        let chunk0 = plan.chunks[0] // newest 30d
        let chunk1 = plan.chunks[1] // middle 30d
        let chunk2 = plan.chunks[2] // oldest 30d

        let chunk0Day = chunk0.endSeconds - 43200 // 2026-06-15 12:00Z
        let chunk1Day = chunk1.startSeconds + 43200
        let chunk2Day = chunk2.startSeconds + 43200

        let transport = DeepSeekTestScriptedTransport(bodyBuilder: { url, start, end in
            if start == chunk0.startSeconds, end == chunk0.endSeconds {
                if url.path.hasSuffix("/amount") {
                    return Self.amountJSON(
                        series: [
                            Self.amountSeries(
                                keyID: "key-A",
                                model: "deepseek-chat",
                                buckets: [
                                    // Out-of-window boundary timestamps must be excluded.
                                    (chunk0.startSeconds - 1, 99999, 999),
                                    (chunk0.endSeconds, 88888, 888),
                                    (chunk0Day, 1000, 10),
                                ]),
                            Self.amountSeries(
                                keyID: "key-B",
                                model: "deepseek-chat",
                                buckets: [(chunk0Day, 500, 5)]),
                        ],
                        functionBuckets: [
                            (chunk0.endSeconds, 777),
                            (chunk0Day, 3),
                        ])
                }
                return Self.costJSON(blocks: [
                    ("CNY", [Self.costSeries(keyID: "key-A", model: "deepseek-chat", buckets: [(chunk0Day, "70")])]),
                    ("USD", [Self.costSeries(keyID: "key-A", model: "deepseek-chat", buckets: [
                        (chunk0.endSeconds, "99"),
                        (chunk0Day, "1.50"),
                    ])]),
                ])
            }
            if start == chunk1.startSeconds, end == chunk1.endSeconds {
                if url.path.hasSuffix("/amount") {
                    return Self.amountJSON(
                        series: [
                            Self.amountSeries(
                                keyID: "key-B",
                                model: "deepseek-reasoner",
                                buckets: [(chunk1Day, 4000, 20)]),
                            Self.amountSeries(
                                keyID: "key-C",
                                model: "deepseek-reasoner",
                                buckets: [(chunk1Day, 1000, 4)]),
                        ],
                        functionBuckets: [(chunk1Day, 5)])
                }
                // Middle window reports CNY only; must never be added into USD totals.
                return Self.costJSON(blocks: [
                    ("CNY", [Self.costSeries(
                        keyID: "key-B",
                        model: "deepseek-reasoner",
                        buckets: [(chunk1Day, "50")])]),
                ])
            }
            if start == chunk2.startSeconds, end == chunk2.endSeconds {
                if url.path.hasSuffix("/amount") {
                    return Self.amountJSON(
                        series: [
                            Self.amountSeries(
                                keyID: "key-A",
                                model: "deepseek-chat",
                                buckets: [(chunk2Day, 2000, 6)]),
                        ],
                        functionBuckets: [])
                }
                return Self.costJSON(blocks: [
                    ("USD", [Self.costSeries(
                        keyID: "key-A",
                        model: "deepseek-chat",
                        buckets: [(chunk2Day, "2.50")])]),
                ])
            }
            return Self.emptyByKeyJSON(isAmount: url.path.hasSuffix("/amount"))
        })

        let summary = try await DeepSeekUsageFetcher.fetchUsageSummary(
            platformToken: "synthetic-platform-token",
            period: .rolling(days: 90),
            now: now,
            localCalendar: utc,
            transport: transport)

        #expect(summary.currency == "USD")
        #expect(summary.currentMonthCost == 4.0)
        #expect(summary.todayCost == 1.5)
        #expect(summary.todayTokens == 1500)
        #expect(summary.requestCount == 18) // 10 + 5 + 3 FUNCTION_CALL
        #expect(summary.currentMonthTokens == 8500) // 1500 + 5000 + 2000
        #expect(summary.currentMonthRequestCount == 53) // 18 + (20+4+5) + 6
        #expect(summary.apiKeyCount == 3) // key-A, key-B, key-C deduplicated
        #expect(summary.topModel == "deepseek-reasoner") // 5000 > 3500
        #expect(summary.modelCosts == [DeepSeekModelCost(model: "deepseek-chat", cost: 4.0)])
        // Middle-chunk day had tokens and requests in CNY only -> USD cost stays nil (not 0 or 50).
        let middleDayKey = CostUsageLocalDay.key(
            from: Date(timeIntervalSince1970: TimeInterval(chunk1Day)),
            calendar: utc)
        let middleDay = try #require(summary.daily.first { $0.date == middleDayKey })
        #expect(middleDay.totalTokens == 5000)
        #expect(middleDay.requestCount == 29)
        #expect(middleDay.cost == nil)
    }

    // MARK: - Failure modes, empty middle vs failed middle, UTC fallback, and 401/403/429 stop

    @Test
    func `successful empty middle chunk stays complete while failed middle chunk reports 60 of 90`() async throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-06-15T12:00:00Z"))
        let utc = try Self.calendar("UTC")
        let plan = DeepSeekHistoryPlan.make(period: .rolling(days: 90), now: now, calendar: utc)
        let chunk0 = plan.chunks[0]
        let chunk1 = plan.chunks[1]
        let chunk2 = plan.chunks[2]

        // Case 1: Empty middle chunk returns 200 with empty series -> full 90/90 coverage.
        let bodyBuilder = Self.edgePagesWithEmptyMiddle(chunk0: chunk0, chunk2: chunk2)
        let emptyMiddleTransport = DeepSeekTestScriptedTransport(bodyBuilder: bodyBuilder)

        let completeSummary = try await DeepSeekUsageFetcher.fetchUsageSummary(
            platformToken: "synthetic-platform-token",
            period: .rolling(days: 90),
            now: now,
            localCalendar: utc,
            transport: emptyMiddleTransport)
        #expect(completeSummary.coverage?.coveredDays == 90)
        #expect(completeSummary.coverage?.isComplete == true)
        #expect(completeSummary.coverage?.coveredIntervals.count == 1)
        #expect(completeSummary.currentMonthTokens == 300)
        #expect(completeSummary.currentMonthCost == 3.0)

        // Case 2: Failed middle chunk (HTTP 503) -> 60/90 with 2 disjoint intervals, no monthly fallback.
        let failedMiddleTransport = DeepSeekTestScriptedTransport(
            statusOverride: { _, start, end in
                start == chunk1.startSeconds && end == chunk1.endSeconds ? 503 : 200
            },
            bodyBuilder: bodyBuilder)

        let partialSummary = try await DeepSeekUsageFetcher.fetchUsageSummary(
            platformToken: "synthetic-platform-token",
            period: .rolling(days: 90),
            now: now,
            localCalendar: utc,
            transport: failedMiddleTransport)
        let failedRequests = await failedMiddleTransport.requests
        #expect(failedRequests.allSatisfy { $0.url?.path.contains("by_api_key") == true })
        #expect(partialSummary.coverage?.coveredDays == 60)
        #expect(partialSummary.coverage?.requestedDays == 90)
        #expect(partialSummary.coverage?.isPartial == true)
        #expect(partialSummary.coverage?.failedChunkCount == 1)
        #expect(partialSummary.coverage?.coveredIntervals.count == 2)
        #expect(partialSummary.periodLabel == "Last 60 of 90 days")
        #expect(partialSummary.currentMonthTokens == 300)
        #expect(partialSummary.currentMonthCost == 3.0)
    }

    @Test(arguments: [401, 403, 429])
    func `terminal auth or rate limit on older chunk stops pagination immediately without monthly fallback`(
        statusCode: Int) async throws
    {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-06-15T12:00:00Z"))
        let utc = try Self.calendar("UTC")
        let plan = DeepSeekHistoryPlan.make(period: .rolling(days: 90), now: now, calendar: utc)
        let chunk1 = plan.chunks[1]

        let transport = DeepSeekTestScriptedTransport(statusOverride: { _, start, end in
            start == chunk1.startSeconds && end == chunk1.endSeconds ? statusCode : 200
        })

        let summary = try await DeepSeekUsageFetcher.fetchUsageSummary(
            platformToken: "synthetic-platform-token",
            period: .rolling(days: 90),
            now: now,
            localCalendar: utc,
            transport: transport)

        let requests = await transport.requests
        // Only chunk 0 (2 requests) and chunk 1 (2 requests) run; chunk 2 is never touched.
        #expect(requests.allSatisfy { $0.url?.path.contains("by_api_key") == true })
        #expect(requests.count == 4)
        #expect(summary.coverage?.coveredDays == 30)
        #expect(summary.coverage?.requestedDays == 90)
        #expect(summary.coverage?.isPartial == true)
        #expect(summary.periodLabel == "Last 30 of 90 days")
    }

    @Test
    func `recent failure under 90-day request falls back to UTC monthly without querying older chunks`() async throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-06-15T12:00:00Z"))
        let calendar = try Self.calendar("America/Los_Angeles")
        let transport = DeepSeekTestScriptedTransport(
            statusOverride: { url, _, _ in
                url.path.contains("by_api_key") ? 503 : 200
            },
            bodyBuilder: { url, _, _ in
                Self.monthlyFallbackPayload(url: url, date: "2026-06-15", tokens: 456, cost: "0.75")
            })

        let summary = try await DeepSeekUsageFetcher.fetchUsageSummary(
            platformToken: "synthetic-platform-token",
            period: .rolling(days: 90),
            now: now,
            localCalendar: calendar,
            transport: transport)

        let requests = await transport.requests
        let byKey = requests.filter { $0.url?.path.contains("by_api_key") == true }
        let monthly = requests.filter { $0.url?.path.contains("by_api_key") == false }
        #expect(byKey.count == 2) // only recent chunk attempted; zero older chunks
        #expect(monthly.count == 2)
        #expect(summary.period == .currentMonth)
        #expect(summary.periodLabel == "This month")
        #expect(summary.todayTokens == 456)
        #expect(summary.todayCost == 0.75)
    }

    @Test(arguments: ["both", "costOnly", "amountOnly"])
    func `unrecognized recent by-api-key shape falls back to UTC monthly instead of reporting zero`(
        corruptedSide: String) async throws
    {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-06-15T12:00:00Z"))
        let calendar = try Self.calendar("America/Los_Angeles")
        let unrecognized = Data(#"{"code":0,"data":{"biz_code":0,"biz_data":{"unrecognized":[]}}}"#.utf8)
        let plan = DeepSeekHistoryPlan.make(period: .rolling(days: 90), now: now, calendar: calendar)
        let chunk0Day = plan.chunks[0].endSeconds - 43200

        let transport = DeepSeekTestScriptedTransport(bodyBuilder: { url, _, _ in
            let isAmount = url.path.hasSuffix("/amount")
            if url.path.contains("by_api_key") {
                if (corruptedSide == "costOnly" && isAmount) || (corruptedSide == "amountOnly" && !isAmount) {
                    return Self.chunkPayload(url: url, time: chunk0Day, tokens: 100, cost: "1.0", requests: 1)
                }
                return unrecognized
            }
            return Self.monthlyFallbackPayload(url: url, date: "2026-06-15", tokens: 456, cost: "0.75")
        })

        let summary = try await DeepSeekUsageFetcher.fetchUsageSummary(
            platformToken: "synthetic-platform-token",
            period: .rolling(days: 90),
            now: now,
            localCalendar: calendar,
            transport: transport)

        let requests = await transport.requests
        let byKey = requests.filter { $0.url?.path.contains("by_api_key") == true }
        let monthly = requests.filter { $0.url?.path.contains("by_api_key") == false }
        #expect(byKey.count == 2)
        #expect(monthly.count == 2)
        #expect(summary.period == .currentMonth)
        #expect(summary.periodLabel == "This month")
        #expect(summary.coverage == nil)
        #expect(summary.todayTokens == 456)
        #expect(summary.todayCost == 0.75)
    }

    @Test(arguments: ["both", "costOnly", "amountOnly"])
    func `unrecognized middle chunk shape is treated as failed chunk with 60 of 90 coverage`(
        corruptedSide: String) async throws
    {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-06-15T12:00:00Z"))
        let utc = try Self.calendar("UTC")
        let plan = DeepSeekHistoryPlan.make(period: .rolling(days: 90), now: now, calendar: utc)
        let chunk0 = plan.chunks[0]
        let chunk1 = plan.chunks[1]
        let chunk2 = plan.chunks[2]
        let unrecognized = Data(#"{"code":0,"data":{"biz_code":0,"biz_data":{"unrecognized":[]}}}"#.utf8)

        let transport = DeepSeekTestScriptedTransport(bodyBuilder: { url, start, end in
            let isAmount = url.path.hasSuffix("/amount")
            if start == chunk0.startSeconds, end == chunk0.endSeconds {
                return Self.chunkPayload(
                    url: url,
                    time: chunk0.endSeconds - 43200,
                    tokens: 100,
                    cost: "1.0",
                    requests: 1)
            }
            if start == chunk1.startSeconds, end == chunk1.endSeconds {
                if (corruptedSide == "costOnly" && isAmount) || (corruptedSide == "amountOnly" && !isAmount) {
                    return Self.chunkPayload(
                        url: url,
                        time: chunk1.startSeconds + 43200,
                        tokens: 500,
                        cost: "5.0",
                        requests: 5)
                }
                return unrecognized
            }
            if start == chunk2.startSeconds, end == chunk2.endSeconds {
                return Self.chunkPayload(
                    url: url,
                    time: chunk2.startSeconds + 43200,
                    tokens: 200,
                    cost: "2.0",
                    requests: 2)
            }
            return Self.emptyByKeyJSON(isAmount: isAmount)
        })

        let summary = try await DeepSeekUsageFetcher.fetchUsageSummary(
            platformToken: "synthetic-platform-token",
            period: .rolling(days: 90),
            now: now,
            localCalendar: utc,
            transport: transport)

        let requests = await transport.requests
        #expect(requests.allSatisfy { $0.url?.path.contains("by_api_key") == true })
        #expect(summary.coverage?.coveredDays == 60)
        #expect(summary.coverage?.requestedDays == 90)
        #expect(summary.coverage?.isPartial == true)
        #expect(summary.coverage?.failedChunkCount == 1)
        #expect(summary.coverage?.coveredIntervals.count == 2)
        #expect(summary.periodLabel == "Last 60 of 90 days")
        #expect(summary.currentMonthTokens == 300)
        #expect(summary.currentMonthCost == 3.0)
    }

    @Test
    func `unselected browser profiles never receive a wide history continuation`() async throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-06-15T12:00:00Z"))
        let utc = try Self.calendar("UTC")
        let plan = DeepSeekHistoryPlan.make(period: .rolling(days: 90), now: now, calendar: utc)
        let foldA = Self.makeFold(window: plan.chunks[0], day: plan.anchorDayKey, tokens: 100, cost: 1.0, req: 1)
        let foldB = Self.makeFold(window: plan.chunks[0], day: plan.anchorDayKey, tokens: 200, cost: 2.0, req: 2)

        let candidates = [
            DeepSeekPlatformTokenImporter.TokenInfo(
                id: "chrome:Default",
                token: "tok-a-1234567890123456",
                sourceLabel: "Personal"),
            DeepSeekPlatformTokenImporter.TokenInfo(
                id: "chrome:Profile 2",
                token: "tok-b-1234567890123456",
                sourceLabel: "Work"),
        ]
        let cache = DeepSeekPlatformValidationCache(validityTTL: 0)

        let resolution = await DeepSeekPlatformTokenImporter._resolvePlatformBalanceForTesting(
            candidates: candidates,
            selectedProfileID: "chrome:Profile 2",
            cache: cache)
        { token in
            let isWork = token == "tok-b-1234567890123456"
            let fold = isWork ? foldB : foldA
            let continuation = DeepSeekWideHistoryContinuation(
                metadata: DeepSeekHistorySessionMetadata(
                    profileID: isWork ? "chrome:Profile 2" : "chrome:Default",
                    ownerTokenDigest: isWork ? "digest-work" : "digest-personal",
                    plan: plan,
                    recentFold: fold),
                fetchChunk: { _ in
                    Issue.record("Validation must never execute wide chunk fetches")
                    return fold
                })
            return DeepSeekUsageSnapshot(
                isAvailable: true,
                currency: "USD",
                totalBalance: isWork ? 20 : 10,
                grantedBalance: 0,
                toppedUpBalance: isWork ? 20 : 10,
                usageSummary: DeepSeekUsageCostParser.mergeByAPIKeyChunks([fold], plan: plan),
                historyContinuation: continuation,
                updatedAt: now)
        }

        #expect(resolution.selectedContinuation?.metadata.profileID == "chrome:Profile 2")
        #expect(resolution.selectedContinuation?.metadata.ownerTokenDigest == "digest-work")
        #expect(resolution.selectedSummary?.todayTokens == 200)
    }

    // MARK: - Rollover plan adaptation and anchor refresh

    @Test
    func `adapting to reusable windows preserves cold plans, rejects invalid candidates, and fills gaps`() throws {
        let iso = ISO8601DateFormatter()
        let day1 = try #require(iso.date(from: "2026-06-15T12:00:00Z"))
        let day2 = try #require(iso.date(from: "2026-06-16T00:05:00Z"))
        let day2Later = try #require(iso.date(from: "2026-06-16T14:30:00Z"))
        let utc = try Self.calendar("UTC")

        // Cold loads and short windows keep exact un-adapted partitions.
        let coldExpectations: [(Int, [Int])] = [
            (1, [1]),
            (7, [7]),
            (30, [30]),
            (31, [30, 1]),
            (32, [30, 2]),
            (90, [30, 30, 30]),
            (365, [30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 5]),
        ]
        for (days, expected) in coldExpectations {
            let plan = DeepSeekHistoryPlan.make(period: .rolling(days: days), now: day1, calendar: utc)
            #expect(plan.adaptingToReusableWindows([]).chunks.map(\.dayCount) == expected)
        }
        let short30 = DeepSeekHistoryPlan.make(period: .rolling(days: 30), now: day2, calendar: utc)
        let day1Plan365 = DeepSeekHistoryPlan.make(period: .rolling(days: 365), now: day1, calendar: utc)
        #expect(short30.adaptingToReusableWindows(Set(day1Plan365.chunks)) == short30)

        // Day 2 adapts to Day 1's 11 complete 30d chunks, rejecting head, expired 5d tail, and malformed entries.
        let day2Plan365 = DeepSeekHistoryPlan.make(period: .rolling(days: 365), now: day2, calendar: utc)
        let valid30 = day1Plan365.chunks[1]
        let wrongTZ = DeepSeekUsageWindow(
            start: valid30.start,
            end: valid30.end,
            dayCount: 30,
            timeZoneSeconds: 32400,
            startDayKey: valid30.startDayKey,
            endDayKey: valid30.endDayKey)
        let misaligned = DeepSeekUsageWindow(
            start: valid30.start.addingTimeInterval(3600),
            end: valid30.end.addingTimeInterval(3600),
            dayCount: 30,
            timeZoneSeconds: 0,
            startDayKey: valid30.startDayKey,
            endDayKey: valid30.endDayKey)
        let subSecond = DeepSeekUsageWindow(
            start: valid30.start.addingTimeInterval(0.5),
            end: valid30.end.addingTimeInterval(0.5),
            dayCount: 30,
            timeZoneSeconds: 0,
            startDayKey: valid30.startDayKey,
            endDayKey: valid30.endDayKey)
        let bogusDayKeys = DeepSeekUsageWindow(
            start: valid30.start,
            end: valid30.end,
            dayCount: 30,
            timeZoneSeconds: 0,
            startDayKey: "1999-01-01",
            endDayKey: "1999-01-30")
        let oneDayShard = DeepSeekUsageWindow(
            start: valid30.start,
            end: valid30.start.addingTimeInterval(86400),
            dayCount: 1,
            timeZoneSeconds: 0,
            startDayKey: valid30.startDayKey,
            endDayKey: valid30.startDayKey)

        // Malformed-only set returns the plan unchanged.
        let invalidSet: Set<DeepSeekUsageWindow> = [
            day1Plan365.chunks[0], // overlaps Day 2 head
            day1Plan365.chunks[12], // starts before Day 2 requestedStart
            wrongTZ,
            misaligned,
            subSecond,
            bogusDayKeys,
            oneDayShard,
        ]
        #expect(day2Plan365.adaptingToReusableWindows(invalidSet) == day2Plan365)

        // Same-day exact tail match (5d) IS accepted so explicit reloads reuse succeeded small tails.
        let exactTailOnly = day2Plan365.adaptingToReusableWindows([day2Plan365.chunks[12]])
        #expect(exactTailOnly.chunks == day2Plan365.chunks)

        // Overlapping 30d candidates pick newest-first pairwise-disjoint subset and fill uncovered gaps newest-first.
        let shiftedOverlap = DeepSeekUsageWindow(
            start: day1Plan365.chunks[2].start.addingTimeInterval(5 * 86400),
            end: day1Plan365.chunks[2].end.addingTimeInterval(5 * 86400),
            dayCount: 30,
            timeZoneSeconds: 0,
            startDayKey: CostUsageLocalDay.key(
                from: day1Plan365.chunks[2].start.addingTimeInterval(5 * 86400),
                calendar: utc),
            endDayKey: CostUsageLocalDay.key(
                from: day1Plan365.chunks[2].end.addingTimeInterval(4 * 86400),
                calendar: utc))
        let adaptedWithOverlap = day2Plan365.adaptingToReusableWindows(
            Set(day1Plan365.chunks).union(invalidSet).union([shiftedOverlap]))
        #expect(adaptedWithOverlap.chunks.map(\.dayCount) == [30, 1, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 4])
        #expect(!adaptedWithOverlap.chunks.contains(shiftedOverlap))
        Self.assertValidPartition(adaptedWithOverlap)

        // withAnchorDate preserves adapted chunks and range bounds while refreshing anchorDate.
        let refreshed = adaptedWithOverlap.withAnchorDate(day2Later)
        #expect(refreshed.anchorDate == day2Later)
        #expect(refreshed.chunks == adaptedWithOverlap.chunks)
        #expect(refreshed.requestedStart == adaptedWithOverlap.requestedStart)
        #expect(refreshed.requestedEnd == adaptedWithOverlap.requestedEnd)
        #expect(refreshed.anchorDayKey == adaptedWithOverlap.anchorDayKey)
        #expect(refreshed.timeZoneSeconds == adaptedWithOverlap.timeZoneSeconds)
    }

    @Test(arguments: ["Asia/Tokyo", "Asia/Kathmandu", "America/St_Johns"])
    func `consecutive midnight rollovers keep adapted 365-day plans disjoint and bounded to at most 14 chunks`(
        zone: String) throws
    {
        let day1 = try #require(ISO8601DateFormatter().date(from: "2026-06-15T12:00:00Z"))
        let calendar = try Self.calendar(zone)
        var cachedWindows = Set<DeepSeekUsageWindow>()
        var olderFetchPairCounts: [Int] = []

        for dayOffset in 0..<35 {
            let now = day1.addingTimeInterval(Double(dayOffset) * 86400)
            let rawPlan = DeepSeekHistoryPlan.make(period: .rolling(days: 365), now: now, calendar: calendar)
            let adapted = rawPlan.adaptingToReusableWindows(cachedWindows)
            Self.assertValidPartition(rawPlan)
            Self.assertValidPartition(adapted)
            #expect(adapted.chunks.count <= 14)

            let uncachedOlder = adapted.chunks.dropFirst().filter { !cachedWindows.contains($0) }
            olderFetchPairCounts.append(uncachedOlder.count)
            cachedWindows = Set(adapted.chunks)
        }

        // Day 1: 12 cold pairs; Day 2..5: 2 pairs; Day 6: 1 pair (0d tail!); Day 7..35: <= 2 pairs.
        #expect(olderFetchPairCounts[0] == 12)
        #expect(olderFetchPairCounts[1] == 2)
        #expect(olderFetchPairCounts[2] == 2)
        #expect(olderFetchPairCounts[5] == 1)
        #expect(olderFetchPairCounts.dropFirst().allSatisfy { $0 <= 2 })
    }

    private static func assertValidPartition(_ plan: DeepSeekHistoryPlan) {
        #expect(!plan.chunks.isEmpty)
        #expect(plan.chunks.first?.endSeconds == Int(plan.requestedEnd.timeIntervalSince1970))
        #expect(plan.chunks.last?.startSeconds == plan.requestedStartSeconds)
        var totalDays = 0
        let calendar = plan.fixedOffsetCalendar
        for index in plan.chunks.indices {
            let chunk = plan.chunks[index]
            #expect(chunk.startDayKey == CostUsageLocalDay.key(from: chunk.start, calendar: calendar))
            // A fixed-offset civil day is exactly 86,400s, so the last included day is `end - 86,400s`.
            #expect(chunk.endDayKey == CostUsageLocalDay.key(
                from: chunk.end.addingTimeInterval(-86400),
                calendar: calendar))
            #expect((1...DeepSeekHistoryPlan.defaultMaxChunkDays).contains(chunk.dayCount))
            #expect((chunk.startSeconds + plan.timeZoneSeconds) % 86400 == 0)
            #expect((chunk.endSeconds + plan.timeZoneSeconds) % 86400 == 0)
            #expect(chunk.endSeconds - chunk.startSeconds == chunk.dayCount * 86400)
            if index > 0 {
                #expect(chunk.endSeconds == plan.chunks[index - 1].startSeconds)
            }
            totalDays += chunk.dayCount
        }
        #expect(totalDays == plan.requestedDays)
    }
}

extension DeepSeekLongHistoryTests {
    // MARK: - Checked arithmetic, cross-window overflow, and widget grouping safety

    @Test
    func `cross-window merge accepts exact Int.max totals across chunks and preserves categories and requests`()
        throws
    {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-06-15T12:00:00Z"))
        let utc = try Self.calendar("UTC")
        let plan = DeepSeekHistoryPlan.make(period: .rolling(days: 60), now: now, calendar: utc)
        #expect(plan.chunks.count == 2)

        let chunk0 = DeepSeekChunkFoldResult(
            window: plan.chunks[0],
            dayTokens: [plan.anchorDayKey: Int.max - 5],
            dayModelRequests: [plan.anchorDayKey: Int.max - 3],
            dayFunctionRequests: [plan.anchorDayKey: 2],
            categoryTotals: [
                .promptCacheHitToken: Int.max - 15,
                .promptCacheMissToken: 10,
            ],
            modelTokens: ["deepseek-chat": Int.max - 5],
            apiKeyIDs: ["key-1"],
            currencyTotals: [
                DeepSeekCurrencyContribution(
                    currency: "USD",
                    dayCosts: [plan.anchorDayKey: 1.5],
                    modelCosts: ["deepseek-chat": 1.5],
                    apiKeyIDs: ["key-1"]),
            ])
        let chunk1 = DeepSeekChunkFoldResult(
            window: plan.chunks[1],
            dayTokens: [plan.chunks[1].startDayKey: 5],
            dayModelRequests: [plan.chunks[1].startDayKey: 1],
            dayFunctionRequests: [:],
            categoryTotals: [.responseToken: 5],
            modelTokens: ["deepseek-reasoner": 5],
            apiKeyIDs: ["key-2"],
            currencyTotals: [
                DeepSeekCurrencyContribution(
                    currency: "USD",
                    dayCosts: [plan.chunks[1].startDayKey: 2.5],
                    modelCosts: ["deepseek-reasoner": 2.5],
                    apiKeyIDs: ["key-2"]),
            ])

        let summary = DeepSeekUsageCostParser.mergeByAPIKeyChunks([chunk0, chunk1], plan: plan)
        #expect(summary.coverage?.isComplete == true)
        #expect(summary.coverage?.coveredDays == 60)
        #expect(summary.coverage?.failedChunkCount == 0)
        #expect(summary.todayTokens == Int.max - 5)
        #expect(summary.currentMonthTokens == Int.max)
        #expect(summary.requestCount == Int.max - 1)
        #expect(summary.currentMonthRequestCount == Int.max)
        #expect(summary.currentMonthCost == 4.0)
        #expect(summary.topModel == "deepseek-chat")
        #expect(summary.categoryBreakdown.first { $0.category == .promptCacheHitToken }?.tokens == Int.max - 15)
        #expect(summary.categoryBreakdown.first { $0.category == .promptCacheMissToken }?.tokens == 10)
        #expect(summary.categoryBreakdown.first { $0.category == .responseToken }?.tokens == 5)

        let costSnapshot = summary.toCostUsageTokenSnapshot(calendar: utc)
        #expect(costSnapshot.last30DaysTokens == Int.max)
        #expect(costSnapshot.last30DaysRequests == Int.max)
        #expect(costSnapshot.last30DaysCostUSD == 4.0)
    }

    @Test(arguments: ["tokens", "requests", "dailyRequests", "siblingCategories", "modelTokens"])
    func `cross-window overflow degrades to honest partial coverage without wrapping, clamping, or zeroing`(
        dimension: String) throws
    {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-06-15T12:00:00Z"))
        let utc = try Self.calendar("UTC")
        let plan = DeepSeekHistoryPlan.make(period: .rolling(days: 60), now: now, calendar: utc)
        let d0 = plan.anchorDayKey
        let d1 = plan.chunks[1].startDayKey

        let chunk0: DeepSeekChunkFoldResult
        let chunk1: DeepSeekChunkFoldResult
        switch dimension {
        case "tokens":
            chunk0 = Self.makeFold(window: plan.chunks[0], day: d0, tokens: Int.max - 10, cost: 1.5, req: 10)
            chunk1 = Self.makeFold(window: plan.chunks[1], day: d1, tokens: 100, cost: 2.5, req: 5)
        case "requests":
            chunk0 = Self.makeFold(window: plan.chunks[0], day: d0, tokens: 100, cost: 1.5, req: Int.max - 5)
            chunk1 = Self.makeFold(window: plan.chunks[1], day: d1, tokens: 200, cost: 2.5, req: 10)
        case "dailyRequests":
            // Each request map fits, but model + FUNCTION_CALL on the same day does not.
            chunk0 = Self.makeFold(window: plan.chunks[0], day: d0, tokens: 100, cost: 1.5, req: 10)
            chunk1 = DeepSeekChunkFoldResult(
                window: plan.chunks[1],
                dayTokens: [d1: 50],
                dayModelRequests: [d1: Int.max],
                dayFunctionRequests: [d1: 1],
                categoryTotals: [.responseToken: 50],
                modelTokens: ["deepseek-chat": 50],
                apiKeyIDs: ["k1"],
                currencyTotals: [DeepSeekCurrencyContribution(
                    currency: "USD",
                    dayCosts: [d1: 2.5],
                    modelCosts: ["deepseek-chat": 2.5])])
        case "siblingCategories":
            chunk0 = DeepSeekChunkFoldResult(
                window: plan.chunks[0],
                dayTokens: [d0: 100],
                dayModelRequests: [d0: 1],
                dayFunctionRequests: [:],
                categoryTotals: [.promptCacheHitToken: Int.max - 5],
                modelTokens: ["deepseek-chat": 100],
                apiKeyIDs: ["k1"],
                currencyTotals: [DeepSeekCurrencyContribution(
                    currency: "USD",
                    dayCosts: [d0: 1.5],
                    modelCosts: ["deepseek-chat": 1.5])])
            chunk1 = DeepSeekChunkFoldResult(
                window: plan.chunks[1],
                dayTokens: [d1: 50],
                dayModelRequests: [d1: 1],
                dayFunctionRequests: [:],
                categoryTotals: [.responseToken: 10],
                modelTokens: ["deepseek-chat": 50],
                apiKeyIDs: ["k1"],
                currencyTotals: [DeepSeekCurrencyContribution(
                    currency: "USD",
                    dayCosts: [d1: 2.5],
                    modelCosts: ["deepseek-chat": 2.5])])
        default:
            chunk0 = DeepSeekChunkFoldResult(
                window: plan.chunks[0],
                dayTokens: [d0: 100],
                dayModelRequests: [d0: 1],
                dayFunctionRequests: [:],
                categoryTotals: [.responseToken: 100],
                modelTokens: ["deepseek-chat": Int.max - 5],
                apiKeyIDs: ["k1"],
                currencyTotals: [DeepSeekCurrencyContribution(
                    currency: "USD",
                    dayCosts: [d0: 1.5],
                    modelCosts: ["deepseek-chat": 1.5])])
            chunk1 = DeepSeekChunkFoldResult(
                window: plan.chunks[1],
                dayTokens: [d1: 50],
                dayModelRequests: [d1: 1],
                dayFunctionRequests: [:],
                categoryTotals: [.responseToken: 50],
                modelTokens: ["deepseek-chat": 10],
                apiKeyIDs: ["k1"],
                currencyTotals: [DeepSeekCurrencyContribution(
                    currency: "USD",
                    dayCosts: [d1: 2.5],
                    modelCosts: ["deepseek-chat": 2.5])])
        }

        let summary = DeepSeekUsageCostParser.mergeByAPIKeyChunks([chunk0, chunk1], plan: plan)
        #expect(summary.coverage?.isPartial == true)
        #expect(summary.coverage?.isComplete == false)
        #expect(summary.coverage?.coveredDays == 30)
        #expect(summary.coverage?.requestedDays == 60)
        #expect(summary.coverage?.failedChunkCount == 1)
        #expect(summary.coverage?.coveredIntervals == [
            CostUsageDayInterval(startDay: plan.chunks[0].startDayKey, endDay: plan.chunks[0].endDayKey),
        ])
        #expect(summary.periodLabel == "Last 30 of 60 days")
        #expect(summary.currentMonthCost == 1.5)
        #expect(summary.daily.map(\.date) == [d0])
        #expect(summary.currentMonthTokens == chunk0.dayTokens[d0])
        #expect(summary.currentMonthRequestCount == chunk0.dayModelRequests[d0])

        let costSnapshot = summary.toCostUsageTokenSnapshot(calendar: utc)
        #expect(costSnapshot.historyScanIsPartial == true)
        #expect(costSnapshot.historyCoverageIsEstablished == false)
        #expect(costSnapshot.historyLabel == "Last 30 of 60 days")
        #expect(costSnapshot.last30DaysTokens == chunk0.dayTokens[d0])
        #expect(costSnapshot.last30DaysRequests == chunk0.dayModelRequests[d0])
        #expect(costSnapshot.last30DaysCostUSD == 1.5)

        let details = DeepSeekUsageSnapshot.detailSections(for: summary)
        let usageRows = try #require(details.first { $0.title == "Usage" }?.rows)
        #expect(usageRows.contains { $0.label == "Last 30 of 60 days" })
        #expect(!usageRows.contains { $0.label == "Last 60 days" })
    }

    @Test
    func `cross-window middle chunk overflow and all-invalid chunks stay honest in snapshot and widget`() throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-06-15T12:00:00Z"))
        let utc = try Self.calendar("UTC")
        let plan90 = DeepSeekHistoryPlan.make(period: .rolling(days: 90), now: now, calendar: utc)

        let head = Self.makeFold(
            window: plan90.chunks[0],
            day: plan90.anchorDayKey,
            tokens: 1000,
            cost: 1.5,
            req: 10)
        let overflowingMiddle = Self.makeFold(
            window: plan90.chunks[1],
            day: plan90.chunks[1].startDayKey,
            tokens: Int.max - 500,
            cost: 5.0,
            req: 5)
        let oldest = Self.makeFold(
            window: plan90.chunks[2],
            day: plan90.chunks[2].startDayKey,
            tokens: 2000,
            cost: 2.5,
            req: 20)

        let partial = DeepSeekUsageCostParser.mergeByAPIKeyChunks([head, overflowingMiddle, oldest], plan: plan90)
        #expect(partial.coverage?.coveredDays == 60)
        #expect(partial.coverage?.failedChunkCount == 1)
        #expect(partial.coverage?.coveredIntervals.count == 2)
        #expect(partial.currentMonthTokens == 3000)
        #expect(partial.currentMonthCost == 4.0)

        let projection = UsageStore.deepSeekWidgetChartProjection(
            from: partial.toCostUsageTokenSnapshot(calendar: utc))
        #expect(projection.chartTitle == "Last 60 of 90 days")
        #expect(projection.compactPeriodLabel == "60/90d")
        #expect(projection.points.contains { $0.totalTokens == nil && $0.costUSD == nil })
        #expect(projection.points.compactMap(\.totalTokens).reduce(0, +) == 3000)

        // All chunks invalid (e.g., negative tokens) -> zero coverage and nil totals (never fabricated zero).
        let plan30 = DeepSeekHistoryPlan.make(period: .rolling(days: 30), now: now, calendar: utc)
        let negativeFold = Self.makeFold(
            window: plan30.chunks[0],
            day: plan30.anchorDayKey,
            tokens: -50,
            cost: 1.0,
            req: 1)
        let emptySummary = DeepSeekUsageCostParser.mergeByAPIKeyChunks([negativeFold], plan: plan30)
        #expect(emptySummary.coverage?.coveredDays == 0)
        #expect(emptySummary.coverage?.failedChunkCount == 1)
        let emptyCostSnapshot = emptySummary.toCostUsageTokenSnapshot(calendar: utc)
        #expect(emptyCostSnapshot.last30DaysTokens == nil)
        #expect(emptyCostSnapshot.last30DaysRequests == nil)
        #expect(emptyCostSnapshot.last30DaysCostUSD == nil)
    }

    @Test
    func `widget chart projection and token summary guard Int.max, overflow, and negative values`() throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-06-15T12:00:00Z"))
        let utc = try Self.calendar("UTC")
        let startOfToday = utc.startOfDay(for: now)
        func dayKey(daysAgo: Int) throws -> String {
            let date = try #require(utc.date(byAdding: .day, value: -daysAgo, to: startOfToday))
            return CostUsageLocalDay.key(from: date, calendar: utc)
        }

        // 90-day span triggers 2-day grouping: [daysAgo 1, 0], [3, 2], [5, 4], [7, 6], ...
        let d0 = try dayKey(daysAgo: 0)
        let d1 = try dayKey(daysAgo: 1)
        let d2 = try dayKey(daysAgo: 2)
        let d3 = try dayKey(daysAgo: 3)
        let d4 = try dayKey(daysAgo: 4)
        let d5 = try dayKey(daysAgo: 5)
        let d6 = try dayKey(daysAgo: 6)
        let d7 = try dayKey(daysAgo: 7)
        let d89 = try dayKey(daysAgo: 89)

        func dailyEntry(_ date: String, tokens: Int?, cost: Double?) -> CostUsageDailyReport.Entry {
            CostUsageDailyReport.Entry(
                date: date,
                inputTokens: nil,
                outputTokens: nil,
                totalTokens: tokens,
                costUSD: cost,
                modelsUsed: nil,
                modelBreakdowns: nil)
        }

        let groupedSnapshot = CostUsageTokenSnapshot(
            sessionTokens: 5,
            sessionCostUSD: 1.0,
            last30DaysTokens: nil,
            last30DaysCostUSD: nil,
            currencyCode: "USD",
            historyDays: 90,
            coveredDayIntervals: [CostUsageDayInterval(startDay: d89, endDay: d0)],
            daily: [
                dailyEntry(d89, tokens: 10, cost: 0.1),
                // Bucket [d7, d6]: negative cost invalidates cost only, tokens stay exact.
                dailyEntry(d7, tokens: 200, cost: 1.5),
                dailyEntry(d6, tokens: 300, cost: -0.5),
                // Bucket [d5, d4]: negative tokens invalidate tokens only, cost stays exact.
                dailyEntry(d5, tokens: 500, cost: 1.0),
                dailyEntry(d4, tokens: -100, cost: 2.0),
                // Bucket [d3, d2]: grouped token overflow -> totalTokens nil, cost exact.
                dailyEntry(d3, tokens: Int.max - 5, cost: 0.75),
                dailyEntry(d2, tokens: 6, cost: 0.25),
                // Bucket [d1, d0]: exact Int.max succeeds cleanly.
                dailyEntry(d1, tokens: Int.max - 5, cost: 1.0),
                dailyEntry(d0, tokens: 5, cost: 1.0),
            ],
            updatedAt: now)

        let projection = UsageStore.deepSeekWidgetChartProjection(from: groupedSnapshot)
        #expect(projection.bucketDays == 2)
        let newest = try #require(projection.points.last)
        #expect(newest.dayKey == d0)
        #expect(newest.totalTokens == Int.max)
        #expect(newest.costUSD == 2.0)

        let overflowBucket = try #require(projection.points.first { $0.dayKey == d3 })
        #expect(overflowBucket.totalTokens == nil)
        #expect(overflowBucket.costUSD == 1.0)

        let negTokenBucket = try #require(projection.points.first { $0.dayKey == d5 })
        #expect(negTokenBucket.totalTokens == nil)
        #expect(negTokenBucket.costUSD == 3.0)

        let negCostBucket = try #require(projection.points.first { $0.dayKey == d7 })
        #expect(negCostBucket.totalTokens == 500)
        #expect(negCostBucket.costUSD == nil)

        // Ungrouped duplicate day keys overflowing must stay nil even when a third valid entry follows.
        let duplicateDaySnapshot = CostUsageTokenSnapshot(
            sessionTokens: -10,
            sessionCostUSD: -1.0,
            last30DaysTokens: nil,
            last30DaysCostUSD: Double.nan,
            currencyCode: "USD",
            historyDays: 7,
            daily: [
                dailyEntry(d0, tokens: Int.max - 5, cost: 1.0),
                dailyEntry(d0, tokens: 10, cost: 2.0),
                dailyEntry(d0, tokens: 20, cost: 0.5),
            ],
            updatedAt: now)
        let duplicateProjection = UsageStore.deepSeekWidgetChartProjection(from: duplicateDaySnapshot)
        #expect(duplicateProjection.points.count == 1)
        #expect(duplicateProjection.points.first?.totalTokens == nil)
        #expect(duplicateProjection.points.first?.costUSD == 3.5)

        let duplicateSummary = try #require(UsageStore.widgetTokenUsageSummary(
            from: duplicateDaySnapshot,
            provider: .deepseek,
            chartProjection: duplicateProjection))
        #expect(duplicateSummary.sessionTokens == nil)
        #expect(duplicateSummary.sessionCostUSD == nil)
        #expect(duplicateSummary.last30DaysTokens == nil)
        #expect(duplicateSummary.last30DaysCostUSD == nil)

        // Negative daily tokens must not subtract into fallbackTokens.
        let negativeFallbackSnapshot = CostUsageTokenSnapshot(
            sessionTokens: 100,
            sessionCostUSD: 1.0,
            last30DaysTokens: nil,
            last30DaysCostUSD: 1.0,
            currencyCode: "USD",
            historyDays: 7,
            daily: [
                dailyEntry(d1, tokens: 100, cost: 0.5),
                dailyEntry(d0, tokens: -50, cost: 0.5),
            ],
            updatedAt: now)
        let negSummary = try #require(UsageStore.widgetTokenUsageSummary(
            from: negativeFallbackSnapshot,
            provider: .deepseek))
        #expect(negSummary.last30DaysTokens == nil)
    }
}

extension DeepSeekLongHistoryTests {
    // MARK: - Helpers

    @MainActor
    func makeStore(
        period: CostReportingPeriod,
        timeZoneIdentifier: String) -> UsageStore
    {
        let settings = testSettingsStore(
            suiteName: "DeepSeekLongHistoryTests-\(UUID().uuidString)",
            userDefaults: InMemoryUserDefaults(),
            config: CodexBarConfig(providers: [ProviderConfig(id: .deepseek, enabled: true)]))
        settings.statusChecksEnabled = false
        settings.costUsageEnabled = true
        settings.showOptionalCreditsAndExtraUsage = true
        settings.costReportingPeriod = period
        settings.costUsageBucketTimeZoneIdentifier = timeZoneIdentifier
        return UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(homeDirectory: "/nonexistent/deepseek-long-history", cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
    }

    nonisolated static func isExecutingOnMainThread() -> Bool {
        Thread.isMainThread
    }

    static func residentMemoryBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
            }
        }
        return status == KERN_SUCCESS ? info.resident_size : 0
    }

    static func makeFold(
        window: DeepSeekUsageWindow,
        day: String,
        tokens: Int,
        cost: Double,
        req: Int) -> DeepSeekChunkFoldResult
    {
        DeepSeekChunkFoldResult(
            window: window,
            dayTokens: [day: tokens],
            dayModelRequests: [day: req],
            dayFunctionRequests: [:],
            categoryTotals: [.responseToken: tokens],
            modelTokens: ["deepseek-chat": tokens],
            apiKeyIDs: ["key-1"],
            currencyTotals: [
                DeepSeekCurrencyContribution(
                    currency: "USD",
                    dayCosts: [day: cost],
                    modelCosts: ["deepseek-chat": cost],
                    apiKeyIDs: ["key-1"]),
            ])
    }

    static func makeChunkFold(
        _ window: DeepSeekUsageWindow,
        tokens: Int,
        cost: Double,
        req: Int) -> DeepSeekChunkFoldResult
    {
        self.makeFold(window: window, day: window.startDayKey, tokens: tokens, cost: cost, req: req)
    }

    static func makeDeepSeekBalance(
        _ balance: Double = 12.0,
        summary: DeepSeekUsageSummary? = nil,
        state: DeepSeekDetailedUsageState? = nil,
        updatedAt: Date) -> DeepSeekUsageSnapshot
    {
        DeepSeekUsageSnapshot(
            isAvailable: true,
            currency: "USD",
            totalBalance: balance,
            grantedBalance: 0,
            toppedUpBalance: balance,
            usageSummary: summary,
            detailedUsageState: state,
            updatedAt: updatedAt)
    }

    static func makeDeepSeekOutcome(
        balance: Double,
        updatedAt: Date,
        summary: DeepSeekUsageSummary? = nil,
        detailedUsageState: DeepSeekDetailedUsageState? = nil,
        continuation: DeepSeekWideHistoryContinuation? = nil,
        disposition: DeepSeekHistoryRefreshDisposition? = nil) -> ProviderFetchOutcome
    {
        let usage = self.makeDeepSeekBalance(balance, summary: summary, state: detailedUsageState, updatedAt: updatedAt)
            .toUsageSnapshot()
        return ProviderFetchOutcome(
            result: .success(ProviderFetchResult(
                usage: usage,
                credits: nil,
                dashboard: nil,
                sourceLabel: "api",
                strategyID: "deepseek.api",
                strategyKind: .apiToken,
                deepseekHistoryContinuation: continuation,
                deepseekHistoryRefreshDisposition: disposition)),
            attempts: [])
    }

    static func makeWideOutcome(
        balance: Double = 10.0,
        updatedAt: Date,
        profileID: String? = "chrome:Default",
        digest: String? = "digest-owner-1",
        plan: DeepSeekHistoryPlan,
        recentFold: DeepSeekChunkFoldResult,
        fetchChunk: @escaping @Sendable (DeepSeekUsageWindow) async throws -> DeepSeekChunkFoldResult)
        -> ProviderFetchOutcome
    {
        self.makeDeepSeekOutcome(
            balance: balance,
            updatedAt: updatedAt,
            summary: DeepSeekUsageCostParser.mergeByAPIKeyChunks([recentFold], plan: plan),
            continuation: DeepSeekWideHistoryContinuation(
                metadata: DeepSeekHistorySessionMetadata(
                    profileID: profileID,
                    ownerTokenDigest: digest,
                    plan: plan,
                    recentFold: recentFold),
                fetchChunk: fetchChunk))
    }

    static func makeTransientScope(
        profileID: String?,
        digest: String?,
        days: Int = 90) throws -> DeepSeekTransientOptionalDetailScope
    {
        try #require(DeepSeekTransientOptionalDetailScope(
            profileID: profileID,
            ownerTokenDigest: digest,
            period: .rolling(days: days),
            bucketTimeZoneIdentifier: "UTC"))
    }

    static func chunkPayload(
        url: URL,
        time: Int,
        tokens: Int,
        cost: String,
        requests: Int,
        keyID: String = "k1",
        model: String = "deepseek-chat") -> Data
    {
        if url.path.hasSuffix("/amount") {
            return self.amountJSON(series: [self.amountSeries(
                keyID: keyID,
                model: model,
                buckets: [(time, tokens, requests)])])
        }
        return self.costJSON(blocks: [("USD", [self.costSeries(
            keyID: keyID,
            model: model,
            buckets: [(time, cost)])])])
    }

    static func monthlyFallbackPayload(
        url: URL,
        date: String,
        tokens: Int,
        cost: String) -> Data
    {
        let isAmount = url.path.hasSuffix("/amount")
        let usage: [[String: Any]] = [[
            "model": "deepseek-chat",
            "usage": [["type": "RESPONSE_TOKEN", "amount": isAmount ? "\(tokens)" : cost]],
        ]]
        let block: [String: Any] = [
            "total": usage,
            "days": [["date": date, "data": usage]],
            "currency": "USD",
        ]
        let payload: [String: Any] = [
            "code": 0,
            "data": ["biz_code": 0, "biz_data": isAmount ? block as Any : [block] as Any],
        ]
        return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
    }

    static func calendar(_ zone: String) throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: zone))
        return calendar
    }

    static func query(_ request: URLRequest) throws -> [String: String] {
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    static func emptyByKeyJSON(isAmount: Bool) -> Data {
        let raw = isAmount
            ? #"{"code":0,"data":{"biz_code":0,"biz_data":{"series":[],"function_series":[]}}}"#
            : #"{"code":0,"data":{"biz_code":0,"biz_data":{"data":[]}}}"#
        return Data(raw.utf8)
    }

    /// Newest page: 100 tokens / $1. Oldest page: 200 tokens / $2 / 2 requests. Other pages return valid empty series.
    static func edgePagesWithEmptyMiddle(
        chunk0: DeepSeekUsageWindow,
        chunk2: DeepSeekUsageWindow,
        newestRequests: Int = 1) -> DeepSeekTestScriptedTransport.BodyBuilder
    {
        { url, start, end in
            if start == chunk0.startSeconds, end == chunk0.endSeconds {
                return Self.chunkPayload(
                    url: url,
                    time: chunk0.endSeconds - 43200,
                    tokens: 100,
                    cost: "1.0",
                    requests: newestRequests)
            }
            if start == chunk2.startSeconds, end == chunk2.endSeconds {
                return Self.chunkPayload(
                    url: url,
                    time: chunk2.startSeconds + 43200,
                    tokens: 200,
                    cost: "2.0",
                    requests: 2)
            }
            return Self.emptyByKeyJSON(isAmount: url.path.hasSuffix("/amount"))
        }
    }

    static func amountSeries(
        keyID: String,
        model: String,
        buckets: [(time: Int, tokens: Int, requests: Int)]) -> [String: Any]
    {
        [
            "api_key": keyID,
            "model": model,
            "buckets": buckets.map { bucket in
                [
                    "time": bucket.time,
                    "usage": [
                        "RESPONSE_TOKEN": "\(bucket.tokens)",
                        "REQUEST": "\(bucket.requests)",
                    ],
                ]
            },
        ]
    }

    static func amountJSON(
        series: [[String: Any]],
        functionBuckets: [(time: Int, calls: Int)] = []) -> Data
    {
        let functionSeries: [[String: Any]] = functionBuckets.isEmpty ? [] : [[
            "buckets": functionBuckets.map { bucket in
                ["time": bucket.time, "usage": ["FUNCTION_CALL": "\(bucket.calls)"]]
            },
        ]]
        let payload: [String: Any] = [
            "code": 0,
            "data": [
                "biz_code": 0,
                "biz_data": [
                    "series": series,
                    "function_series": functionSeries,
                ],
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
    }

    static func costSeries(
        keyID: String,
        model: String,
        buckets: [(time: Int, cost: String)]) -> [String: Any]
    {
        [
            "api_key": keyID,
            "model": model,
            "buckets": buckets.map { ["time": $0.time, "cost": $0.cost] },
        ]
    }

    static func costJSON(blocks: [(currency: String, series: [[String: Any]])]) -> Data {
        let payload: [String: Any] = [
            "code": 0,
            "data": [
                "biz_code": 0,
                "biz_data": [
                    "data": blocks.map { ["currency": $0.currency, "series": $0.series] },
                ],
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
    }
}

actor DeepSeekTestScriptedTransport: ProviderHTTPTransport {
    typealias StatusOverride = @Sendable (URL, Int, Int) -> Int
    typealias BodyBuilder = @Sendable (URL, Int, Int) -> Data
    typealias BeforeResponse = @Sendable (URL, Int, Int) async throws -> Void

    private let statusOverride: StatusOverride?
    private let bodyBuilder: BodyBuilder?
    private let beforeResponse: BeforeResponse?
    private(set) var requests: [URLRequest] = []
    private(set) var totalResponseBytes = 0

    init(
        statusOverride: StatusOverride? = nil,
        bodyBuilder: BodyBuilder? = nil,
        beforeResponse: BeforeResponse? = nil)
    {
        self.statusOverride = statusOverride
        self.bodyBuilder = bodyBuilder
        self.beforeResponse = beforeResponse
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        self.requests.append(request)
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        let start = items["start"].flatMap(Int.init) ?? 0
        let end = items["end"].flatMap(Int.init) ?? 0
        if let beforeResponse = self.beforeResponse {
            try await beforeResponse(url, start, end)
        }
        let status = self.statusOverride?(url, start, end) ?? 200
        let body: Data = if status == 200 {
            self.bodyBuilder?(url, start, end)
                ?? DeepSeekLongHistoryTests.emptyByKeyJSON(isAmount: url.path.hasSuffix("/amount"))
        } else {
            Data()
        }
        self.totalResponseBytes += body.count
        return try (body, #require(HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil)))
    }
}

actor DeepSeekTestCounterBox {
    private(set) var value = 0
    func increment() { self.value += 1 }
    func add(_ delta: Int) { self.value += delta }
}

actor DeepSeekTestFlagBox {
    private(set) var value: Bool
    init(_ initial: Bool) { self.value = initial }
    func set(_ newValue: Bool) { self.value = newValue }
}

actor DeepSeekTestWindowCounterBox {
    private var counts: [DeepSeekUsageWindow: Int] = [:]
    func increment(_ window: DeepSeekUsageWindow) { self.counts[window, default: 0] += 1 }
    func count(_ window: DeepSeekUsageWindow) -> Int { self.counts[window, default: 0] }
}

final class DeepSeekTestClockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date) { self.date = date }

    var current: Date {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.date
    }

    func set(_ newDate: Date) {
        self.lock.lock()
        self.date = newDate
        self.lock.unlock()
    }
}

actor DeepSeekTestChunkGate {
    private var released = false
    private var pausedWindows: Set<DeepSeekUsageWindow> = []
    private var pauseWaiters: [DeepSeekUsageWindow: [CheckedContinuation<Void, Never>]] = [:]
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellableReleaseWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    func waitForRelease(window: DeepSeekUsageWindow) async {
        self.pausedWindows.insert(window)
        for waiter in self.pauseWaiters.removeValue(forKey: window) ?? [] {
            waiter.resume()
        }
        guard !self.released else { return }
        await withCheckedContinuation { continuation in
            self.releaseWaiters.append(continuation)
        }
    }

    func waitForReleaseOrCancel(window: DeepSeekUsageWindow) async throws {
        self.pausedWindows.insert(window)
        for waiter in self.pauseWaiters.removeValue(forKey: window) ?? [] {
            waiter.resume()
        }
        try Task.checkCancellation()
        guard !self.released else { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await self.suspendCancellableWaiter(id: id)
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
    }

    private func suspendCancellableWaiter(id: UUID) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            if Task.isCancelled {
                continuation.resume(throwing: CancellationError())
                return
            }
            if self.released {
                continuation.resume()
                return
            }
            self.cancellableReleaseWaiters[id] = continuation
        }
    }

    private func cancelWaiter(id: UUID) {
        self.cancellableReleaseWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    func waitForReleaseIgnoringCancellation(window: DeepSeekUsageWindow) async {
        await self.waitForRelease(window: window)
    }

    func waitUntilPaused(window: DeepSeekUsageWindow) async {
        if self.pausedWindows.contains(window) { return }
        await withCheckedContinuation { continuation in
            self.pauseWaiters[window, default: []].append(continuation)
        }
    }

    func releaseAll() {
        self.released = true
        let waiters = self.releaseWaiters
        self.releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        let cancellable = Array(self.cancellableReleaseWaiters.values)
        self.cancellableReleaseWaiters.removeAll()
        for waiter in cancellable {
            waiter.resume()
        }
    }
}
