import Foundation
import Testing
@testable import CodexBarCore

#if os(macOS)
@Suite(.serialized)
struct CursorUsageEventsPaginationTests {
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

    // MARK: - Fetching & Pagination

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
