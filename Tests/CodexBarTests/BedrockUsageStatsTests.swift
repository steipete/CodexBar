import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct BedrockUsageStatsTests {
    @Test
    func `to usage snapshot with budget shows primary window`() {
        let snapshot = BedrockUsageSnapshot(
            monthlySpend: 50,
            monthlyBudget: 200,
            inputTokens: 1_500_000,
            outputTokens: 500_000,
            requestCount: 42,
            region: "us-east-1",
            updatedAt: Date(timeIntervalSince1970: 1_739_841_600))

        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 25)
        #expect(usage.primary?.resetDescription == "Monthly budget")
        #expect(usage.primary?.resetsAt != nil)
        #expect(usage.providerCost?.used == 50)
        #expect(usage.providerCost?.limit == 200)
        #expect(usage.providerCost?.currencyCode == "USD")
        #expect(usage.providerCost?.period == "Monthly")
        #expect(usage.identity?.providerID == .bedrock)
        #expect(usage.identity?.loginMethod?.contains("Spend: $50.00") == true)
        #expect(usage.identity?.loginMethod?.contains("Claude 14d: 2.0M tokens") == true)
        #expect(usage.identity?.loginMethod?.contains("Requests: 42") == true)
    }

    @Test
    func `to usage snapshot without budget omits primary window`() {
        let snapshot = BedrockUsageSnapshot(
            monthlySpend: 75.5,
            monthlyBudget: nil,
            region: "us-west-2",
            updatedAt: Date(timeIntervalSince1970: 1_739_841_600))

        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary == nil)
        #expect(usage.providerCost?.used == 75.5)
        #expect(usage.providerCost?.limit == 0)
    }

    @Test
    func `settings reader parses credentials from environment`() {
        let env = [
            "AWS_ACCESS_KEY_ID": "AKIAIOSFODNN7EXAMPLE",
            "AWS_SECRET_ACCESS_KEY": "secret",
            "AWS_REGION": "eu-west-1",
            "CODEXBAR_BEDROCK_BUDGET": "500",
        ]

        #expect(BedrockSettingsReader.accessKeyID(environment: env) == "AKIAIOSFODNN7EXAMPLE")
        #expect(BedrockSettingsReader.secretAccessKey(environment: env) == "secret")
        #expect(BedrockSettingsReader.region(environment: env) == "eu-west-1")
        #expect(BedrockSettingsReader.budget(environment: env) == 500)
        #expect(BedrockSettingsReader.hasCredentials(environment: env))
    }

    @Test
    func `settings reader requires both credential fields`() {
        #expect(!BedrockSettingsReader.hasCredentials(environment: [:]))
        #expect(!BedrockSettingsReader.hasCredentials(environment: [
            "AWS_ACCESS_KEY_ID": "AKIATEST",
        ]))
        #expect(!BedrockSettingsReader.hasCredentials(environment: [
            "AWS_SECRET_ACCESS_KEY": "secret",
        ]))
    }

    @Test
    func `cost explorer response parsing extracts total`() async throws {
        let registered = URLProtocol.registerClass(BedrockStubURLProtocol.self)
        defer {
            if registered {
                URLProtocol.unregisterClass(BedrockStubURLProtocol.self)
            }
            BedrockStubURLProtocol.handler = nil
        }

        BedrockStubURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            let body = """
            {
                "ResultsByTime": [
                    {
                        "TimePeriod": {"Start": "2026-04-01", "End": "2026-04-06"},
                        "Groups": [
                            {
                                "Keys": ["Claude Opus (Bedrock Edition)"],
                                "Metrics": {"UnblendedCost": {"Amount": "30.00", "Unit": "USD"}}
                            },
                            {
                                "Keys": ["Claude Sonnet (Bedrock Edition)"],
                                "Metrics": {"UnblendedCost": {"Amount": "12.50", "Unit": "USD"}}
                            },
                            {
                                "Keys": ["Amazon EC2"],
                                "Metrics": {"UnblendedCost": {"Amount": "5.00", "Unit": "USD"}}
                            }
                        ]
                    }
                ]
            }
            """
            return Self.makeResponse(url: url, body: body, statusCode: 200)
        }

        let credentials = BedrockAWSSigner.Credentials(
            accessKeyID: "AKIATEST",
            secretAccessKey: "testSecret",
            sessionToken: nil)

        let usage = try await BedrockUsageFetcher.fetchUsage(
            credentials: credentials,
            region: "us-east-1",
            budget: 100,
            environment: ["CODEXBAR_BEDROCK_API_URL": "https://bedrock.test"])

        #expect(usage.monthlySpend == 42.50)
        #expect(usage.monthlyBudget == 100)
        #expect(usage.region == "us-east-1")
    }

    @Test
    func `cost explorer data unavailable response returns zero usage`() async throws {
        let registered = URLProtocol.registerClass(BedrockStubURLProtocol.self)
        defer {
            if registered {
                URLProtocol.unregisterClass(BedrockStubURLProtocol.self)
            }
            BedrockStubURLProtocol.handler = nil
        }

        BedrockStubURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            return Self.makeResponse(
                url: url,
                body: #"{"__type":"com.amazonaws.ce#DataUnavailableException","message":"Data is not ready"}"#,
                statusCode: 400)
        }

        let credentials = BedrockAWSSigner.Credentials(
            accessKeyID: "AKIATEST",
            secretAccessKey: "testSecret",
            sessionToken: nil)

        let usage = try await BedrockUsageFetcher.fetchUsage(
            credentials: credentials,
            region: "us-east-1",
            budget: 100,
            environment: [BedrockSettingsReader.apiURLKey: "https://bedrock.test"])

        #expect(usage.monthlySpend == 0)
        #expect(usage.monthlyBudget == 100)
    }

    @Test
    func `cost explorer unrelated bad request remains an API error`() async throws {
        let registered = URLProtocol.registerClass(BedrockStubURLProtocol.self)
        defer {
            if registered {
                URLProtocol.unregisterClass(BedrockStubURLProtocol.self)
            }
            BedrockStubURLProtocol.handler = nil
        }

        BedrockStubURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            return Self.makeResponse(
                url: url,
                body: #"{"__type":"ValidationException","message":"Invalid request"}"#,
                statusCode: 400)
        }

        let credentials = BedrockAWSSigner.Credentials(
            accessKeyID: "AKIATEST",
            secretAccessKey: "testSecret",
            sessionToken: nil)

        await #expect(throws: BedrockUsageError.apiError("HTTP 400")) {
            try await BedrockUsageFetcher.fetchUsage(
                credentials: credentials,
                region: "us-east-1",
                budget: nil,
                environment: [BedrockSettingsReader.apiURLKey: "https://bedrock.test"])
        }
    }

    @Test
    func `cost explorer rejects remote HTTP override before transport`() async throws {
        let registered = URLProtocol.registerClass(BedrockStubURLProtocol.self)
        defer {
            if registered {
                URLProtocol.unregisterClass(BedrockStubURLProtocol.self)
            }
            BedrockStubURLProtocol.handler = nil
        }
        let capture = BedrockRequestCapture()
        BedrockStubURLProtocol.handler = { request in
            capture.append(request)
            throw URLError(.badURL)
        }

        await #expect(throws: BedrockUsageError.parseFailed("invalid endpoint override")) {
            try await BedrockUsageFetcher.fetchUsage(
                credentials: Self.testCredentials,
                region: "us-east-1",
                budget: nil,
                environment: [BedrockSettingsReader.apiURLKey: "http://bedrock.test"])
        }
        #expect(capture.requests.isEmpty)
    }

    @Test
    func `cost explorer pagination aggregates monthly total`() async throws {
        let registered = URLProtocol.registerClass(BedrockStubURLProtocol.self)
        defer {
            if registered {
                URLProtocol.unregisterClass(BedrockStubURLProtocol.self)
            }
            BedrockStubURLProtocol.handler = nil
        }

        let responses = BedrockStubResponseQueue([
            """
            {
                "NextPageToken": "page-2",
                "ResultsByTime": [
                    {
                        "TimePeriod": {"Start": "2026-04-01", "End": "2026-04-06"},
                        "Groups": [
                            {
                                "Keys": ["Amazon EC2"],
                                "Metrics": {"UnblendedCost": {"Amount": "5.00", "Unit": "USD"}}
                            }
                        ]
                    }
                ]
            }
            """,
            """
            {
                "ResultsByTime": [
                    {
                        "TimePeriod": {"Start": "2026-04-01", "End": "2026-04-06"},
                        "Groups": [
                            {
                                "Keys": ["Amazon Bedrock"],
                                "Metrics": {"UnblendedCost": {"Amount": "12.00", "Unit": "USD"}}
                            },
                            {
                                "Keys": ["Claude Sonnet (Bedrock Edition)"],
                                "Metrics": {"UnblendedCost": {"Amount": "8.00", "Unit": "USD"}}
                            }
                        ]
                    }
                ]
            }
            """,
        ])
        BedrockStubURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            return responses.next(url: url)
        }

        let credentials = BedrockAWSSigner.Credentials(
            accessKeyID: "AKIATEST",
            secretAccessKey: "testSecret",
            sessionToken: nil)

        let usage = try await BedrockUsageFetcher.fetchUsage(
            credentials: credentials,
            region: "us-east-1",
            budget: nil,
            environment: [BedrockSettingsReader.apiURLKey: "https://bedrock.test"])

        #expect(usage.monthlySpend == 20)
        #expect(responses.remainingCount == 0)
    }

    @Test
    func `cost usage fetcher uses provided bedrock environment`() async throws {
        let registered = URLProtocol.registerClass(BedrockStubURLProtocol.self)
        defer {
            if registered {
                URLProtocol.unregisterClass(BedrockStubURLProtocol.self)
            }
            BedrockStubURLProtocol.handler = nil
        }

        let responses = BedrockStubResponseQueue([
            """
            {
                "NextPageToken": "daily-page-2",
                "ResultsByTime": [
                    {
                        "TimePeriod": {"Start": "2025-12-10", "End": "2025-12-11"},
                        "Groups": [
                            {
                                "Keys": ["Amazon EC2"],
                                "Metrics": {"UnblendedCost": {"Amount": "5.00", "Unit": "USD"}}
                            }
                        ]
                    }
                ]
            }
            """,
            """
            {
                "ResultsByTime": [
                    {
                        "TimePeriod": {"Start": "2025-12-10", "End": "2025-12-11"},
                        "Groups": [
                            {
                                "Keys": ["Amazon Bedrock"],
                                "Metrics": {"UnblendedCost": {"Amount": "7.25", "Unit": "USD"}}
                            }
                        ]
                    }
                ]
            }
            """,
        ])
        BedrockStubURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            return responses.next(url: url)
        }

        let snapshot = try await CostUsageFetcher().loadTokenSnapshot(
            provider: .bedrock,
            environment: [
                BedrockSettingsReader.accessKeyIDKey: "AKIATEST",
                BedrockSettingsReader.secretAccessKeyKey: "testSecret",
                BedrockSettingsReader.apiURLKey: "https://bedrock.test",
            ],
            now: Date(timeIntervalSince1970: 1_765_324_800))

        #expect(snapshot.last30DaysCostUSD == 7.25)
        #expect(snapshot.sessionCostUSD == 7.25)
        #expect(snapshot.daily.map(\.date) == ["2025-12-10"])
        #expect(responses.remainingCount == 0)
    }

    @Test
    func `current month range uses UTC calendar`() throws {
        let originalTimeZone = NSTimeZone.default
        NSTimeZone.default = TimeZone(secondsFromGMT: 14 * 60 * 60)!
        defer {
            NSTimeZone.default = originalTimeZone
        }

        let now = try #require(ISO8601DateFormatter().date(from: "2026-05-10T12:00:00Z"))
        let range = BedrockUsageFetcher.currentMonthRange(now: now)

        #expect(range.start == "2026-05-01")
        #expect(range.end == "2026-05-11")
    }

    @Test
    func `cloudwatch fetch aggregates Claude activity with bounded signed query`() async throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-06-19T12:00:00Z"))
        let capture = BedrockRequestCapture()
        let transport = ProviderHTTPTransportHandler { request in
            capture.append(request)
            let requestURL = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: requestURL,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]))
            let body = """
            {
                "MetricDataResults": [
                    {"Id":"inputTokens","StatusCode":"Complete","Values":[1000,2500]},
                    {"Id":"outputTokens","StatusCode":"Complete","Values":[400,600]},
                    {"Id":"requests","StatusCode":"Complete","Values":[7,8]}
                ]
            }
            """
            return (Data(body.utf8), response)
        }

        let activity = try await BedrockCloudWatchUsageFetcher.fetch(
            credentials: Self.testCredentials,
            region: "us-west-2",
            now: now,
            endpointOverride: "https://cloudwatch.test",
            transport: transport)

        #expect(activity == BedrockClaudeActivity(inputTokens: 3500, outputTokens: 1000, requestCount: 15))
        let request = try #require(capture.requests.first)
        #expect(capture.requests.count == 1)
        #expect(request.value(forHTTPHeaderField: "X-Amz-Target") ==
            "GraniteServiceVersion20100801.GetMetricData")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-amz-json-1.0")
        #expect(request.value(forHTTPHeaderField: "Authorization")?.contains(
            "/us-west-2/monitoring/aws4_request") == true)

        let requestBody = try #require(request.httpBody)
        let payload = try #require(try JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
        #expect(payload["StartTime"] as? Double == now.timeIntervalSince1970 - 14 * 24 * 60 * 60)
        #expect(payload["EndTime"] as? Double == now.timeIntervalSince1970)
        let queries = try #require(payload["MetricDataQueries"] as? [[String: Any]])
        #expect(queries.count == 3)
        #expect(queries.allSatisfy { query in
            guard let expression = query["Expression"] as? String else { return false }
            return expression.hasPrefix("SUM(SEARCH(") && expression.contains("claude") &&
                expression.contains("86400")
        })
    }

    @Test
    func `cloudwatch pagination aggregates pages`() async throws {
        let transport = ProviderHTTPTransportHandler { request in
            let requestBody = try #require(request.httpBody)
            let payload = try #require(JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
            let isSecondPage = payload["NextToken"] as? String == "page-2"
            let body = if isSecondPage {
                """
                {"MetricDataResults":[{"Id":"inputTokens","StatusCode":"Complete","Values":[3]}]}
                """
            } else {
                """
                {
                    "NextToken":"page-2",
                    "MetricDataResults":[{"Id":"inputTokens","StatusCode":"Complete","Values":[2]}]
                }
                """
            }
            let requestURL = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: requestURL,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil))
            return (Data(body.utf8), response)
        }

        let activity = try await BedrockCloudWatchUsageFetcher.fetch(
            credentials: Self.testCredentials,
            region: "us-east-1",
            now: Date(timeIntervalSince1970: 1_750_000_000),
            endpointOverride: "https://cloudwatch.test",
            transport: transport)

        #expect(activity.inputTokens == 5)
        #expect(activity.outputTokens == 0)
        #expect(activity.requestCount == 0)
    }

    @Test
    func `cloudwatch rejects incomplete search results`() async throws {
        let transport = ProviderHTTPTransportHandler { request in
            let requestURL = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: requestURL,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil))
            let body = #"{"Messages":[{"Code":"MaxQueryLimit","Value":"Maximum number exceeded"}]}"#
            return (Data(body.utf8), response)
        }

        await #expect(throws: BedrockUsageError.cloudWatchParseFailed(
            "CloudWatch reported incomplete results"))
        {
            try await BedrockCloudWatchUsageFetcher.fetch(
                credentials: Self.testCredentials,
                region: "us-east-1",
                now: Date(timeIntervalSince1970: 1_750_000_000),
                endpointOverride: "https://cloudwatch.test",
                transport: transport)
        }
    }

    @Test
    func `cloudwatch permission failure preserves cost explorer usage`() async throws {
        let registered = URLProtocol.registerClass(BedrockStubURLProtocol.self)
        defer {
            if registered {
                URLProtocol.unregisterClass(BedrockStubURLProtocol.self)
            }
            BedrockStubURLProtocol.handler = nil
        }
        BedrockStubURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            let body = """
            {
                "ResultsByTime": [{
                    "Groups": [{
                        "Keys": ["Amazon Bedrock"],
                        "Metrics": {"UnblendedCost": {"Amount": "12.50"}}
                    }]
                }]
            }
            """
            return Self.makeResponse(url: url, body: body)
        }
        let cloudWatchTransport = ProviderHTTPTransportHandler { request in
            let requestURL = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: requestURL,
                statusCode: 403,
                httpVersion: "HTTP/1.1",
                headerFields: nil))
            return (Data(), response)
        }
        let now = Date(timeIntervalSince1970: 1_750_000_000)

        let usage = try await BedrockUsageFetcher.fetchUsage(
            credentials: Self.testCredentials,
            region: "us-east-1",
            budget: nil,
            environment: [
                BedrockSettingsReader.apiURLKey: "https://bedrock.test",
                BedrockSettingsReader.cloudWatchAPIURLKey: "https://cloudwatch.test",
            ],
            now: now,
            cloudWatchTransport: cloudWatchTransport)

        #expect(usage.monthlySpend == 12.5)
        #expect(usage.inputTokens == nil)
        #expect(usage.outputTokens == nil)
        #expect(usage.requestCount == nil)
        #expect(usage.updatedAt == now)
    }

    @Test
    func `cloudwatch invalid override fails closed without transport`() async throws {
        let capture = BedrockRequestCapture()
        let transport = ProviderHTTPTransportHandler { request in
            capture.append(request)
            throw URLError(.badURL)
        }

        for override in ["   ", "not-an-absolute-url", "http://cloudwatch.test"] {
            await #expect(throws: BedrockUsageError.cloudWatchParseFailed("invalid endpoint override")) {
                try await BedrockCloudWatchUsageFetcher.fetch(
                    credentials: Self.testCredentials,
                    region: "us-east-1",
                    now: Date(timeIntervalSince1970: 1_750_000_000),
                    endpointOverride: override,
                    transport: transport)
            }
        }
        #expect(capture.requests.isEmpty)
    }

    @Test
    func `cloudwatch allows HTTP only for loopback overrides`() async throws {
        let capture = BedrockRequestCapture()
        let transport = ProviderHTTPTransportHandler { request in
            capture.append(request)
            let requestURL = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: requestURL,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil))
            return (Data(#"{"MetricDataResults":[]}"#.utf8), response)
        }
        let overrides = [
            "http://localhost:8080",
            "http://127.42.0.1:8080",
            "http://[::1]:8080",
        ]

        for endpointOverride in overrides {
            _ = try await BedrockCloudWatchUsageFetcher.fetch(
                credentials: Self.testCredentials,
                region: "us-east-1",
                now: Date(timeIntervalSince1970: 1_750_000_000),
                endpointOverride: endpointOverride,
                transport: transport)
        }

        #expect(capture.requests.compactMap(\.url?.absoluteString) == overrides)
    }

    @Test
    func `cloudwatch resolves AWS partition endpoints`() async throws {
        let capture = BedrockRequestCapture()
        let transport = ProviderHTTPTransportHandler { request in
            capture.append(request)
            let requestURL = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: requestURL,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil))
            return (Data(#"{"MetricDataResults":[]}"#.utf8), response)
        }
        let cases = [
            ("us-east-1", "monitoring.us-east-1.amazonaws.com"),
            ("us-gov-west-1", "monitoring.us-gov-west-1.amazonaws.com"),
            ("cn-north-1", "monitoring.cn-north-1.amazonaws.com.cn"),
            ("eusc-de-east-1", "monitoring.eusc-de-east-1.amazonaws.eu"),
            ("us-iso-east-1", "monitoring.us-iso-east-1.c2s.ic.gov"),
            ("us-isob-east-1", "monitoring.us-isob-east-1.sc2s.sgov.gov"),
            ("eu-isoe-west-1", "monitoring.eu-isoe-west-1.cloud.adc-e.uk"),
            ("us-isof-south-1", "monitoring.us-isof-south-1.csp.hci.ic.gov"),
        ]

        for (region, _) in cases {
            _ = try await BedrockCloudWatchUsageFetcher.fetch(
                credentials: Self.testCredentials,
                region: region,
                now: Date(timeIntervalSince1970: 1_750_000_000),
                endpointOverride: nil,
                transport: transport)
        }

        #expect(capture.requests.compactMap(\.url?.host) == cases.map(\.1))
    }

    private static let testCredentials = BedrockAWSSigner.Credentials(
        accessKeyID: "AKIATEST",
        secretAccessKey: "testSecret",
        sessionToken: nil)

    private final class BedrockStubResponseQueue {
        private let lock = NSLock()
        private var bodies: [String]

        init(_ bodies: [String]) {
            self.bodies = bodies
        }

        var remainingCount: Int {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.bodies.count
        }

        func next(url: URL) -> (HTTPURLResponse, Data) {
            self.lock.lock()
            let body = self.bodies.isEmpty ? #"{"ResultsByTime":[]}"# : self.bodies.removeFirst()
            self.lock.unlock()

            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!
            return (response, Data(body.utf8))
        }
    }

    private static func makeResponse(
        url: URL,
        body: String,
        statusCode: Int = 200) -> (HTTPURLResponse, Data)
    {
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        return (response, Data(body.utf8))
    }
}

private final class BedrockRequestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []

    var requests: [URLRequest] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.storage
    }

    func append(_ request: URLRequest) {
        self.lock.lock()
        self.storage.append(request)
        self.lock.unlock()
    }
}

final class BedrockStubURLProtocol: URLProtocol {
    private static let _handlerBox = LockIsolated<((URLRequest) throws -> (HTTPURLResponse, Data))?>(nil)
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))? {
        get { Self._handlerBox.value }
        set { Self._handlerBox.setValue(newValue) }
    }

    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "bedrock.test"
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
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
