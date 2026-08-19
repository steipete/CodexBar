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

        #expect(abs((summary.last30DaysSpend ?? -1) - 1.525548296) <= 0.000000001)
        #expect(summary.currencyCode == "USD")

        let usage = FireworksUsageSnapshot(summary: summary).toUsageSnapshot()
        #expect(usage.primary == nil)
        #expect(usage.secondary == nil)
        #expect(abs((usage.providerCost?.used ?? -1) - 1.525548296) <= 0.000000001)
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
        #expect(abs((summary.last30DaysSpend ?? -1) - 1.35) <= 0.000000001)
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
    func `summary url carries account slug and iso window`() throws {
        let url = try FireworksUsageFetcher.resolveSummaryURL(
            accountSlug: "x0mh0x",
            startTime: Date(timeIntervalSince1970: 0),
            endTime: Date(timeIntervalSince1970: 86400))

        #expect(url.absoluteString.hasPrefix("https://api.fireworks.ai/v1/accounts/x0mh0x/billing/summary?"))
        #expect(url.absoluteString.contains("startTime=1970-01-01T00:00:00Z"))
        #expect(url.absoluteString.contains("endTime=1970-01-02T00:00:00Z"))
    }

    @Test
    func `malformed account slugs fail with a config error instead of misrouting`() {
        // A slug with reserved/invalid URL characters must surface as a config error
        // (never widen the path, inject a query, or crash on URL construction).
        for badSlug in ["sp ace", "has/slash", "has?query", "has#fragment", "percent%2F", "col\u{00e9}on"] {
            #expect(throws: FireworksUsageError.invalidAccountSlug(badSlug)) {
                _ = try FireworksUsageFetcher.resolveSummaryURL(accountSlug: badSlug)
            }
        }

        // Permitted slug characters still produce the exact billing-summary path.
        for goodSlug in ["x0mh0x", "acct-1_x.d"] {
            let url = try? FireworksUsageFetcher.resolveSummaryURL(accountSlug: goodSlug)
            #expect(url?.path == "/v1/accounts/\(goodSlug)/billing/summary", "\(goodSlug) should resolve")
        }
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
        #expect(abs((snapshot.summary.last30DaysSpend ?? -1) - 0.5) <= 0.000000001)
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
                guard let error = error as? FireworksUsageError else { return false }
                return error == expectedError
            }
        }
    }

    @Test
    func `wrong slug with empty billing response is an explicit account error`() async throws {
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
            let body: String
            if url.path == "/v1/accounts" {
                body = #"{"accounts":[{"name":"accounts/actual-team"}]}"#
            } else {
                #expect(url.path == "/v1/accounts/guessed-user/billing/summary")
                body = #"{"lineItems":[],"usageBuckets":[]}"#
            }
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(body.utf8))
        }

        await #expect {
            _ = try await FireworksUsageFetcher.fetchUsage(
                apiKey: "fw-test-key",
                accountSlug: "guessed-user",
                session: session)
        } throws: { error in
            guard error as? FireworksUsageError == .accountNotFound("guessed-user") else { return false }
            return error.localizedDescription.hasPrefix(
                "Fireworks account slug 'guessed-user' not found for this API key")
        }
        #expect(FireworksStubURLProtocol.requests.map(\.url?.path) == [
            "/v1/accounts/guessed-user/billing/summary",
            "/v1/accounts",
        ])
    }

    @Test
    func `missing slug auto discovers a single account before fetching billing`() async throws {
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
            let body: String
            if url.path == "/v1/accounts" {
                body = #"{"accounts":[{"name":"accounts/discovered-team","displayName":"Discovered Team"}]}"#
            } else {
                #expect(url.path == "/v1/accounts/discovered-team/billing/summary")
                body = """
                {
                  "lineItems": [
                    { "totalCost": { "currencyCode": "USD", "nanos": 250000000, "units": "2" } }
                  ]
                }
                """
            }
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fw-test-key")
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(body.utf8))
        }

        let snapshot = try await FireworksUsageFetcher.fetchUsage(
            apiKey: "fw-test-key",
            accountSlug: nil,
            session: session)

        #expect(snapshot.accountSlug == "discovered-team")
        #expect(snapshot.accountSlugWasDiscovered)
        #expect(snapshot.summary.last30DaysSpend == 2.25)
        #expect(FireworksStubURLProtocol.requests.map(\.url?.path) == [
            "/v1/accounts",
            "/v1/accounts/discovered-team/billing/summary",
        ])
    }

    @Test
    func `multiple visible accounts report sorted slug candidates`() async throws {
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
            #expect(url.path == "/v1/accounts")
            let body = #"{"accounts":[{"name":"accounts/zeta"},{"name":"accounts/alpha"}]}"#
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(body.utf8))
        }

        await #expect {
            _ = try await FireworksUsageFetcher.fetchUsage(
                apiKey: "fw-test-key",
                accountSlug: nil,
                session: session)
        } throws: { error in
            guard error as? FireworksUsageError == .multipleAccountsFound(["alpha", "zeta"]) else {
                return false
            }
            return error.localizedDescription.contains("alpha, zeta")
        }
        #expect(FireworksStubURLProtocol.requests.count == 1)
    }

    @Test
    func `configured 404 auto discovers the sole visible account`() async throws {
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
            let response: HTTPURLResponse
            let body: String
            switch url.path {
            case "/v1/accounts/old-slug/billing/summary":
                response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!
                body = #"{"code":5,"message":"account not found"}"#
            case "/v1/accounts":
                response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                body = #"{"accounts":[{"name":"accounts/current-slug"}]}"#
            default:
                #expect(url.path == "/v1/accounts/current-slug/billing/summary")
                response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                body = #"{"lineItems":[{"totalCost":{"currencyCode":"USD","nanos":0,"units":"1"}}]}"#
            }
            return (response, Data(body.utf8))
        }

        let snapshot = try await FireworksUsageFetcher.fetchUsage(
            apiKey: "fw-test-key",
            accountSlug: "old-slug",
            session: session)

        #expect(snapshot.accountSlug == "current-slug")
        #expect(snapshot.accountSlugWasDiscovered)
        #expect(snapshot.summary.last30DaysSpend == 1)
        #expect(FireworksStubURLProtocol.requests.map(\.url?.path) == [
            "/v1/accounts/old-slug/billing/summary",
            "/v1/accounts",
            "/v1/accounts/current-slug/billing/summary",
        ])
    }

    @Test
    func `fetch usage requires key`() async {
        await #expect(throws: FireworksUsageError.missingCredentials) {
            _ = try await FireworksUsageFetcher.fetchUsage(
                apiKey: "  ",
                accountSlug: "x0mh0x",
                session: URLSession(configuration: .ephemeral))
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
