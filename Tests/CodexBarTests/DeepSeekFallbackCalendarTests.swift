import Foundation
import Testing
@testable import CodexBarCore

struct DeepSeekFallbackCalendarTests {
    @Test(arguments: [
        ("2026-06-01T00:30:00Z", "America/Los_Angeles", "2026-06-01", "6"),
        ("2026-05-31T23:30:00Z", "Asia/Tokyo", "2026-05-31", "5"),
        ("2026-06-15T00:30:00Z", "America/Los_Angeles", "2026-06-15", "6"),
    ])
    func `failed daily requests preserve UTC monthly selection and today parsing`(
        instant: String,
        zone: String,
        day: String,
        month: String) async throws
    {
        let now = try #require(ISO8601DateFormatter().date(from: instant))
        let local = try Self.calendar(zone)
        let transport = RecordingTransport(day: day)
        let summary = try await DeepSeekUsageFetcher.fetchUsageSummary(
            platformToken: "synthetic-platform-token",
            now: now,
            localCalendar: local,
            transport: transport)
        #expect(summary.period == .currentMonth)
        #expect(summary.todayTokens == 123)
        #expect(summary.todayCost == 2)
        let requests = await transport.requests
        let daily = requests.filter { $0.url?.path.contains("by_api_key") == true }
        let monthly = requests.filter { $0.url?.path.contains("by_api_key") == false }
        #expect(daily.count == 2)
        #expect(monthly.count == 2)
        for request in daily {
            let query = try Self.query(request)
            #expect(query["tz"] == String(local.timeZone.secondsFromGMT(for: now)))
            let end = try #require(query["end"].flatMap(Double.init))
            let expectedEnd = try #require(local.date(
                byAdding: .day,
                value: 1,
                to: local.startOfDay(for: now)))
            #expect(end == expectedEnd.timeIntervalSince1970)
        }
        for request in monthly {
            let query = try Self.query(request)
            #expect(query["month"] == month)
            #expect(query["year"] == "2026")
        }
    }

    @Test(arguments: ["2026-03-09T12:00:00Z", "2026-11-02T12:00:00Z"])
    func `daily requests use the same fixed offset across daylight saving boundaries`(instant: String) async throws {
        let now = try #require(ISO8601DateFormatter().date(from: instant))
        let local = try Self.calendar("America/Los_Angeles")
        let transport = RecordingTransport(day: "2026-03-09")
        _ = try await DeepSeekUsageFetcher.fetchUsageSummary(
            platformToken: "synthetic-platform-token",
            now: now,
            localCalendar: local,
            transport: transport)
        for request in await transport.requests where request.url?.path.contains("by_api_key") == true {
            let query = try Self.query(request)
            let offset = try #require(query["tz"].flatMap(Double.init))
            let start = try #require(query["start"].flatMap(Double.init))
            let end = try #require(query["end"].flatMap(Double.init))
            #expect((start + offset).truncatingRemainder(dividingBy: 86400) == 0)
            #expect((end + offset).truncatingRemainder(dividingBy: 86400) == 0)
            #expect(end - start == 30 * 86400)
        }
    }

    @Test
    func `explicit calendar continues to override daily and monthly paths`() async throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-06-01T00:30:00Z"))
        let calendar = try Self.calendar("America/Los_Angeles")
        let transport = RecordingTransport(day: "2026-05-31")
        let summary = try await DeepSeekUsageFetcher.fetchUsageSummary(
            platformToken: "synthetic-platform-token",
            now: now,
            calendar: calendar,
            localCalendar: Self.calendar("Asia/Tokyo"),
            transport: transport)
        #expect(summary.todayTokens == 123)
        #expect(summary.todayCost == 2)
        for request in await transport.requests where request.url?.path.contains("by_api_key") == false {
            #expect(try Self.query(request)["month"] == "5")
        }
    }

    @Test(arguments: [false, true])
    func `cancelled daily work never starts monthly fallback`(urlCancellation: Bool) async throws {
        let transport = RecordingTransport(
            day: "2026-06-01",
            cancellation: urlCancellation)
        do {
            _ = try await DeepSeekUsageFetcher.fetchUsageSummary(
                platformToken: "synthetic-platform-token",
                now: Date(),
                transport: transport)
            Issue.record("Expected cancellation")
        } catch {
            #expect(error is CancellationError || (error as? URLError)?.code == .cancelled)
        }
        #expect(await transport.requests.allSatisfy { $0.url?.path.contains("by_api_key") == true })
    }

    private static func calendar(_ zone: String) throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: zone))
        return calendar
    }

    private static func query(_ request: URLRequest) throws -> [String: String] {
        let url = try #require(request.url)
        let components = try #require(URLComponents(
            url: url,
            resolvingAgainstBaseURL: false))
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    private actor RecordingTransport: ProviderHTTPTransport {
        let day: String
        let cancellation: Bool?
        private(set) var requests: [URLRequest] = []

        init(
            day: String,
            cancellation: Bool? = nil)
        {
            self.day = day
            self.cancellation = cancellation
        }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            self.requests.append(request)
            let url = try #require(request.url)
            if url.path.contains("by_api_key") {
                if let cancellation {
                    if cancellation {
                        throw URLError(.cancelled)
                    }
                    throw CancellationError()
                }
                return try (Data(), #require(HTTPURLResponse(
                    url: url,
                    statusCode: 503,
                    httpVersion: nil,
                    headerFields: nil)))
            }
            let amount = url.path.hasSuffix("/amount")
            let usage: [[String: Any]] = [[
                "model": "example-model", "usage": [["type": "RESPONSE_TOKEN", "amount": amount ? "123" : "2"]],
            ]]
            let block: [String: Any] = [
                "total": usage, "days": [["date": self.day, "data": usage]], "currency": "USD",
            ]
            let data = try JSONSerialization.data(withJSONObject: [
                "code": 0, "data": ["biz_code": 0, "biz_data": amount ? block as Any : [block] as Any],
            ])
            return try (data, #require(HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil)))
        }
    }
}
