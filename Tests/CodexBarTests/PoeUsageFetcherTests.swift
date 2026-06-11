import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct PoeUsageFetcherTests {
    @Test
    func `parse snapshot extracts current point balance`() throws {
        let json = #"{"current_point_balance": 1500}"#
        let data = Data(json.utf8)
        let snapshot = try PoeUsageFetcher._parseSnapshotForTesting(data)
        #expect(snapshot.currentPointBalance == 1500)
    }

    @Test
    func `parse snapshot accepts string-encoded balance`() throws {
        let json = #"{"current_point_balance": "2500"}"#
        let snapshot = try PoeUsageFetcher._parseSnapshotForTesting(Data(json.utf8))
        #expect(snapshot.currentPointBalance == 2500)
    }

    @Test
    func `parse snapshot returns nil balance when absent`() throws {
        let json = #"{}"#
        let snapshot = try PoeUsageFetcher._parseSnapshotForTesting(Data(json.utf8))
        #expect(snapshot.currentPointBalance == nil)
    }

    @Test
    func `parse snapshot throws on malformed JSON`() {
        #expect {
            _ = try PoeUsageFetcher._parseSnapshotForTesting(Data("not-json".utf8))
        } throws: { error in
            guard case PoeUsageError.parseFailed = error else { return false }
            return true
        }
    }

    @Test
    func `snapshot maps balance to identity loginMethod only, not RateWindow`() {
        let snapshot = PoeUsageSnapshot(
            currentPointBalance: 500,
            updatedAt: Date())

        let unified = snapshot.toUsageSnapshot()
        // No rate windows — balance is not a usage percentage
        #expect(unified.primary == nil)
        #expect(unified.secondary == nil)
        #expect(unified.tertiary == nil)
        // Balance lives in identity.loginMethod as "Balance: X points"
        #expect(unified.identity?.providerID == .poe)
        #expect(unified.identity?.loginMethod == "Balance: 500 points")
    }

    @Test
    func `snapshot hides balance when balance is absent`() {
        let snapshot = PoeUsageSnapshot(
            currentPointBalance: nil,
            updatedAt: Date())

        let unified = snapshot.toUsageSnapshot()
        #expect(unified.primary == nil)
        #expect(unified.identity?.loginMethod == nil)
    }

    @Test
    func `missing credentials fetch call throws missing credentials`() async {
        do {
            _ = try await PoeUsageFetcher.fetchUsage(apiKey: "   ")
            Issue.record("Expected missingCredentials error")
        } catch let error as PoeUsageError {
            guard case .missingCredentials = error else {
                Issue.record("Expected .missingCredentials but got \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func `compact number formats thousands with no decimals`() {
        #expect(PoeUsageSnapshot.compactNumber(1500) == "1,500")
        #expect(PoeUsageSnapshot.compactNumber(999) == "999")
        #expect(PoeUsageSnapshot.compactNumber(10000) == "10,000")
    }

    @Test
    func `history page parser extracts entries and cursor`() throws {
        let json = """
        {
          "data": [
            {
              "query_id": "a1",
              "creation_time": 1717000000000000,
              "bot_name": "GPT-4o",
              "usage_type": "API",
              "cost_points": 12.5,
              "cost_usd": "0.03"
            },
            {
              "query_id": "a2",
              "creation_time": 1717003600,
              "bot_name": "Claude Sonnet",
              "usage_type": "Chat",
              "cost_points": "8",
              "usd": "0.02"
            }
          ],
          "next_cursor": "cursor-2"
        }
        """

        let parsed = try PoeUsageFetcher._parseHistoryPageForTesting(Data(json.utf8))
        #expect(parsed.entries.count == 2)
        #expect(parsed.entries[0].model == "GPT-4o")
        #expect(parsed.entries[0].points == 12.5)
        #expect(parsed.entries[0].id == "a1")
        #expect(parsed.entries[1].costUSD == 0.02)
        #expect(parsed.nextCursor == "cursor-2")
    }

    @Test
    func `history parser derives cursor from has_more and last query id`() throws {
        let json = """
        {
          "has_more": true,
          "data": [
            {
              "query_id": "q-1",
              "creation_time": 1717000000,
              "bot_name": "GPT-4o",
              "usage_type": "API",
              "cost_points": 3
            },
            {
              "query_id": "q-2",
              "creation_time": 1717003600,
              "bot_name": "Claude Sonnet",
              "usage_type": "Chat",
              "cost_points": 9
            }
          ]
        }
        """

        let parsed = try PoeUsageFetcher._parseHistoryPageForTesting(Data(json.utf8))
        #expect(parsed.entries.count == 2)
        #expect(parsed.nextCursor == "q-2")
    }

    @Test
    func `history daily aggregation groups by utc day`() {
        let entries = [
            PoeUsageHistorySnapshot.Entry(
                id: "1",
                createdAt: Date(timeIntervalSince1970: 1_717_000_000),
                model: "GPT-4o",
                usageType: "inference",
                points: 10,
                costUSD: 0.02),
            PoeUsageHistorySnapshot.Entry(
                id: "2",
                createdAt: Date(timeIntervalSince1970: 1_717_000_100),
                model: "GPT-4o",
                usageType: "inference",
                points: 5,
                costUSD: 0.01),
        ]

        let daily = PoeUsageFetcher._buildDailyBucketsForTesting(entries: entries)
        #expect(daily.count == 1)
        #expect(daily[0].requests == 2)
        #expect(daily[0].points == 15)
        #expect(daily[0].costUSD == 0.03)
    }

    @Test
    func `fetch usage returns balance when points history endpoint fails`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            let path = url.path
            let response: (Data, Int)
            if path.contains("current_balance") {
                response = (Data(#"{"current_point_balance": 1500}"#.utf8), 200)
            } else if path.contains("points_history") {
                // Simulate a 500 from the optional history endpoint.
                response = (Data("server error".utf8), 500)
            } else {
                Issue.record("Unexpected request: \(url.absoluteString)")
                return Self.httpResponse(url: nil, status: 0)
            }
            return Self.httpResponse(url: nil, status: response.1, body: response.0)
        }

        let snapshot = try await PoeUsageFetcher._fetchUsage(
            apiKey: "test-key",
            transport: transport)

        #expect(snapshot.currentPointBalance == 1500)
        // History should be nil, not propagate the failure.
        #expect(snapshot.history == nil)
    }

    @Test
    func `fetch usage surfaces history snapshot when history endpoint succeeds`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            let path = url.path
            if path.contains("current_balance") {
                return Self.httpResponse(
                    url: nil,
                    status: 200,
                    body: Data(#"{"current_point_balance": 2500}"#.utf8))
            }
            if path.contains("points_history") {
                return Self.httpResponse(
                    url: nil,
                    status: 200,
                    body: Data("""
                    {"data":[],"next_cursor":null}
                    """.utf8))
            }
            Issue.record("Unexpected request: \(url.absoluteString)")
            return Self.httpResponse(url: nil, status: 0)
        }

        let snapshot = try await PoeUsageFetcher._fetchUsage(
            apiKey: "test-key",
            transport: transport)

        #expect(snapshot.currentPointBalance == 2500)
        // Empty history page still produces a non-nil snapshot with empty buckets.
        #expect(snapshot.history == nil)
    }
}

extension PoeUsageFetcherTests {
    fileprivate static func httpResponse(
        url: URL?,
        status: Int,
        body: Data = Data()) -> (Data, URLResponse)
    {
        let response = HTTPURLResponse(
            url: url ?? URL(string: "https://example.invalid")!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: nil) ?? HTTPURLResponse()
        return (body, response)
    }
}
