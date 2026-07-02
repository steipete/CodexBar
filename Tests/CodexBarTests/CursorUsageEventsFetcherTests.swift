import Foundation
import Testing
@testable import CodexBarCore

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
    func `meteredCostUSD sums chargedCents and ignores events without it`() {
        // Two charged events (4c + 8c) plus one event with no chargedCents -> $0.12.
        let events = [
            Self.event(timestampMS: 1_700_000_000_000, model: "claude", input: 5, totalCents: 994, chargedCents: 4),
            Self.event(timestampMS: 1_700_000_001_000, model: "gpt-5", input: 5, totalCents: 500, chargedCents: 8),
            Self.event(timestampMS: 1_700_000_002_000, model: "default", input: 5, totalCents: 12),
        ]

        #expect(Self.approxEqual(CursorUsageEventsFetcher.meteredCostUSD(from: events), 0.12))
    }

    @Test
    func `meteredCostUSD returns nil when no event reports chargedCents`() {
        let events = [
            Self.event(timestampMS: 1_700_000_000_000, model: "claude", input: 5, totalCents: 994),
        ]

        #expect(CursorUsageEventsFetcher.meteredCostUSD(from: events) == nil)
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
            default:
                // Second event repeats (must dedupe) alongside one new event.
                Self.httpResponse("""
                {"totalUsageEventsCount":3,"usageEventsDisplay":[\(secondEvent),\(thirdEvent)]}
                """)
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
        #expect(requests.count == 2)
        for request in requests {
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/api/dashboard/get-filtered-usage-events")
            #expect(request.value(forHTTPHeaderField: "Origin") == "https://cursor.test")
            #expect(request.value(forHTTPHeaderField: "Cookie") == "WorkosCursorSessionToken=abc")
        }
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
            if case .notLoggedIn = thrown { return true }
            return false
        } ?? false
        #expect(isNotLoggedIn)
    }

    @Test
    func `cost fetcher reports Cursor as a supported token-snapshot provider`() {
        #expect(CostUsageFetcher.supportsTokenSnapshot(.cursor))
    }
}
