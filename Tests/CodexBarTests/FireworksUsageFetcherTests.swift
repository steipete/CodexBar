import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct FireworksUsageFetcherTests {
    @Test
    func `sums rated line items from units and nanos`() throws {
        let json = """
        {
          "lineItems": [
            {
              "category": "LLM input tokens (cached)",
              "groupingKey": "model_bucket",
              "groupingValue": "DeepSeek V4 Flash",
              "quantity": 17580572,
              "series": "SERVERLESS",
              "totalCost": { "currencyCode": "USD", "nanos": 492256016, "units": "0" },
              "unitAmount": { "currencyCode": "USD", "nanos": 28, "units": "0" }
            },
            {
              "category": "LLM output tokens",
              "groupingKey": "model_bucket",
              "groupingValue": "DeepSeek V4 Flash",
              "quantity": 118901,
              "series": "SERVERLESS",
              "totalCost": { "currencyCode": "USD", "nanos": 33292280, "units": "1" },
              "unitAmount": { "currencyCode": "USD", "nanos": 280, "units": "0" }
            }
          ],
          "usageBuckets": []
        }
        """

        let summary = try FireworksUsageFetcher._parseSummaryForTesting(Data(json.utf8))

        #expect(summary.last30DaysSpend ?? -1 == 1.525548296, accuracy: 0.000000001)
        #expect(summary.currencyCode == "USD")

        let usage = FireworksUsageSnapshot(summary: summary).toUsageSnapshot()
        #expect(usage.primary == nil)
        #expect(usage.secondary == nil)
        #expect(usage.providerCost?.used == 1.525548296, accuracy: 0.000000001)
        #expect(usage.providerCost?.currencyCode == "USD")
        #expect(usage.providerCost?.period == "Last 30 days")
        #expect(usage.providerCost?.limit == 0)
    }

    @Test
    func `only rows in the first rated currency are summed`() throws {
        let json = """
        {
          "lineItems": [
            {
              "category": "LLM input tokens (cached)",
              "totalCost": { "currencyCode": "USD", "nanos": 100000000, "units": "1" }
            },
            {
              "category": "LLM output tokens",
              "totalCost": { "currencyCode": "EUR", "nanos": 900000000, "units": "9" }
            },
            {
              "category": "LLM input tokens (uncached)",
              "totalCost": { "currencyCode": "USD", "nanos": 250000000, "units": "0" }
            }
          ],
          "usageBuckets": []
        }
        """

        let summary = try FireworksUsageFetcher._parseSummaryForTesting(Data(json.utf8))

        #expect(summary.currencyCode == "USD")
        #expect(summary.last30DaysSpend ?? -1 == 1.35, accuracy: 0.000000001)
    }

    @Test
    func `empty line items report no spend window`() throws {
        let json = """
        { "lineItems": [], "usageBuckets": [] }
        """

        let summary = try FireworksUsageFetcher._parseSummaryForTesting(Data(json.utf8))

        #expect(summary.last30DaysSpend == nil)
        #expect(summary.currencyCode == nil)
        #expect(FireworksUsageSnapshot(summary: summary).toUsageSnapshot().providerCost == nil)
    }

    @Test
    func `invalid root returns parse error`() {
        let json = """
        [{ "lineItems": [] }]
        """

        #expect {
            _ = try FireworksUsageFetcher._parseSummaryForTesting(Data(json.utf8))
        } throws: { error in
            guard case FireworksUsageError.parseFailed = error else { return false }
            return true
        }
    }

    @Test
    func `summary url carries account slug and iso window`() {
        let url = FireworksUsageFetcher.resolveSummaryURL(
            accountSlug: "x0mh0x",
            startTime: Date(timeIntervalSince1970: 0),
            endTime: Date(timeIntervalSince1970: 86_400))

        #expect(url.absoluteString.hasPrefix("https://api.fireworks.ai/v1/accounts/x0mh0x/billing/summary?"))
        #expect(url.absoluteString.contains("startTime=1970-01-01T00%3A00%3A00Z"))
        #expect(url.absoluteString.contains("endTime=1970-01-02T00%3A00%3A00Z"))
    }

    @Test
    func `fetch usage sends bearer token and bounded request`() async throws {
        defer {
            FireworksStubURLProtocol.requests = []
            FireworksStubURLProtocol.handler = nil
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FireworksStubURLProtocol.self]
        let session = URLSession(configuration: config)

        FireworksStubURLProtocol.requests = []
        FireworksStubURLProtocol.handler = { request in
            let url = try #require(request.url)
            #expect(request.httpMethod == "GET")
            #expect(url.absoluteString.hasPrefix("https://api.fireworks.ai/v1/accounts/x0mh0x/billing/summary?"))
            #expect(url.absoluteString.contains("startTime="))
            #expect(url.absoluteString.contains("endTime="))
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fw-test-key")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            #expect(request.timeoutInterval == 15)

            let body = """
            {
              "lineItems": [
                {
                  "category": "LLM input tokens (cached)",
                  "totalCost": { "currencyCode": "USD", "nanos": 500000000, "units": "0" }
                }
              ],
              "usageBuckets": []
            }
            """
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"])!
            return (response, Data(body.utf8))
        }

        let snapshot = try await FireworksUsageFetcher.fetchUsage(
            apiKey: "fw-test-key",
            accountSlug: "x0mh0x",
            session: session)

        #expect(FireworksStubURLProtocol.requests.count == 1)
        #expect(snapshot.summary.last30DaysSpend ?? -1 == 0.5, accuracy: 0.000000001)
    }

    @Test
    func `fetch usage maps authentication and rate limit failures`() async throws {
        for (statusCode, expectedError) in [
            (401, FireworksUsageError.authenticationRejected),
            (403, FireworksUsageError.authenticationRejected),
            (429, FireworksUsageError.rateLimited),
            (500, FireworksUsageError.apiError(500)),
        ] {
            defer {
                FireworksStubURLProtocol.requests = []
                FireworksStubURLProtocol.handler = nil
            }

            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [FireworksStubURLProtocol.self]
            let session = URLSession(configuration: config)

            FireworksStubURLProtocol.handler = { request in
                guard let url = request.url else { throw URLError(.badURL) }
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: statusCode,
                    httpVersion: nil,
                    headerFields: nil)!
                return (response, Data(#"{"error":"secret-ish provider body"}"#.utf8))
            }

            await #expect {
                _ = try await FireworksUsageFetcher.fetchUsage(
                    apiKey: "fw-test-key",
                    accountSlug: "x0mh0x",
                    session: session)
            } throws: { error in
                error == expectedError
            }
        }
    }

    @Test
    func `fetch usage requires key and slug`() async {
        await #expect {
            _ = try await FireworksUsageFetcher.fetchUsage(
                apiKey: "  ",
                accountSlug: "x0mh0x",
                session: URLSession(configuration: .ephemeral))
        } throws: { error in
            error == FireworksUsageError.missingCredentials
        }

        await #expect {
            _ = try await FireworksUsageFetcher.fetchUsage(
                apiKey: "fw-test-key",
                accountSlug: "",
                session: URLSession(configuration: .ephemeral))
        } throws: { error in
            error == FireworksUsageError.missingAccountSlug
        }
    }
}

final class FireworksStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requests: [URLRequest] = []
    private static let _handlerBox = LockIsolated<(@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?>(nil)
    static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))? {
        get { Self._handlerBox.value }
        set { Self._handlerBox.setValue(newValue) }
    }

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.requests.append(self.request)
        guard let handler = Self.handler else {
            self.client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(self.request)
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        } catch {
            self.client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
