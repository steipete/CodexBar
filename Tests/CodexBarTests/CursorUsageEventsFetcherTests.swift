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

        let report = CursorUsageEventsFetcher.makeDailyReport(from: events, calendar: Self.utcCalendar)

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

        let report = CursorUsageEventsFetcher.makeDailyReport(from: events, calendar: Self.utcCalendar)

        #expect(report.data.count == 1)
        #expect(report.data[0].requestCount == 1)
        #expect(Self.approxEqual(report.data[0].costUSD, 0.12))
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

        let report = CursorUsageEventsFetcher.makeDailyReport(from: [event], calendar: calendar)
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

    @Test(arguments: [
        #"{"totalUsageEventsCount":0}"#,
        #"{"totalUsageEventsCount":0,"usageEventsDisplay":{}}"#,
        #"{"error":"temporarily unavailable"}"#,
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

        let report = CursorUsageEventsFetcher.makeDailyReport(from: [event], calendar: Self.utcCalendar)

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

        let report = CursorUsageEventsFetcher.makeDailyReport(from: [event], calendar: Self.utcCalendar)

        #expect(report.data.count == 1)
        #expect(report.data[0].inputTokens == 5)
        #expect(report.data[0].costUSD == nil)
        #expect(report.data[0].modelBreakdowns?.first?.costUSD == nil)
        #expect(report.summary?.totalCostUSD == nil)
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

        let report = CursorUsageEventsFetcher.makeDailyReport(from: events, calendar: Self.utcCalendar)

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

    // MARK: - Fetching

    @Test
    func `fetchUsage paginates, dedupes, sums metered cents, and sends Origin and Cookie headers`() async throws {
        // swiftlint:disable line_length
        let firstEvent = #"""
        {"timestamp":"1700000000000","model":"claude-4.5-sonnet","tokenUsage":{"inputTokens":100,"outputTokens":50,"cacheWriteTokens":0,"cacheReadTokens":0,"totalCents":100},"chargedCents":4}
        """#
        let secondEvent = #"""
        {"timestamp":"1700003600000","model":"gpt-5","tokenUsage":{"inputTokens":10,"outputTokens":5,"cacheWriteTokens":0,"cacheReadTokens":0,"totalCents":50},"chargedCents":4}
        """#
        // 1_700_005_400_000 is 2023-11-14T23:43:20Z: a distinct event still inside the same UTC day.
        let thirdEvent = #"""
        {"timestamp":"1700005400000","model":"gpt-5","tokenUsage":{"inputTokens":1,"outputTokens":1,"cacheWriteTokens":0,"cacheReadTokens":0,"totalCents":25},"chargedCents":8}
        """#
        // swiftlint:enable line_length

        let transport = ProviderHTTPTransportStub { request in
            switch Self.requestedPage(request) {
            case 1:
                // Full page of two distinct events; total signals one more remains.
                Self.httpResponse("""
                {"totalUsageEventsCount":3,"usageEventsDisplay":[\(firstEvent),\(secondEvent)]}
                """)
            case 2:
                // Second event repeats (must dedupe) alongside one new event.
                Self.httpResponse("""
                {"totalUsageEventsCount":3,"usageEventsDisplay":[\(secondEvent),\(thirdEvent)]}
                """)
            default:
                Self.httpResponse(#"{"totalUsageEventsCount":3,"usageEventsDisplay":[]}"#)
            }
        }

        let fetcher = CursorUsageEventsFetcher(
            baseURL: Self.baseURL,
            transport: transport,
            pageSize: 2)
        let result = try await fetcher.fetchUsage(
            cookieHeader: "WorkosCursorSessionToken=abc",
            since: nil,
            until: nil,
            calendar: Self.utcCalendar)

        // Three unique events across one UTC day -> one entry with two models.
        #expect(result.daily.data.count == 1)
        #expect(result.daily.data[0].requestCount == 3)
        #expect(Self.approxEqual(result.daily.data[0].costUSD, 1.75))
        // Metered total dedupes the same way: (4 + 4 + 8) cents -> $0.16.
        #expect(Self.approxEqual(result.meteredCostUSD, 0.16))

        let requests = await transport.requests()
        #expect(requests.count == 3)
        for request in requests {
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/api/dashboard/get-filtered-usage-events")
            #expect(request.value(forHTTPHeaderField: "Origin") == "https://cursor.test")
            #expect(request.value(forHTTPHeaderField: "Cookie") == "WorkosCursorSessionToken=abc")
            let body = try #require(request.httpBody)
            let fields = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(fields["teamId"] == nil)
        }
    }

    @Test
    func `pagination preserves rows with matching tokens but distinct billing fields`() async throws {
        // swiftlint:disable line_length
        let first = #"{"timestamp":"1700000000000","model":"gpt-5","kind":"USAGE_EVENT_KIND_USAGE_BASED","owningUser":"42","tokenUsage":{"inputTokens":10,"outputTokens":5,"cacheWriteTokens":0,"cacheReadTokens":0,"totalCents":50},"chargedCents":4}"#
        let second = #"{"timestamp":"1700000000000","model":"gpt-5","kind":"USAGE_EVENT_KIND_USAGE_BASED","owningUser":"42","tokenUsage":{"inputTokens":10,"outputTokens":5,"cacheWriteTokens":0,"cacheReadTokens":0,"totalCents":75},"chargedCents":8}"#
        // swiftlint:enable line_length
        let transport = ProviderHTTPTransportStub { request in
            switch Self.requestedPage(request) {
            case 1:
                Self.httpResponse("{\"totalUsageEventsCount\":2,\"usageEventsDisplay\":[\(first)]}")
            case 2:
                Self.httpResponse("{\"totalUsageEventsCount\":2,\"usageEventsDisplay\":[\(second)]}")
            default:
                Self.httpResponse(#"{"totalUsageEventsCount":2,"usageEventsDisplay":[]}"#)
            }
        }
        let fetcher = CursorUsageEventsFetcher(
            baseURL: Self.baseURL,
            transport: transport,
            pageSize: 1,
            maxPages: 3)

        let result = try await fetcher.fetchUsage(
            cookieHeader: "WorkosCursorSessionToken=abc",
            since: nil,
            until: nil,
            calendar: Self.utcCalendar)

        #expect(result.daily.data.first?.requestCount == 2)
        #expect(Self.approxEqual(result.daily.data.first?.costUSD, 1.25))
        #expect(Self.approxEqual(result.meteredCostUSD, 0.12))
    }

    @Test
    func `pagination preserves identical rows when the reported count includes both`() async throws {
        // swiftlint:disable line_length
        let event = #"{"timestamp":"1700000000000","model":"gpt-5","tokenUsage":{"inputTokens":10,"outputTokens":5,"cacheWriteTokens":0,"cacheReadTokens":0,"totalCents":50},"chargedCents":4}"#
        // swiftlint:enable line_length
        let transport = ProviderHTTPTransportStub { request in
            if Self.requestedPage(request) <= 2 {
                return Self.httpResponse("{\"totalUsageEventsCount\":2,\"usageEventsDisplay\":[\(event)]}")
            }
            return Self.httpResponse(#"{"totalUsageEventsCount":2,"usageEventsDisplay":[]}"#)
        }
        let fetcher = CursorUsageEventsFetcher(
            baseURL: Self.baseURL,
            transport: transport,
            pageSize: 1,
            maxPages: 3)

        let result = try await fetcher.fetchUsage(
            cookieHeader: "WorkosCursorSessionToken=abc",
            since: nil,
            until: nil,
            calendar: Self.utcCalendar)

        #expect(result.daily.data.first?.requestCount == 2)
        #expect(Self.approxEqual(result.daily.data.first?.costUSD, 1.0))
        #expect(Self.approxEqual(result.meteredCostUSD, 0.08))
    }

    @Test
    func `pagination fails closed when a full safety cap page reaches the raw total`() async {
        // swiftlint:disable line_length
        let first = #"{"timestamp":"1700000000000","model":"gpt-5","tokenUsage":{"inputTokens":10,"outputTokens":5,"cacheWriteTokens":0,"cacheReadTokens":0,"totalCents":50},"chargedCents":4}"#
        let second = #"{"timestamp":"1700000001000","model":"gpt-5","tokenUsage":{"inputTokens":20,"outputTokens":5,"cacheWriteTokens":0,"cacheReadTokens":0,"totalCents":75},"chargedCents":8}"#
        let third = #"{"timestamp":"1700000002000","model":"gpt-5","tokenUsage":{"inputTokens":30,"outputTokens":5,"cacheWriteTokens":0,"cacheReadTokens":0,"totalCents":100},"chargedCents":12}"#
        // swiftlint:enable line_length
        let transport = ProviderHTTPTransportStub { request in
            switch Self.requestedPage(request) {
            case 1:
                Self.httpResponse("{\"totalUsageEventsCount\":4,\"usageEventsDisplay\":[\(first),\(second)]}")
            default:
                Self.httpResponse("{\"totalUsageEventsCount\":4,\"usageEventsDisplay\":[\(second),\(third)]}")
            }
        }
        let fetcher = CursorUsageEventsFetcher(
            baseURL: Self.baseURL,
            transport: transport,
            pageSize: 2,
            maxPages: 2)

        let error = await #expect(throws: CostUsageError.self) {
            _ = try await fetcher.fetchUsage(
                cookieHeader: "WorkosCursorSessionToken=abc",
                since: nil,
                until: nil,
                calendar: Self.utcCalendar)
        }
        guard case let .cursorPaginationIncomplete(expected, received) = error else {
            Issue.record("Expected cursorPaginationIncomplete")
            return
        }
        #expect(expected == 4)
        #expect(received == 4)
    }

    @Test
    func `pagination fails closed when the reported total changes between pages`() async {
        // swiftlint:disable line_length
        let first = #"{"timestamp":"1700000000000","model":"gpt-5","tokenUsage":{"inputTokens":10,"outputTokens":5,"cacheWriteTokens":0,"cacheReadTokens":0,"totalCents":50},"chargedCents":4}"#
        let second = #"{"timestamp":"1700000001000","model":"gpt-5","tokenUsage":{"inputTokens":20,"outputTokens":5,"cacheWriteTokens":0,"cacheReadTokens":0,"totalCents":75},"chargedCents":8}"#
        // swiftlint:enable line_length
        let transport = ProviderHTTPTransportStub { request in
            if Self.requestedPage(request) == 1 {
                return Self.httpResponse("{\"totalUsageEventsCount\":1,\"usageEventsDisplay\":[\(first)]}")
            }
            return Self.httpResponse("{\"totalUsageEventsCount\":2,\"usageEventsDisplay\":[\(second)]}")
        }
        let fetcher = CursorUsageEventsFetcher(
            baseURL: Self.baseURL,
            transport: transport,
            pageSize: 1,
            maxPages: 2)

        let error = await #expect(throws: CostUsageError.self) {
            _ = try await fetcher.fetchUsage(
                cookieHeader: "WorkosCursorSessionToken=abc",
                since: nil,
                until: nil,
                calendar: Self.utcCalendar)
        }
        guard case let .cursorPaginationInconsistent(expected, received) = error else {
            Issue.record("Expected cursorPaginationInconsistent")
            return
        }
        #expect(expected == 1)
        #expect(received == 2)
    }

    @Test
    func `cost report carries the exact fetched credential scope`() async throws {
        let transport = ProviderHTTPTransportStub { _ in
            Self.httpResponse(#"{"totalUsageEventsCount":0,"usageEventsDisplay":[]}"#)
        }
        let probe = CursorStatusProbe(
            baseURL: Self.baseURL,
            timeout: 1,
            browserDetection: BrowserDetection(cacheTTL: 0),
            urlSession: transport)
        let cookie = "WorkosCursorSessionToken=abc"

        let report = try await probe.fetchCostReport(
            since: nil,
            until: nil,
            cookieHeaderOverride: cookie)

        #expect(report.credentialScopeFingerprint == CookieHeaderCache.credentialFingerprint(cookie))
    }

    @Test
    func `fetchUsage fails instead of publishing a truncated pagination window`() async {
        // swiftlint:disable line_length
        let event = #"{"timestamp":"1700000000000","model":"gpt-5","tokenUsage":{"inputTokens":10,"outputTokens":5,"cacheWriteTokens":0,"cacheReadTokens":0,"totalCents":50},"chargedCents":4}"#
        // swiftlint:enable line_length
        let transport = ProviderHTTPTransportStub { _ in
            Self.httpResponse("{\"totalUsageEventsCount\":2,\"usageEventsDisplay\":[\(event)]}")
        }
        let fetcher = CursorUsageEventsFetcher(
            baseURL: Self.baseURL,
            transport: transport,
            pageSize: 1,
            maxPages: 1)

        let error = await #expect(throws: CostUsageError.self) {
            _ = try await fetcher.fetchUsage(
                cookieHeader: "WorkosCursorSessionToken=abc",
                since: nil,
                until: nil,
                calendar: Self.utcCalendar)
        }
        guard case let .cursorPaginationIncomplete(expected, received) = error else {
            Issue.record("Expected cursorPaginationIncomplete")
            return
        }
        #expect(expected == 2)
        #expect(received == 1)
    }

    @Test
    func `fetchUsage reports nil metered total when events omit chargedCents`() async throws {
        // swiftlint:disable line_length
        let event = #"""
        {"timestamp":"1700000000000","model":"gpt-5","tokenUsage":{"inputTokens":10,"outputTokens":5,"cacheWriteTokens":0,"cacheReadTokens":0,"totalCents":50}}
        """#
        // swiftlint:enable line_length
        let transport = ProviderHTTPTransportStub { _ in
            Self.httpResponse("{\"totalUsageEventsCount\":1,\"usageEventsDisplay\":[\(event)]}")
        }

        let fetcher = CursorUsageEventsFetcher(baseURL: Self.baseURL, transport: transport, pageSize: 2)
        let result = try await fetcher.fetchUsage(
            cookieHeader: "WorkosCursorSessionToken=abc",
            since: nil,
            until: nil,
            calendar: Self.utcCalendar)

        #expect(result.meteredCostUSD == nil)
        #expect(Self.approxEqual(result.daily.data.first?.costUSD, 0.50))
    }

    @Test
    func `fetchUsage surfaces not logged in on 401`() async {
        let transport = ProviderHTTPTransportStub { _ in
            Self.httpResponse(#"{"error":"unauthorized"}"#, statusCode: 401)
        }
        let fetcher = CursorUsageEventsFetcher(baseURL: Self.baseURL, transport: transport)

        let error = await #expect(throws: CursorStatusProbeError.self) {
            _ = try await fetcher.fetchUsage(cookieHeader: "x=y", since: nil, until: nil)
        }
        let isNotLoggedIn = error.map { thrown in
            if case .notLoggedIn = thrown {
                return true
            }
            return false
        } ?? false
        #expect(isNotLoggedIn)
    }

    @Test
    func `fetchUsage preserves a 403 as a non authentication failure`() async {
        let transport = ProviderHTTPTransportStub { _ in
            Self.httpResponse(#"{"error":"forbidden"}"#, statusCode: 403)
        }
        let fetcher = CursorUsageEventsFetcher(baseURL: Self.baseURL, transport: transport)

        let error = await #expect(throws: CursorStatusProbeError.self) {
            _ = try await fetcher.fetchUsage(cookieHeader: "x=y", since: nil, until: nil)
        }
        guard case let .networkError(message) = error else {
            Issue.record("Expected networkError")
            return
        }
        #expect(message == "HTTP 403")
    }

    @Test
    func `cost fetcher reports Cursor as a supported token-snapshot provider`() {
        #expect(CostUsageFetcher.supportsTokenSnapshot(.cursor))
    }
}
#endif
