import Foundation
import Testing
@testable import CodexBarCore

#if os(macOS)
@Suite(.serialized)
struct CursorUsageEventsFetcherTests {
    // MARK: - Helpers

    private static let baseURL = URL(string: "https://cursor.test")!

    /// Calendar pinned to UTC so timestamp-to-day grouping is deterministic across machines.
    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// Cost math runs through `cents / 100`, so compare with a tolerance rather than `==`.
    private static func approxEqual(_ actual: Double?, _ expected: Double, tolerance: Double = 1e-9) -> Bool {
        guard let actual else { return false }
        return abs(actual - expected) < tolerance
    }

    private static func httpResponse(_ body: String, statusCode: Int = 200) -> (Data, URLResponse) {
        let response = HTTPURLResponse(
            url: baseURL,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!
        return (Data(body.utf8), response)
    }

    private static func event(
        timestampMS: Int64,
        model: String,
        input: Int = 0,
        output: Int = 0,
        cacheWrite: Int = 0,
        cacheRead: Int = 0,
        totalCents: Double?,
        isChargeable: Bool? = nil,
        chargedCents: Double? = nil) -> CursorUsageEvent
    {
        CursorUsageEvent(
            timestampMS: timestampMS,
            model: model,
            tokenUsage: CursorEventTokenUsage(
                inputTokens: input,
                outputTokens: output,
                cacheWriteTokens: cacheWrite,
                cacheReadTokens: cacheRead,
                totalCents: totalCents),
            isChargeable: isChargeable,
            chargedCents: chargedCents)
    }

    /// Reads the `page` field from a stubbed request body so the handler can return pages.
    private struct PageProbe: Decodable {
        let page: Int?
    }

    private static func requestedPage(_ request: URLRequest) -> Int {
        guard let body = request.httpBody,
              let probe = try? JSONDecoder().decode(PageProbe.self, from: body)
        else { return 1 }
        return probe.page ?? 1
    }

    private static func makeDailyReport(
        from events: [CursorUsageEvent],
        calendar: Calendar) -> CostUsageDailyReport
    {
        CursorUsageEventsFetcher.makeDailyReport(
            from: events, calendar: calendar, modelsDevCatalog: ModelsDevCatalog(providers: [:]))
    }

    // MARK: - Mapping

    @Test
    func `makeDailyReport groups events by local day and model with cents converted to USD`() {
        // 2023-11-14T22:13:20Z and one hour later share a UTC day; the third event is two days later.
        let day1 = Int64(1_700_000_000_000)
        let day1Later = day1 + 3_600_000
        let day3 = day1 + 172_800_000

        let events = [
            Self.event(timestampMS: day1, model: "claude-4.5-sonnet", input: 100, output: 50, totalCents: 100),
            Self.event(timestampMS: day1Later, model: "claude-4.5-sonnet", input: 10, output: 5, totalCents: 23),
            Self.event(timestampMS: day1, model: "gpt-5", input: 200, output: 20, totalCents: 500),
            Self.event(timestampMS: day3, model: "claude-4.5-sonnet", input: 1, output: 1, totalCents: 9),
        ]

        let report = Self.makeDailyReport(from: events, calendar: Self.utcCalendar)

        #expect(report.data.count == 2)

        let firstDay = report.data[0]
        #expect(firstDay.date == "2023-11-14")
        // Two models on day one; the gpt-5 row is more expensive so it sorts first.
        #expect(firstDay.modelBreakdowns?.count == 2)
        #expect(firstDay.modelBreakdowns?.first?.modelName == "gpt-5")
        #expect(firstDay.modelsUsed == ["claude-4.5-sonnet", "gpt-5"])
        // claude rows merge: (100 + 23) cents, gpt-5 row: 500 cents -> $6.23 total for the day.
        #expect(Self.approxEqual(firstDay.costUSD, 6.23))
        #expect(firstDay.requestCount == 3)
        #expect(firstDay.totalTokens == 100 + 50 + 10 + 5 + 200 + 20)

        let claudeBreakdown = firstDay.modelBreakdowns?.first { $0.modelName == "claude-4.5-sonnet" }
        #expect(Self.approxEqual(claudeBreakdown?.costUSD, 1.23))
        #expect(claudeBreakdown?.requestCount == 2)

        let lastDay = report.data[1]
        #expect(lastDay.date == "2023-11-16")
        #expect(Self.approxEqual(lastDay.costUSD, 0.09))

        // Summary aggregates every day.
        #expect(Self.approxEqual(report.summary?.totalCostUSD, 6.32))
    }

    @Test
    func `makeDailyReport skips events without token usage`() {
        let events = [
            Self.event(timestampMS: 1_700_000_000_000, model: "claude-4.5-sonnet", totalCents: 0),
            Self.event(timestampMS: 1_700_000_000_000, model: "claude-4.5-sonnet", input: 5, totalCents: 12),
        ]

        let report = Self.makeDailyReport(from: events, calendar: Self.utcCalendar)

        #expect(report.data.count == 1)
        #expect(report.data[0].requestCount == 1)
        #expect(Self.approxEqual(report.data[0].costUSD, 0.12))
    }

    @Test
    func `make daily report prices unreported cursor events from the shared catalog`() {
        let report = Self.makeDailyReport(
            from: [
                Self.event(timestampMS: 1_700_000_000_000, model: "gpt-5", input: 200, output: 20, totalCents: nil),
            ],
            calendar: Self.utcCalendar)

        let day = report.data.first
        #expect(day?.requestCount == 1)
        #expect(day?.estimatedRequestCount == 1)
        // Bundled list pricing: 200 input tokens at $1.25/M plus 20 output tokens at $10/M.
        #expect(Self.approxEqual(day?.costUSD, 0.00045))
    }

    @Test
    func `meteredCostUSD rejects a partial sum when an event omits chargedCents`() {
        let events = [
            Self.event(timestampMS: 1_700_000_000_000, model: "claude", input: 5, totalCents: 994, chargedCents: 4),
            Self.event(timestampMS: 1_700_000_001_000, model: "gpt-5", input: 5, totalCents: 500, chargedCents: 8),
            Self.event(timestampMS: 1_700_000_002_000, model: "default", input: 5, totalCents: 12),
        ]

        #expect(CursorUsageEventsFetcher.meteredCostUSD(from: events) == nil)
    }

    @Test
    func `meteredCostUSD returns nil when no event reports chargedCents`() {
        let events = [
            Self.event(timestampMS: 1_700_000_000_000, model: "claude", input: 5, totalCents: 994),
        ]

        #expect(CursorUsageEventsFetcher.meteredCostUSD(from: events) == nil)
    }

    @Test
    func `meteredCostUSD includes plan consumption not marked additionally chargeable`() {
        let events = [
            Self.event(
                timestampMS: 1_700_000_000_000,
                model: "claude",
                input: 5,
                totalCents: 994,
                isChargeable: false,
                chargedCents: 40),
            Self.event(
                timestampMS: 1_700_000_001_000,
                model: "gpt-5",
                input: 5,
                totalCents: 500,
                isChargeable: true,
                chargedCents: 8),
            Self.event(
                timestampMS: 1_700_000_002_000,
                model: "legacy",
                input: 5,
                totalCents: 100,
                chargedCents: 4),
        ]

        // Cursor's dashboard reconciliation sums chargedCents even for included-plan events.
        #expect(Self.approxEqual(CursorUsageEventsFetcher.meteredCostUSD(from: events), 0.52))
    }

    // MARK: - Snapshot

    @Test
    func `session cost tracks the current local day, not the latest entry`() throws {
        // Cursor labels the session line "Today", so a stale latest day must not leak into it. This
        // mirrors loadCursorTokenSnapshot, which builds the snapshot with current-local-day semantics.
        let calendar = Calendar.current
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 5, day: 18, hour: 12)))
        let twoDaysAgo = try #require(calendar.date(byAdding: .day, value: -2, to: now))
        let event = Self.event(
            timestampMS: Int64(twoDaysAgo.timeIntervalSince1970 * 1000),
            model: "claude-4.5-sonnet",
            input: 100,
            output: 50,
            totalCents: 150)

        let report = Self.makeDailyReport(from: [event], calendar: calendar)
        let snapshot = CostUsageFetcher.tokenSnapshot(from: report, now: now, useCurrentLocalDayForSession: true)

        // No usage today -> session is zero, while the window total still reflects the older day.
        #expect(snapshot.sessionCostUSD == 0)
        #expect(snapshot.sessionTokens == 0)
        #expect(Self.approxEqual(snapshot.last30DaysCostUSD, 1.5))
    }

    // MARK: - Decoding

    @Test
    func `decodes string-encoded numbers leniently`() throws {
        let json = """
        {
          "totalUsageEventsCount": "2",
          "usageEventsDisplay": [
            {
              "timestamp": "1700000000000",
              "model": "claude-4.5-sonnet",
              "tokenUsage": {
                "inputTokens": "100",
                "outputTokens": 50,
                "cacheWriteTokens": "10",
                "cacheReadTokens": "5",
                "totalCents": "12.5"
              }
            }
          ]
        }
        """
        let page = try JSONDecoder().decode(CursorUsageEventsPage.self, from: Data(json.utf8))

        #expect(page.totalUsageEventsCount == 2)
        let event = try #require(page.usageEventsDisplay.first)
        #expect(event.timestampMS == 1_700_000_000_000)
        #expect(event.tokenUsage?.inputTokens == 100)
        #expect(event.tokenUsage?.cacheWriteTokens == 10)
        #expect(Self.approxEqual(event.tokenUsage?.totalCents, 12.5))
    }

    @Test
    func `page decoding accepts the literal empty query response`() throws {
        let page = try JSONDecoder().decode(CursorUsageEventsPage.self, from: Data("{}".utf8))

        #expect(page.totalUsageEventsCount == 0)
        #expect(page.usageEventsDisplay.isEmpty)
    }

    @Test(arguments: [0, 2])
    func `page decoding preserves the query count on omitted empty arrays`(count: Int) throws {
        let json = #"{"totalUsageEventsCount":\#(count)}"#
        let page = try JSONDecoder().decode(CursorUsageEventsPage.self, from: Data(json.utf8))
        #expect(page.totalUsageEventsCount == count)
        #expect(page.usageEventsDisplay.isEmpty)
    }

    @Test(arguments: [
        #"{"totalUsageEventsCount":0,"usageEventsDisplay":{}}"#,
        #"{"error":"temporarily unavailable"}"#,
        #"{"usageEventsDisplay":null}"#,
        #"{"unknown":null}"#,
        #"{"totalUsageEventsCount":0,"error":"unavailable"}"#,
        #"{"totalUsageEventsCount":null}"#,
        #"{"totalUsageEventsCount":"Infinity"}"#,
        #"{"totalUsageEventsCount":true}"#,
        #"{"totalUsageEventsCount":-1}"#,
        "[]",
        "null",
    ])
    func `page decoding rejects missing or malformed event arrays`(json: String) {
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(CursorUsageEventsPage.self, from: Data(json.utf8))
        }
    }

    @Test(arguments: ["-1", String(Int.min)])
    func `page decoding rejects negative event counts`(count: String) {
        let json = #"{"totalUsageEventsCount":\#(count),"usageEventsDisplay":[]}"#

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(CursorUsageEventsPage.self, from: Data(json.utf8))
        }
    }

    @Test
    func `invalid and out of range numeric fields fail closed without trapping`() throws {
        let json = """
        {
          "totalUsageEventsCount": "Infinity",
          "usageEventsDisplay": [
            {
              "timestamp": "Infinity",
              "model": "fixture-model",
              "chargedCents": "NaN",
              "tokenUsage": {
                "inputTokens": "Infinity",
                "outputTokens": "1e999",
                "cacheWriteTokens": "-Infinity",
                "cacheReadTokens": "NaN",
                "totalCents": "Infinity"
              }
            }
          ]
        }
        """
        let page = try JSONDecoder().decode(CursorUsageEventsPage.self, from: Data(json.utf8))
        let event = try #require(page.usageEventsDisplay.first)

        #expect(page.totalUsageEventsCount == nil)
        #expect(event.timestampMS == nil)
        #expect(event.chargedCents == nil)
        #expect(event.tokenUsage?.inputTokens == 0)
        #expect(event.tokenUsage?.outputTokens == 0)
        #expect(event.tokenUsage?.cacheWriteTokens == 0)
        #expect(event.tokenUsage?.cacheReadTokens == 0)
        #expect(event.tokenUsage?.totalCents == nil)
    }

    @Test
    func `reports skip events without a valid timestamp`() {
        let event = CursorUsageEvent(
            timestampMS: nil,
            model: "fixture-model",
            tokenUsage: CursorEventTokenUsage(
                inputTokens: 10,
                outputTokens: 5,
                cacheWriteTokens: 0,
                cacheReadTokens: 0,
                totalCents: 100),
            chargedCents: 25)

        let report = Self.makeDailyReport(from: [event], calendar: Self.utcCalendar)

        #expect(report.data.isEmpty)
        #expect(report.summary?.totalCostUSD == 0)
        #expect(CursorUsageEventsFetcher.meteredCostUSD(from: [event]) == nil)
    }

    @Test
    func `token totals fail closed on overflow`() {
        let usage = CursorEventTokenUsage(
            inputTokens: Int.max,
            outputTokens: 1,
            cacheWriteTokens: 0,
            cacheReadTokens: 0,
            totalCents: nil)

        #expect(usage.totalTokens == 0)
        #expect(!usage.hasTokens)
    }

    @Test
    func `reports preserve unknown cost when a token event omits total cents`() {
        let event = Self.event(
            timestampMS: 1_700_000_000_000,
            model: "fixture-model",
            input: 5,
            totalCents: nil)

        let report = Self.makeDailyReport(from: [event], calendar: Self.utcCalendar)

        #expect(report.data.count == 1)
        #expect(report.data[0].inputTokens == 5)
        #expect(report.data[0].costUSD == nil)
        #expect(report.data[0].modelBreakdowns?.first?.costUSD == nil)
        #expect(report.summary?.totalCostUSD == nil)
    }

    @Test
    func `reports price a known model when a sibling event omits total cents`() {
        let events = [
            Self.event(
                timestampMS: 1_700_000_000_000,
                model: "claude-4.5-sonnet",
                input: 5,
                totalCents: 100),
            Self.event(
                timestampMS: 1_700_000_001_000,
                model: "gpt-5",
                input: 7,
                totalCents: nil),
        ]

        let report = Self.makeDailyReport(from: events, calendar: Self.utcCalendar)
        let priced = report.data[0].modelBreakdowns?.first { $0.modelName == "claude-4.5-sonnet" }
        let unpriced = report.data[0].modelBreakdowns?.first { $0.modelName == "gpt-5" }

        #expect(report.data.count == 1)
        // Claude reports $1.00; gpt-5 (7 input tokens) is priced from the bundled catalog.
        #expect(Self.approxEqual(report.data[0].costUSD, 1.00000875))
        #expect(Self.approxEqual(priced?.costUSD, 1.0))
        #expect(Self.approxEqual(unpriced?.costUSD, 0.00000875))
        #expect(unpriced?.totalTokens == 7)
        #expect(Self.approxEqual(report.summary?.totalCostUSD, 1.00000875))
    }

    @Test
    func `reports do not revive a model cost after an invalid cents event`() {
        let events = [
            Self.event(
                timestampMS: 1_700_000_000_000,
                model: "gpt-5",
                input: 5,
                totalCents: 100),
            Self.event(
                timestampMS: 1_700_000_001_000,
                model: "gpt-5",
                input: 7,
                totalCents: -1),
            Self.event(
                timestampMS: 1_700_000_002_000,
                model: "gpt-5",
                input: 3,
                totalCents: 50),
        ]

        let report = Self.makeDailyReport(from: events, calendar: Self.utcCalendar)

        #expect(report.data.count == 1)
        #expect(report.data[0].costUSD == nil)
        #expect(report.data[0].modelBreakdowns?.first?.costUSD == nil)
        #expect(report.data[0].modelBreakdowns?.first?.totalTokens == 15)
        #expect(report.summary?.totalCostUSD == nil)
    }

    @Test
    func `reports price a known model on a day without reported cents`() {
        let events = [
            Self.event(
                timestampMS: 1_700_000_000_000,
                model: "claude-4.5-sonnet",
                input: 5,
                totalCents: 100),
            Self.event(
                timestampMS: 1_700_172_800_000,
                model: "gpt-5",
                input: 7,
                totalCents: nil),
        ]

        let report = Self.makeDailyReport(from: events, calendar: Self.utcCalendar)
        let priced = report.data.first { $0.costUSD != nil }
        let catalogPricedDay = report.data.first { $0.estimatedRequestCount == 1 }

        #expect(report.data.count == 2)
        #expect(Self.approxEqual(priced?.costUSD, 1.0))
        #expect(catalogPricedDay?.requestCount == 1)
        #expect(catalogPricedDay?.totalTokens == 7)
        #expect(Self.approxEqual(report.summary?.totalCostUSD, 1.00000875))
    }

    @Test
    func `estimates price cached claude tokens without double billing`() {
        // Cursor reports disjoint counters: input excludes cache. For Claude the
        // pricing bills input, cacheRead, and cacheCreation disjointly. The
        // fallback must not fold cache tokens into input for the Claude route.
        let event = Self.event(
            timestampMS: 1_700_000_000_000,
            model: "claude-sonnet-4-20250514",
            input: 100,
            output: 50,
            cacheWrite: 300,
            cacheRead: 200,
            totalCents: nil)
        let report = Self.makeDailyReport(from: [event], calendar: Self.utcCalendar)
        let expected = CostUsagePricing.claudeCostUSD(
            model: "claude-sonnet-4-20250514",
            inputTokens: 100,
            cacheReadInputTokens: 200,
            cacheCreationInputTokens: 300,
            outputTokens: 50,
            modelsDevCatalog: ModelsDevCatalog(providers: [:]))
        #expect(report.data.count == 1)
        #expect(report.data[0].estimatedRequestCount == 1)
        #expect(report.data[0].unpricedRequestCount == nil)
        #expect(Self.approxEqual(report.data[0].costUSD, expected ?? -1))
    }

    @Test
    func `estimates price cursor claude alias from bundled catalog`() {
        let event = Self.event(
            timestampMS: 1_700_000_000_000,
            model: "claude-4.5-sonnet",
            input: 100,
            output: 50,
            totalCents: nil)
        let report = Self.makeDailyReport(from: [event], calendar: Self.utcCalendar)
        let expected = CostUsagePricing.claudeCostUSD(
            model: "claude-sonnet-4-5",
            inputTokens: 100,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 0,
            outputTokens: 50,
            modelsDevCatalog: ModelsDevCatalog(providers: [:]))

        #expect(report.data.count == 1)
        #expect(report.data[0].estimatedRequestCount == 1)
        #expect(report.data[0].unpricedRequestCount == nil)
        #expect(Self.approxEqual(report.data[0].costUSD, expected ?? -1))
    }

    @Test
    func `mixed priced and catalog missing day counts unpriced requests`() {
        let events = [
            Self.event(
                timestampMS: 1_700_000_000_000,
                model: "claude-4.5-sonnet",
                input: 5,
                totalCents: 100),
            Self.event(
                timestampMS: 1_700_000_001_000,
                model: "fixture-model",
                input: 7,
                totalCents: nil),
        ]
        let report = Self.makeDailyReport(from: events, calendar: Self.utcCalendar)
        #expect(report.data.count == 1)
        // Only the Claude event has a price; the unknown model is absent from bundled tables.
        #expect(Self.approxEqual(report.data[0].costUSD, 1.0))
        #expect(report.data[0].requestCount == 2)
        #expect(report.data[0].unpricedRequestCount == 1)
        #expect(report.data[0].estimatedRequestCount == nil)
        let coverage = report.data[0].coverageCounts
        #expect(coverage.priced == 1)
        #expect(coverage.unpriced == 1)
        #expect(coverage.estimated == 0)
    }

    @Test
    func `mixed valid and rejected cost counts unpriced requests`() {
        let events = [
            Self.event(
                timestampMS: 1_700_000_000_000,
                model: "claude-4.5-sonnet",
                input: 5,
                totalCents: 100),
            Self.event(
                timestampMS: 1_700_000_001_000,
                model: "gpt-5",
                input: 7,
                totalCents: -1),
        ]
        let report = Self.makeDailyReport(from: events, calendar: Self.utcCalendar)
        #expect(report.data.count == 1)
        #expect(report.data[0].requestCount == 2)
        #expect(Self.approxEqual(report.data[0].costUSD, 1.0))
        #expect(report.data[0].unpricedRequestCount == 1)
        #expect(report.data[0].estimatedRequestCount == nil)
        let coverage = report.data[0].coverageCounts
        #expect(coverage.priced == 1)
        #expect(coverage.unpriced == 1)
        #expect(coverage.estimated == 0)
    }

    @Test
    func `same model valid and rejected costs preserve valid coverage`() {
        let events = [
            Self.event(timestampMS: 1_700_000_000_000, model: "gpt-5", input: 5, totalCents: 100),
            Self.event(timestampMS: 1_700_000_001_000, model: "gpt-5", input: 7, totalCents: -1),
        ]
        let report = Self.makeDailyReport(from: events, calendar: Self.utcCalendar)

        #expect(report.data.count == 1)
        #expect(report.data[0].requestCount == 2)
        #expect(report.data[0].costUSD == nil) // Aggregate fails closed.
        #expect(report.data[0].unpricedRequestCount == 1)
        let coverage = report.data[0].coverageCounts
        #expect(coverage.priced == 1) // The valid request remains visible.
        #expect(coverage.unpriced == 1)
    }

    @Test
    func `decoded json distinguishes omitted and null total cents from invalid values`() throws {
        // gpt-5 with 200 input, 20 output at catalog rates ($1.25/M in, $10/M out) -> $0.00045 / request
        let json = """
        {
          "totalUsageEventsCount": 4,
          "usageEventsDisplay": [
            {
              "timestamp": "1700000000000",
              "model": "gpt-5",
              "chargedCents": 10,
              "tokenUsage": {
                "inputTokens": 200,
                "outputTokens": 20,
                "cacheWriteTokens": 0,
                "cacheReadTokens": 0
              }
            },
            {
              "timestamp": "1700000001000",
              "model": "gpt-5",
              "chargedCents": 10,
              "tokenUsage": {
                "inputTokens": 200,
                "outputTokens": 20,
                "cacheWriteTokens": 0,
                "cacheReadTokens": 0,
                "totalCents": null
              }
            },
            {
              "timestamp": "1700000002000",
              "model": "gpt-5",
              "chargedCents": 10,
              "tokenUsage": {
                "inputTokens": 10,
                "outputTokens": 5,
                "cacheWriteTokens": 0,
                "cacheReadTokens": 0,
                "totalCents": 0
              }
            },
            {
              "timestamp": "1700000003000",
              "model": "gpt-5",
              "chargedCents": 10,
              "tokenUsage": {
                "inputTokens": 10,
                "outputTokens": 5,
                "cacheWriteTokens": 0,
                "cacheReadTokens": 0,
                "totalCents": "12.5"
              }
            }
          ]
        }
        """
        let page = try JSONDecoder().decode(CursorUsageEventsPage.self, from: Data(json.utf8))
        #expect(page.usageEventsDisplay.count == 4)

        // Verify metered cost is completely untouched (4 * 10 cents = $0.40)
        #expect(Self.approxEqual(CursorUsageEventsFetcher.meteredCostUSD(from: page.usageEventsDisplay), 0.40))

        let report = Self.makeDailyReport(from: page.usageEventsDisplay, calendar: Self.utcCalendar)
        #expect(report.data.count == 1)
        let day = report.data[0]
        #expect(day.requestCount == 4)
        #expect(day.estimatedRequestCount == 2) // 2 omitted/null events estimated
        #expect(day.unpricedRequestCount == nil)
        #expect(day.pricedRequestCount == 2) // 0 cents and 12.5 cents

        // Total cost: 2 * 0.00045 + 0.0 + 0.125 = 0.1259
        #expect(Self.approxEqual(day.costUSD, 0.1259))
        let coverage = day.coverageCounts
        #expect(coverage.priced == 2)
        #expect(coverage.estimated == 2)
        #expect(coverage.unpriced == 0)
    }

    @Test
    func `decoded json with nonfinite negative or malformed total cents stays unpriced and fails closed`() throws {
        let json = """
        {
          "totalUsageEventsCount": 6,
          "usageEventsDisplay": [
            {
              "timestamp": "1700000000000",
              "model": "gpt-5",
              "chargedCents": 5,
              "tokenUsage": {
                "inputTokens": 100,
                "outputTokens": 50,
                "cacheWriteTokens": 0,
                "cacheReadTokens": 0,
                "totalCents": 100
              }
            },
            {
              "timestamp": "1700000001000",
              "model": "gpt-5",
              "chargedCents": 5,
              "tokenUsage": {
                "inputTokens": 200,
                "outputTokens": 20,
                "cacheWriteTokens": 0,
                "cacheReadTokens": 0,
                "totalCents": "NaN"
              }
            },
            {
              "timestamp": "1700000002000",
              "model": "gpt-5",
              "chargedCents": 5,
              "tokenUsage": {
                "inputTokens": 200,
                "outputTokens": 20,
                "cacheWriteTokens": 0,
                "cacheReadTokens": 0,
                "totalCents": "Infinity"
              }
            },
            {
              "timestamp": "1700000003000",
              "model": "gpt-5",
              "chargedCents": 5,
              "tokenUsage": {
                "inputTokens": 200,
                "outputTokens": 20,
                "cacheWriteTokens": 0,
                "cacheReadTokens": 0,
                "totalCents": "-Infinity"
              }
            },
            {
              "timestamp": "1700000004000",
              "model": "gpt-5",
              "chargedCents": 5,
              "tokenUsage": {
                "inputTokens": 200,
                "outputTokens": 20,
                "cacheWriteTokens": 0,
                "cacheReadTokens": 0,
                "totalCents": -1
              }
            },
            {
              "timestamp": "1700000005000",
              "model": "gpt-5",
              "chargedCents": 5,
              "tokenUsage": {
                "inputTokens": 200,
                "outputTokens": 20,
                "cacheWriteTokens": 0,
                "cacheReadTokens": 0,
                "totalCents": "not-a-number"
              }
            }
          ]
        }
        """
        let page = try JSONDecoder().decode(CursorUsageEventsPage.self, from: Data(json.utf8))
        #expect(page.usageEventsDisplay.count == 6)

        // Metered cost remains unaffected (6 * 5 cents = $0.30)
        #expect(Self.approxEqual(CursorUsageEventsFetcher.meteredCostUSD(from: page.usageEventsDisplay), 0.30))

        let report = Self.makeDailyReport(from: page.usageEventsDisplay, calendar: Self.utcCalendar)
        #expect(report.data.count == 1)
        let day = report.data[0]
        #expect(day.requestCount == 6)
        #expect(day.costUSD == nil) // Aggregate fails closed because of invalid cents
        #expect(day.estimatedRequestCount == nil) // No estimates manufactured for invalid values!
        #expect(day.unpricedRequestCount == 5) // 5 invalid events are unpriced
        #expect(day.pricedRequestCount == 1) // 1 valid event preserved

        let coverage = day.coverageCounts
        #expect(coverage.priced == 1)
        #expect(coverage.unpriced == 5)
        #expect(coverage.estimated == 0)
    }

    @Test
    func `reports preserve unknown aggregate tokens on cross event overflow`() {
        let events = [
            Self.event(
                timestampMS: 1_700_000_000_000,
                model: "fixture-model",
                input: Int.max,
                totalCents: 1),
            Self.event(
                timestampMS: 1_700_000_001_000,
                model: "fixture-model",
                input: Int.max,
                totalCents: 1),
        ]

        let report = Self.makeDailyReport(from: events, calendar: Self.utcCalendar)

        #expect(report.data.count == 1)
        #expect(report.data[0].inputTokens == nil)
        #expect(report.data[0].totalTokens == nil)
        #expect(report.data[0].requestCount == 2)
        #expect(report.data[0].modelBreakdowns?.first?.totalTokens == nil)
        #expect(report.summary?.totalInputTokens == nil)
        #expect(report.summary?.totalTokens == nil)
        #expect(Self.approxEqual(report.summary?.totalCostUSD, 0.02))
    }

    @Test
    func `metered totals fail closed on overflow`() {
        let events = [
            Self.event(
                timestampMS: 1_700_000_000_000,
                model: "fixture-model",
                input: 1,
                totalCents: 1,
                chargedCents: Double.greatestFiniteMagnitude),
            Self.event(
                timestampMS: 1_700_000_001_000,
                model: "fixture-model",
                input: 1,
                totalCents: 1,
                chargedCents: Double.greatestFiniteMagnitude),
        ]

        #expect(CursorUsageEventsFetcher.meteredCostUSD(from: events) == nil)
    }
}
#endif
