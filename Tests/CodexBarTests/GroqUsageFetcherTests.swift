import CodexBarCore
import Foundation
import Testing

struct GroqUsageFetcherTests {
    @Test
    func `parses prometheus scalar response`() throws {
        let json = """
        {
          "status": "success",
          "data": {
            "result": [
              { "value": [1710000000, "2.5"] },
              { "value": [1710000000, "1.5"] }
            ]
          }
        }
        """

        let value = try GroqUsageFetcher._parseScalarForTesting(Data(json.utf8))

        #expect(value == 4)
    }

    @Test
    func `snapshot maps prometheus rates to menu windows`() {
        let snapshot = GroqUsageSnapshot(
            requestRatePerSecond: 2,
            inputTokenRatePerSecond: 100,
            outputTokenRatePerSecond: 50,
            promptCacheHitRatePerSecond: 3,
            updatedAt: Date(timeIntervalSince1970: 1))
            .toUsageSnapshot()

        #expect(snapshot.identity?.providerID == .groq)
        #expect(snapshot.identity?.loginMethod == "Prometheus metrics")
        #expect(snapshot.primary?.resetDescription == "120 req/min")
        #expect(snapshot.secondary?.resetDescription == "9000 tok/min")
        #expect(snapshot.tertiary?.resetDescription == "180 cache/min")
    }

    @Test(arguments: [
        #"{"status":"success"}"#,
        #"{"status":"success","data":{"result":[{}]}}"#,
        #"{"status":"success","data":{"result":[{"value":[]}]}}"#,
        #"{"status":"success","data":{"result":[{"value":["2.5"]}]}}"#,
        #"{"status":"success","data":{"result":[{"value":[1,"2.5",3]}]}}"#,
        #"{"status":"success","data":{"result":[{"value":[1,"NaN"]}]}}"#,
        #"{"status":"success","data":{"result":[{"value":[1,"+Inf"]}]}}"#,
        #"{"status":"success","data":{"result":[{"value":[1,"-Inf"]}]}}"#,
        #"{"status":"success","data":{"result":[{"value":[1,"invalid"]}]}}"#,
        #"{"status":"success","data":{"result":[{"value":[1,"-1"]}]}}"#,
        #"{"status":"success","data":{"result":[{"value":[1,"1e308"]},{"value":[1,"1e308"]}]}}"#,
    ])
    func `rejects unavailable or malformed samples instead of inventing a rate`(json: String) {
        #expect(throws: GroqUsageError.self) {
            try GroqUsageFetcher._parseScalarForTesting(Data(json.utf8))
        }
    }

    @Test(arguments: [
        #"{"status":"success","data":{"result":[]}}"#,
        #"{"status":"success","data":{"result":[{"value":[1,0]}]}}"#,
        #"{"status":"success","data":{"result":[{"value":[1,"0"]}]}}"#,
    ])
    func `retains genuine zero and empty vectors`(json: String) throws {
        #expect(try GroqUsageFetcher._parseScalarForTesting(Data(json.utf8)) == 0)
    }

    @Test(arguments: [
        #"{"result":[{"value":[1,"NaN"]}]}"#,
        #"{"result":[{"value":[1,true]}]}"#,
        #"{"result":[{"value":false}]}"#,
        #"{"result":false}"#,
        "false",
    ])
    func `server error takes precedence over unavailable sample data`(payload: String) {
        let json = #"{"status":"error","error":"query unavailable","data":\#(payload)}"#
        do {
            _ = try GroqUsageFetcher._parseScalarForTesting(Data(json.utf8))
            Issue.record("Expected server error")
        } catch let GroqUsageError.apiError(message) {
            #expect(message == "query unavailable")
        } catch {
            Issue.record("Unexpected error category: \(error)")
        }
    }

    @Test(arguments: [(0.0, "0.00 req/min"), (0.1, "6.00 req/min"), (0.25, "15.0 req/min"), (2.0, "120 req/min")])
    func `rate labels preserve magnitude based decimal precision`(rate: Double, label: String) {
        let usage = GroqUsageSnapshot(
            requestRatePerSecond: rate,
            inputTokenRatePerSecond: 0,
            outputTokenRatePerSecond: 0,
            updatedAt: Date(timeIntervalSince1970: 1)).toUsageSnapshot()
        #expect(usage.primary?.resetDescription == label)
    }

    @Test(arguments: ["requests", "cache", "tokens"])
    func `rejects overflow when finite query rates become per minute rates`(metric: String) async {
        await #expect(throws: GroqUsageError.self) {
            try await GroqUsageFetcher.fetchUsage(
                apiKey: "synthetic-groq-key", environment: [:], transport: RateTransport(overflowMetric: metric))
        }
    }

    @Test
    func `fetch retains finite combined rates`() async throws {
        let result = try await GroqUsageFetcher.fetchUsage(
            apiKey: "synthetic-groq-key", environment: [:], transport: RateTransport(overflowMetric: nil))
        #expect(result.requestsPerMinute == 120)
        #expect(result.tokensPerMinute == 240)
        #expect(result.cacheHitsPerMinute == 120)
    }

    private struct RateTransport: ProviderHTTPTransport {
        let overflowMetric: String?

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let url = try #require(request.url)
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "query" }?.value ?? ""
            let matches: Bool = switch self.overflowMetric {
            case "requests": query.contains("requests:")
            case "cache": query.contains("prompt_cache_hits:")
            case "tokens": query.contains("tokens_in:") || query.contains("tokens_out:")
            default: false
            }
            let value = matches ? (self.overflowMetric == "tokens" ? "1.6e306" : "1e308") : "2"
            let json = #"{"status":"success","data":{"result":[{"value":[1,"\#(value)"]}]}}"#
            let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (Data(json.utf8), response)
        }
    }
}
