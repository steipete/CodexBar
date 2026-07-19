import Foundation
import Testing
@testable import CodexBarCore

struct OpenAIAPIUsageFetcherTests {
    @Test
    func `parses admin costs and completions usage into daily summaries`() throws {
        let now = Date(timeIntervalSince1970: 1_700_179_200)
        let costs = """
        {
          "object": "page",
          "data": [
            {
              "object": "bucket",
              "start_time": 1700000000,
              "end_time": 1700086400,
              "results": [
                {
                  "object": "organization.costs.result",
                  "amount": { "value": 12.50, "currency": "usd" },
                  "line_item": "Text tokens"
                },
                {
                  "object": "organization.costs.result",
                  "amount": { "value": "2.25", "currency": "usd" },
                  "line_item": "Web search tool calls"
                }
              ]
            },
            {
              "object": "bucket",
              "start_time": 1700086400,
              "end_time": 1700172800,
              "results": [
                {
                  "object": "organization.costs.result",
                  "amount": { "value": 4.00, "currency": "usd" },
                  "line_item": "Text tokens"
                }
              ]
            }
          ],
          "has_more": false,
          "next_page": null
        }
        """
        let completions = """
        {
          "object": "page",
          "data": [
            {
              "object": "bucket",
              "start_time": 1700000000,
              "end_time": 1700086400,
              "results": [
                {
                  "object": "organization.usage.completions.result",
                  "input_tokens": 1000,
                  "input_cached_tokens": 250,
                  "output_tokens": 500,
                  "num_model_requests": 7,
                  "model": "gpt-5.2"
                },
                {
                  "object": "organization.usage.completions.result",
                  "input_tokens": 300,
                  "output_tokens": 200,
                  "num_model_requests": 3,
                  "model": "gpt-5.2-codex"
                }
              ]
            },
            {
              "object": "bucket",
              "start_time": 1700086400,
              "end_time": 1700172800,
              "results": [
                {
                  "object": "organization.usage.completions.result",
                  "input_tokens": 200,
                  "output_tokens": 100,
                  "num_model_requests": 2,
                  "model": "gpt-5.2"
                }
              ]
            }
          ],
          "has_more": false,
          "next_page": null
        }
        """

        let snapshot = try OpenAIAPIUsageFetcher._parseSnapshotForTesting(
            costs: Data(costs.utf8),
            completions: Data(completions.utf8),
            now: now,
            historyDays: 90)

        #expect(snapshot.historyDays == 90)
        #expect(snapshot.historyWindowLabel == "90d")
        #expect(snapshot.daily.count == 2)
        #expect(snapshot.daily[0].costUSD == 14.75)
        #expect(snapshot.daily[0].requests == 10)
        #expect(snapshot.daily[0].totalTokens == 2000)
        #expect(snapshot.daily[0].cachedInputTokens == 250)
        #expect(snapshot.daily[0].lineItems.first?.name == "Text tokens")
        #expect(snapshot.last30Days.costUSD == 18.75)
        #expect(snapshot.last30Days.requests == 12)
        #expect(snapshot.last30Days.totalTokens == 2300)
        #expect(snapshot.topModels.first?.name == "gpt-5.2")
        #expect(snapshot.topModels.first?.totalTokens == 1800)
    }

    @Test(arguments: ["NaN", "Infinity", "-Infinity", "1e309", "-1e309"])
    func `rejects nonfinite cost strings`(value: String) {
        let costs = """
        {
          "data": [{
            "start_time": 1700000000,
            "end_time": 1700086400,
            "results": [{ "amount": { "value": "\(value)", "currency": "usd" } }]
          }],
          "has_more": false,
          "next_page": null
        }
        """
        let completions = #"{"data":[],"has_more":false,"next_page":null}"#

        do {
            _ = try OpenAIAPIUsageFetcher._parseSnapshotForTesting(
                costs: Data(costs.utf8),
                completions: Data(completions.utf8),
                now: Date(timeIntervalSince1970: 1_700_179_200))
            Issue.record("Expected a costs parse failure.")
        } catch let error as OpenAIAPIUsageError {
            guard case let .parseFailed(endpoint, _) = error else {
                Issue.record("Expected a costs parse failure, got \(error).")
                return
            }
            #expect(endpoint == "costs")
        } catch {
            Issue.record("Expected OpenAIAPIUsageError, got \(error).")
        }
    }

    @Test
    func `admin usage fetch pages long history within endpoint bucket limit`() async throws {
        let now = Date(timeIntervalSince1970: 1_700_179_200)
        let emptyPage = Data(#"{"object":"page","data":[],"has_more":false,"next_page":null}"#.utf8)
        let transport = ProviderHTTPTransportStub { request in
            let response = try HTTPURLResponse(
                url: #require(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil)!
            return (emptyPage, response)
        }

        let snapshot = try await OpenAIAPIUsageFetcher.fetchUsage(
            apiKey: "sk-test",
            costsURL: #require(URL(string: "https://api.openai.test/v1/organization/costs")),
            completionsURL: #require(URL(string: "https://api.openai.test/v1/organization/usage/completions")),
            session: transport,
            now: now,
            historyDays: 90)

        let requests = await transport.requests()
        let limits = requests.compactMap { request -> Int? in
            guard let url = request.url,
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let raw = components.queryItems?.first(where: { $0.name == "limit" })?.value
            else { return nil }
            return Int(raw)
        }

        #expect(snapshot.historyDays == 90)
        #expect(requests.count == 6)
        #expect(limits == [31, 31, 28, 31, 31, 28])
        #expect(limits.allSatisfy { $0 <= 31 })
    }

    @Test
    func `admin usage filters costs and completions by project`() async throws {
        let now = Date(timeIntervalSince1970: 1_700_179_200)
        let emptyPage = Data(#"{"object":"page","data":[],"has_more":false,"next_page":null}"#.utf8)
        let transport = ProviderHTTPTransportStub { request in
            let response = try HTTPURLResponse(
                url: #require(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil)!
            return (emptyPage, response)
        }

        let snapshot = try await OpenAIAPIUsageFetcher.fetchUsage(
            apiKey: "sk-test",
            projectID: " proj_abc ",
            costsURL: #require(URL(string: "https://api.openai.test/v1/organization/costs")),
            completionsURL: #require(URL(string: "https://api.openai.test/v1/organization/usage/completions")),
            session: transport,
            now: now,
            historyDays: 1)

        let requests = await transport.requests()
        let projectIDs = requests.compactMap { request -> String? in
            guard let url = request.url,
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            else { return nil }
            return components.queryItems?.first(where: { $0.name == "project_ids" })?.value
        }
        let groupBys = requests.compactMap { request -> String? in
            guard let url = request.url,
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            else { return nil }
            return components.queryItems?.first(where: { $0.name == "group_by" })?.value
        }

        #expect(snapshot.projectID == "proj_abc")
        #expect(snapshot.toUsageSnapshot().identity?.accountOrganization == "Project: proj_abc")
        #expect(requests.count == 2)
        #expect(projectIDs == ["proj_abc", "proj_abc"])
        #expect(groupBys == ["line_item", "model"])
    }

    @Test
    func `admin usage follows costs and completions pagination cursors`() async throws {
        let now = Date(timeIntervalSince1970: 1_700_179_200)
        let transport = OpenAIAdminUsagePaginationScript()

        let snapshot = try await OpenAIAPIUsageFetcher.fetchUsage(
            apiKey: "sk-test",
            projectID: "proj_abc",
            costsURL: #require(URL(string: "https://api.openai.test/v1/organization/costs")),
            completionsURL: #require(URL(string: "https://api.openai.test/v1/organization/usage/completions")),
            session: transport,
            now: now,
            historyDays: 1)

        let requests = await transport.requests()
        let costsRequests = requests.filter { $0.url?.path.contains("/organization/costs") == true }
        let completionRequests = requests.filter { $0.url?.path.contains("/usage/completions") == true }

        #expect(snapshot.daily.count == 1)
        #expect(snapshot.latestDay.costUSD == 4.0)
        #expect(snapshot.latestDay.requests == 3)
        #expect(snapshot.latestDay.totalTokens == 45)
        #expect(costsRequests.count == 2)
        #expect(completionRequests.count == 2)
        #expect(Self.queryValue("page", in: costsRequests[0]) == nil)
        #expect(Self.queryValue("page", in: costsRequests[1]) == "costs_page_2")
        #expect(Self.queryValue("page", in: completionRequests[0]) == nil)
        #expect(Self.queryValue("page", in: completionRequests[1]) == "completions_page_2")
        #expect(requests.allSatisfy { Self.queryValue("project_ids", in: $0) == "proj_abc" })
    }

    @Test
    func `admin usage rejects repeated pagination cursor`() async throws {
        let transport = OpenAIAdminUsageRepeatingCursorScript()

        await #expect(throws: OpenAIAPIUsageError.parseFailed(
            endpoint: "costs",
            message: "Pagination cursor repeated."))
        {
            try await OpenAIAPIUsageFetcher.fetchUsage(
                apiKey: "sk-test",
                costsURL: #require(URL(string: "https://api.openai.test/v1/organization/costs")),
                completionsURL: #require(URL(string: "https://api.openai.test/v1/organization/usage/completions")),
                session: transport,
                now: Date(timeIntervalSince1970: 1_700_179_200),
                historyDays: 1)
        }
    }

    @Test
    func `admin usage rejects missing pagination cursor`() async throws {
        let transport = OpenAIAdminUsageMissingCursorScript()

        await #expect(throws: OpenAIAPIUsageError.parseFailed(
            endpoint: "costs",
            message: "Pagination cursor missing."))
        {
            try await OpenAIAPIUsageFetcher.fetchUsage(
                apiKey: "sk-test",
                costsURL: #require(URL(string: "https://api.openai.test/v1/organization/costs")),
                completionsURL: #require(URL(string: "https://api.openai.test/v1/organization/usage/completions")),
                session: transport,
                now: Date(timeIntervalSince1970: 1_700_179_200),
                historyDays: 1)
        }
    }

    @Test
    func `admin usage rejects page without costs data`() async throws {
        let transport = OpenAIAdminUsageMalformedPageScript(
            costs: #"{"object":"page","has_more":false,"next_page":null}"#,
            completions: #"{"object":"page","data":[],"has_more":false,"next_page":null}"#)

        do {
            _ = try await OpenAIAPIUsageFetcher.fetchUsage(
                apiKey: "sk-test",
                costsURL: #require(URL(string: "https://api.openai.test/v1/organization/costs")),
                completionsURL: #require(URL(string: "https://api.openai.test/v1/organization/usage/completions")),
                session: transport,
                now: Date(timeIntervalSince1970: 1_700_179_200),
                historyDays: 1)
            Issue.record("Expected costs parse failure.")
        } catch let error as OpenAIAPIUsageError {
            guard case let .parseFailed(endpoint, message) = error else {
                Issue.record("Expected parse failure, got \(error).")
                return
            }
            #expect(endpoint == "costs")
            #expect(message.contains("data"))
        } catch {
            Issue.record("Expected OpenAIAPIUsageError, got \(error).")
        }
    }

    @Test
    func `admin usage rejects page without completions pagination state`() async throws {
        let transport = OpenAIAdminUsageMalformedPageScript(
            costs: #"{"object":"page","data":[],"has_more":false,"next_page":null}"#,
            completions: #"{"object":"page","data":[],"next_page":null}"#)

        do {
            _ = try await OpenAIAPIUsageFetcher.fetchUsage(
                apiKey: "sk-test",
                costsURL: #require(URL(string: "https://api.openai.test/v1/organization/costs")),
                completionsURL: #require(URL(string: "https://api.openai.test/v1/organization/usage/completions")),
                session: transport,
                now: Date(timeIntervalSince1970: 1_700_179_200),
                historyDays: 1)
            Issue.record("Expected completions parse failure.")
        } catch let error as OpenAIAPIUsageError {
            guard case let .parseFailed(endpoint, message) = error else {
                Issue.record("Expected parse failure, got \(error).")
                return
            }
            #expect(endpoint == "completions")
            #expect(message.contains("missing"))
        } catch {
            Issue.record("Expected OpenAIAPIUsageError, got \(error).")
        }
    }

    @Test
    func `admin usage retries transient completions failure once`() async throws {
        let now = Date(timeIntervalSince1970: 1_700_179_200)
        let emptyPage = Data(#"{"object":"page","data":[],"has_more":false,"next_page":null}"#.utf8)
        let completions = Data("""
        {
          "object": "page",
          "data": [
            {
              "object": "bucket",
              "start_time": 1700000000,
              "end_time": 1700086400,
              "results": [
                {
                  "object": "organization.usage.completions.result",
                  "input_tokens": 10,
                  "output_tokens": 5,
                  "num_model_requests": 1,
                  "model": "gpt-5.2"
                }
              ]
            }
          ],
          "has_more": false,
          "next_page": null
        }
        """.utf8)
        let transport = OpenAIAdminUsageRetryScript(costs: emptyPage, completions: completions)

        let snapshot = try await OpenAIAPIUsageFetcher.fetchUsage(
            apiKey: "sk-test",
            costsURL: #require(URL(string: "https://api.openai.test/v1/organization/costs")),
            completionsURL: #require(URL(string: "https://api.openai.test/v1/organization/usage/completions")),
            session: transport,
            now: now,
            historyDays: 1,
            retryPolicy: ProviderHTTPRetryPolicy(maxRetries: 1, baseDelaySeconds: 0, maxDelaySeconds: 0))

        #expect(snapshot.latestDay.totalTokens == 15)
        #expect(snapshot.latestDay.requests == 1)
        #expect(await transport.completionsRequestCount() == 2)
    }

    @Test
    func `maps admin usage to openai usage snapshot`() {
        let now = Date(timeIntervalSince1970: 1_700_179_200)
        let apiUsage = OpenAIAPIUsageSnapshot(
            daily: [
                OpenAIAPIUsageSnapshot.DailyBucket(
                    day: "2023-11-14",
                    startTime: now,
                    endTime: now.addingTimeInterval(86400),
                    costUSD: 8.5,
                    requests: 42,
                    inputTokens: 1000,
                    cachedInputTokens: 400,
                    outputTokens: 250,
                    totalTokens: 1250,
                    lineItems: [],
                    models: []),
            ],
            updatedAt: now)

        let usage = apiUsage.toUsageSnapshot()

        #expect(usage.primary == nil)
        #expect(usage.providerCost?.used == 8.5)
        #expect(usage.providerCost?.limit == 0)
        #expect(usage.providerCost?.period == "Last 30 days")
        #expect(usage.openAIAPIUsage?.last30Days.requests == 42)
        #expect(usage.identity?.loginMethod == "Admin API")
    }

    @Test
    func `maps project scoped admin usage to cost token snapshot`() throws {
        let now = try Self.localNoon(year: 2023, month: 11, day: 17)
        let firstDay = try Self.localNoon(year: 2023, month: 11, day: 13)
        let secondDay = try Self.localNoon(year: 2023, month: 11, day: 14)
        let apiUsage = OpenAIAPIUsageSnapshot(
            daily: [
                OpenAIAPIUsageSnapshot.DailyBucket(
                    day: "2023-11-13",
                    startTime: firstDay,
                    endTime: firstDay.addingTimeInterval(86400),
                    costUSD: 2.25,
                    requests: 3,
                    inputTokens: 300,
                    cachedInputTokens: 100,
                    outputTokens: 200,
                    totalTokens: 500,
                    lineItems: [],
                    models: [
                        OpenAIAPIUsageSnapshot.ModelBreakdown(
                            name: "gpt-5.2",
                            requests: 3,
                            inputTokens: 300,
                            cachedInputTokens: 100,
                            outputTokens: 200,
                            totalTokens: 500),
                    ]),
                OpenAIAPIUsageSnapshot.DailyBucket(
                    day: "2023-11-14",
                    startTime: secondDay,
                    endTime: secondDay.addingTimeInterval(86400),
                    costUSD: 8.5,
                    requests: 42,
                    inputTokens: 1000,
                    cachedInputTokens: 400,
                    outputTokens: 250,
                    totalTokens: 1250,
                    lineItems: [],
                    models: [
                        OpenAIAPIUsageSnapshot.ModelBreakdown(
                            name: "gpt-5.2-codex",
                            requests: 42,
                            inputTokens: 1000,
                            cachedInputTokens: 400,
                            outputTokens: 250,
                            totalTokens: 1250),
                    ]),
            ],
            updatedAt: now,
            historyDays: 7,
            projectID: " proj_abc ")

        let usage = apiUsage.toUsageSnapshot()
        let snapshot = apiUsage.toCostUsageTokenSnapshot()

        #expect(apiUsage.projectID == "proj_abc")
        #expect(usage.identity?.loginMethod == "Admin API: proj_abc")
        #expect(usage.identity?.accountOrganization == "Project: proj_abc")
        #expect(snapshot.historyDays == 7)
        #expect(snapshot.currencyCode == "USD")
        #expect(apiUsage.currentDay.costUSD == 0)
        #expect(apiUsage.currentDay.totalTokens == 0)
        #expect(snapshot.sessionCostUSD == 0)
        #expect(snapshot.sessionTokens == 0)
        #expect(snapshot.sessionRequests == 0)
        #expect(snapshot.last30DaysCostUSD == 10.75)
        #expect(snapshot.last30DaysTokens == 1750)
        #expect(snapshot.last30DaysRequests == 45)
        #expect(snapshot.daily.count == 2)
        #expect(snapshot.daily[1].cacheReadTokens == 400)
        #expect(snapshot.daily[1].requestCount == 42)
        #expect(snapshot.daily[1].modelBreakdowns?.first?.requestCount == 42)
        #expect(snapshot.daily[1].modelBreakdowns?.first?.modelName == "gpt-5.2-codex")
    }

    private static func queryValue(_ name: String, in request: URLRequest) -> String? {
        guard let url = request.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        return components.queryItems?.first(where: { $0.name == name })?.value
    }

    private static func localNoon(year: Int, month: Int, day: Int) throws -> Date {
        try #require(Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: 12)))
    }
}

private actor OpenAIAdminUsagePaginationScript: ProviderHTTPTransport {
    private var recordedRequests: [URLRequest] = []

    func requests() -> [URLRequest] {
        self.recordedRequests
    }

    func data(for request: URLRequest) throws -> (Data, URLResponse) {
        self.recordedRequests.append(request)
        let url = request.url ?? URL(string: "https://api.openai.test")!
        let page = Self.queryValue("page", in: url)
        let body: String = if url.path.contains("/organization/costs") {
            page == "costs_page_2" ? Self.costsPage2 : Self.costsPage1
        } else if url.path.contains("/usage/completions") {
            page == "completions_page_2" ? Self.completionsPage2 : Self.completionsPage1
        } else {
            #"{"object":"page","data":[],"has_more":false,"next_page":null}"#
        }
        return (Data(body.utf8), HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil)!)
    }

    private static func queryValue(_ name: String, in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == name })?
            .value
    }

    private static let costsPage1 = """
    {
      "object": "page",
      "data": [
        {
          "object": "bucket",
          "start_time": 1700000000,
          "end_time": 1700086400,
          "results": [
            {
              "object": "organization.costs.result",
              "amount": { "value": 1.25, "currency": "usd" },
              "line_item": "Text tokens"
            }
          ]
        }
      ],
      "has_more": true,
      "next_page": "costs_page_2"
    }
    """

    private static let costsPage2 = """
    {
      "object": "page",
      "data": [
        {
          "object": "bucket",
          "start_time": 1700000000,
          "end_time": 1700086400,
          "results": [
            {
              "object": "organization.costs.result",
              "amount": { "value": 2.75, "currency": "usd" },
              "line_item": "Web search tool calls"
            }
          ]
        }
      ],
      "has_more": false,
      "next_page": null
    }
    """

    private static let completionsPage1 = """
    {
      "object": "page",
      "data": [
        {
          "object": "bucket",
          "start_time": 1700000000,
          "end_time": 1700086400,
          "results": [
            {
              "object": "organization.usage.completions.result",
              "input_tokens": 10,
              "output_tokens": 5,
              "num_model_requests": 1,
              "model": "gpt-5.2"
            }
          ]
        }
      ],
      "has_more": true,
      "next_page": "completions_page_2"
    }
    """

    private static let completionsPage2 = """
    {
      "object": "page",
      "data": [
        {
          "object": "bucket",
          "start_time": 1700000000,
          "end_time": 1700086400,
          "results": [
            {
              "object": "organization.usage.completions.result",
              "input_tokens": 20,
              "output_tokens": 10,
              "num_model_requests": 2,
              "model": "gpt-5.2"
            }
          ]
        }
      ],
      "has_more": false,
      "next_page": null
    }
    """
}

private actor OpenAIAdminUsageRepeatingCursorScript: ProviderHTTPTransport {
    func data(for request: URLRequest) throws -> (Data, URLResponse) {
        let url = request.url ?? URL(string: "https://api.openai.test")!
        let body = """
        {
          "object": "page",
          "data": [],
          "has_more": true,
          "next_page": "same_page"
        }
        """
        return (Data(body.utf8), HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil)!)
    }
}

private actor OpenAIAdminUsageMissingCursorScript: ProviderHTTPTransport {
    func data(for request: URLRequest) throws -> (Data, URLResponse) {
        let url = request.url ?? URL(string: "https://api.openai.test")!
        let body = """
        {
          "object": "page",
          "data": [],
          "has_more": true,
          "next_page": null
        }
        """
        return (Data(body.utf8), HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil)!)
    }
}

private actor OpenAIAdminUsageMalformedPageScript: ProviderHTTPTransport {
    private let costs: String
    private let completions: String

    init(costs: String, completions: String) {
        self.costs = costs
        self.completions = completions
    }

    func data(for request: URLRequest) throws -> (Data, URLResponse) {
        let url = request.url ?? URL(string: "https://api.openai.test")!
        let body = url.path.contains("/usage/completions") ? self.completions : self.costs
        return (Data(body.utf8), HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil)!)
    }
}

private actor OpenAIAdminUsageRetryScript: ProviderHTTPTransport {
    private let costs: Data
    private let completions: Data
    private var completionsRequests = 0

    init(costs: Data, completions: Data) {
        self.costs = costs
        self.completions = completions
    }

    func completionsRequestCount() -> Int {
        self.completionsRequests
    }

    func data(for request: URLRequest) throws -> (Data, URLResponse) {
        let url = request.url ?? URL(string: "https://api.openai.test")!
        if url.path.contains("/usage/completions") {
            self.completionsRequests += 1
            if self.completionsRequests == 1 {
                return (Data(), HTTPURLResponse(
                    url: url,
                    statusCode: 503,
                    httpVersion: "HTTP/1.1",
                    headerFields: nil)!)
            }
            return (self.completions, HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil)!)
        }

        return (self.costs, HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil)!)
    }
}
