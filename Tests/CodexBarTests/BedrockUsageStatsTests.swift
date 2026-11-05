import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct BedrockUsageStatsTests {
    @Test(arguments: [true, false])
    func `cost selection excludes the preceding UTC bucket`(utcMonthHasStarted: Bool) async throws {
        let registered = URLProtocol.registerClass(BedrockStubURLProtocol.self)
        defer {
            if registered { URLProtocol.unregisterClass(BedrockStubURLProtocol.self) }
            BedrockStubURLProtocol.handler = nil
        }
        let calendar = CostUsageBucketTimeZone.calendar(identifier: "Asia/Tokyo")
        let now = try #require(ISO8601DateFormatter().date(from:
            utcMonthHasStarted ? "2026-03-01T10:00:00Z" : "2026-02-28T16:00:00Z"))
        let rows: [(String, String)] = utcMonthHasStarted
            ? [("2026-02-28", "99.00"), ("2026-03-01", "7.00")] : [("2026-02-28", "99.00")]
        let data = try JSONSerialization.data(withJSONObject: ["ResultsByTime": rows.map { day, cost in
            ["TimePeriod": ["Start": day], "Groups": [[
                "Keys": ["Amazon Bedrock"], "Metrics": ["UnblendedCost": ["Amount": cost, "Unit": "USD"]],
            ]]] as [String: Any]
        }])
        BedrockStubURLProtocol.handler = { request in
            let url = try #require(request.url)
            return try (#require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)), data)
        }
        let snapshot = try await CostUsageFetcher(calendar: calendar).loadTokenSnapshot(
            provider: .bedrock,
            environment: [
                BedrockSettingsReader.accessKeyIDKey: "AKIATEST",
                BedrockSettingsReader.secretAccessKeyKey: "testSecret",
                BedrockSettingsReader.apiURLKey: "https://bedrock.test",
            ],
            now: now,
            historyDays: CostReportingPeriod.monthToDate.days(now: now, calendar: calendar))
        #expect(snapshot.daily.map(\.date) == (utcMonthHasStarted ? ["2026-03-01"] : []))
        #expect(snapshot.last30DaysCostUSD == (utcMonthHasStarted ? 7 : nil))
        #expect(snapshot.last30DaysTokens == nil)
        #expect(snapshot.historyCoverageIsEstablished == utcMonthHasStarted)
    }

    @Test
    func `daily cost history respects the Cost Explorer retention boundary`() throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-04-06T12:00:00Z"))
        let all = BedrockUsageFetcher.dailyRange(since: .distantPast, until: now)
        #expect(all.start == "2025-03-01")
        #expect(all.end == "2026-04-07")
        let recent = try #require(ISO8601DateFormatter().date(from: "2026-04-03T12:00:00Z"))
        #expect(BedrockUsageFetcher.dailyRange(since: recent, until: now).start == "2026-04-03")
        #expect(BedrockUsageFetcher.currentMonthRange(now: now).start == "2026-04-01")
    }

    @Test(arguments: ["9.223372036854776e18", "1e40"])
    func `cloudwatch rejects unrepresentable totals without trapping`(literal: String) async throws {
        let transport = ProviderHTTPTransportHandler { request in
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            let body = """
            {"MetricDataResults":[{"Id":"inputTokens","StatusCode":"Complete","Values":[\(literal)]}]}
            """
            return (Data(body.utf8), response)
        }
        await #expect(throws: BedrockUsageError.cloudWatchParseFailed("invalid metric total")) {
            try await BedrockCloudWatchUsageFetcher.fetch(
                credentials: Self.testCredentials,
                region: "us-east-1",
                now: Date(timeIntervalSince1970: 1_750_000_000),
                endpointOverride: "https://cloudwatch.test",
                transport: transport)
        }
    }

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
    func `cost explorer data unavailable fails without inventing zero usage`() async throws {
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

        let unavailable = ProviderFetchClassifiedError(kind: .providerUnavailable, message: "Spend unavailable")
        await #expect(throws: unavailable) {
            try await BedrockUsageFetcher.fetchUsage(
                credentials: credentials,
                region: "us-east-1",
                budget: 100,
                environment: [BedrockSettingsReader.apiURLKey: "https://bedrock.test"])
        }
        await #expect(throws: unavailable) {
            try await BedrockUsageFetcher.fetchDailyReport(
                credentials: credentials,
                region: "us-east-1",
                since: Date(timeIntervalSince1970: 1_791_849_600),
                until: Date(timeIntervalSince1970: 1_791_936_000),
                environment: [BedrockSettingsReader.apiURLKey: "https://bedrock.test"])
        }
    }

    @Test
    func `cost explorer measured zero remains a successful balance`() async throws {
        let registered = URLProtocol.registerClass(BedrockStubURLProtocol.self)
        defer {
            if registered { URLProtocol.unregisterClass(BedrockStubURLProtocol.self) }
            BedrockStubURLProtocol.handler = nil
        }
        BedrockStubURLProtocol.handler = { request in
            let url = try #require(request.url)
            return Self.makeResponse(
                url: url,
                body: #"""
                {"ResultsByTime":[{"Groups":[{"Keys":["Amazon Bedrock"],
                  "Metrics":{"UnblendedCost":{"Amount":"0.00000000","Unit":"USD"}}}]}]}
                """#,
                statusCode: 200)
        }
        let snapshot = try await BedrockUsageFetcher.fetchUsage(
            credentials: Self.testCredentials,
            region: "us-east-1",
            budget: 100,
            environment: [BedrockSettingsReader.apiURLKey: "https://bedrock.test"])
        #expect(snapshot.monthlySpend == 0)
        #expect(snapshot.toUsageSnapshot().providerCost?.used == 0)
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

        let snapshot = try await CostUsageFetcher(calendar: CostUsageBucketTimeZone.calendar(identifier: "UTC"))
            .loadTokenSnapshot(
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
        NSTimeZone.default = try #require(TimeZone(secondsFromGMT: 14 * 60 * 60))
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

extension BedrockUsageStatsTests {
    @Test
    func `cost cache isolates queries expires and bypasses explicit refreshes`() async throws {
        let registered = URLProtocol.registerClass(BedrockStubURLProtocol.self)
        defer {
            if registered { URLProtocol.unregisterClass(BedrockStubURLProtocol.self) }
            BedrockStubURLProtocol.handler = nil
        }
        let capture = BedrockRequestCapture()
        BedrockStubURLProtocol.handler = { request in
            capture.append(request)
            return try Self.makeResponse(url: #require(request.url), body: #"{"ResultsByTime":[]}"#)
        }
        let cache = BedrockCostExplorerCache()
        let now = try #require(ISO8601DateFormatter().date(from: "2026-04-06T12:00:00Z"))
        let environment = [BedrockSettingsReader.apiURLKey: "https://bedrock.test"]
        func fetch(
            key: String = "account-a",
            region: String = "us-east-1",
            time: Date,
            env: [String: String]? = nil) async throws -> BedrockUsageSnapshot
        {
            try await BedrockUsageFetcher.fetchUsage(
                credentials: .init(accessKeyID: key, secretAccessKey: "fixture", sessionToken: nil),
                region: region,
                budget: nil,
                environment: env ?? environment,
                now: time,
                cache: cache)
        }
        _ = try await fetch(time: now)
        let cached = try await fetch(time: now.addingTimeInterval(60))
        #expect(capture.requests.count == 1)
        #expect(cached.updatedAt == now)
        _ = try await fetch(key: "account-b", time: now)
        _ = try await fetch(key: "account-b", region: "us-west-2", time: now)
        _ = try await fetch(
            key: "account-b",
            region: "us-west-2",
            time: now,
            env: [BedrockSettingsReader.apiURLKey: "https://bedrock.test/other"])
        #expect(capture.requests.count == 4)
        _ = try await fetch(time: now)
        _ = try await fetch(time: now.addingTimeInterval(6 * 60 * 60))
        _ = try await fetch(time: now.addingTimeInterval(24 * 60 * 60))
        #expect(capture.requests.count == 7)
        _ = try await ProviderInteractionContext.$current.withValue(.userInitiated) {
            try await fetch(time: now.addingTimeInterval(24 * 60 * 60 + 60))
        }
        #expect(capture.requests.count == 8)
        _ = try await fetch(time: now)
        #expect(capture.requests.count == 9)
    }

    @Test
    func `failed cost responses never poison successful zero measurements`() async throws {
        let registered = URLProtocol.registerClass(BedrockStubURLProtocol.self)
        defer {
            if registered { URLProtocol.unregisterClass(BedrockStubURLProtocol.self) }
            BedrockStubURLProtocol.handler = nil
        }
        let cache = BedrockCostExplorerCache()
        let capture = BedrockRequestCapture()
        let responses = BedrockStubResponseQueue(["{}", #"{"ResultsByTime":[]}"#])
        BedrockStubURLProtocol.handler = { request in
            capture.append(request)
            return try responses.next(url: #require(request.url))
        }
        let now = Date(timeIntervalSince1970: 1_775_476_800)
        let environment = [BedrockSettingsReader.apiURLKey: "https://bedrock.test"]
        await #expect(throws: BedrockUsageError.parseFailed("Missing ResultsByTime in Cost Explorer response")) {
            try await BedrockUsageFetcher.fetchUsage(
                credentials: Self.testCredentials,
                region: "us-east-1",
                budget: nil,
                environment: environment,
                now: now,
                cache: cache)
        }
        let measured = try await BedrockUsageFetcher.fetchUsage(
            credentials: Self.testCredentials,
            region: "us-east-1",
            budget: nil,
            environment: environment,
            now: now,
            cache: cache)
        let cached = try await BedrockUsageFetcher.fetchUsage(
            credentials: Self.testCredentials,
            region: "us-east-1",
            budget: nil,
            environment: environment,
            now: now.addingTimeInterval(60),
            cache: cache)
        #expect(measured.monthlySpend == 0)
        #expect(cached.monthlySpend == 0)
        #expect(cached.updatedAt == now)
        #expect(capture.requests.count == 2)
    }

    @Test
    func `oversized daily reports are returned without retaining a cache entry`() async throws {
        let registered = URLProtocol.registerClass(BedrockStubURLProtocol.self)
        defer {
            if registered { URLProtocol.unregisterClass(BedrockStubURLProtocol.self) }
            BedrockStubURLProtocol.handler = nil
        }
        let body = try JSONSerialization.data(withJSONObject: ["ResultsByTime": [[
            "TimePeriod": ["Start": "2026-04-06"],
            "Groups": [[
                "Keys": ["Amazon Bedrock " + String(repeating: "x", count: 600_000)],
                "Metrics": ["UnblendedCost": ["Amount": "1"]],
            ]],
        ]]])
        let capture = BedrockRequestCapture()
        BedrockStubURLProtocol.handler = { request in
            capture.append(request)
            let url = try #require(request.url)
            return try (#require(HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil)), body)
        }
        let cache = BedrockCostExplorerCache()
        let now = try #require(ISO8601DateFormatter().date(from: "2026-04-06T12:00:00Z"))
        for _ in 0..<2 {
            let result = try await BedrockUsageFetcher.fetchDailyReport(
                credentials: Self.testCredentials,
                region: "us-east-1",
                since: now,
                until: now,
                environment: [BedrockSettingsReader.apiURLKey: "https://bedrock.test"],
                cache: cache)
            #expect(result.report.data.first?.costUSD == 1)
        }
        #expect(capture.requests.count == 2)
        #expect(cache.daily.load(now: now) == nil)
    }

    @Test
    func `repeated cost refreshes reuse paid measurements and their timestamps`() async throws {
        let registered = URLProtocol.registerClass(BedrockStubURLProtocol.self)
        defer {
            if registered { URLProtocol.unregisterClass(BedrockStubURLProtocol.self) }
            BedrockStubURLProtocol.handler = nil
        }
        let capture = BedrockRequestCapture()
        BedrockStubURLProtocol.handler = { request in
            capture.append(request)
            return try Self.makeResponse(
                url: #require(request.url),
                body: #"{"ResultsByTime":[]}"#)
        }
        let now = try #require(ISO8601DateFormatter().date(from: "2026-04-06T12:00:00Z"))
        let later = now.addingTimeInterval(60)
        let credentials = BedrockAWSSigner.Credentials(
            accessKeyID: "cache-regression-" + UUID().uuidString, secretAccessKey: "fixture", sessionToken: nil)
        let offline = ProviderHTTPTransportHandler { _ in throw URLError(.notConnectedToInternet) }
        let first = try await BedrockUsageFetcher.fetchUsage(
            credentials: credentials,
            region: "us-east-1",
            budget: 100,
            environment: [:],
            now: now,
            cloudWatchTransport: offline)
        let second = try await BedrockUsageFetcher.fetchUsage(
            credentials: credentials,
            region: "us-east-1",
            budget: 100,
            environment: [:],
            now: later,
            cloudWatchTransport: offline)
        #expect(capture.requests.count == 1)
        #expect(second.monthlySpend == first.monthlySpend)
        #expect(second.updatedAt == first.updatedAt)
        #expect(second.toUsageSnapshot().providerCost?.updatedAt == now)

        let fetcher = CostUsageFetcher(calendar: CostUsageBucketTimeZone.calendar(identifier: "UTC"))
        let environment = [
            BedrockSettingsReader.accessKeyIDKey: credentials.accessKeyID,
            BedrockSettingsReader.secretAccessKeyKey: "fixture",
            "AWS_REGION": "us-east-1",
        ]
        let daily = try await fetcher.loadTokenSnapshot(
            provider: .bedrock,
            environment: environment,
            now: now,
            allowPricingRefresh: false,
            includePiSessions: false)
        let cached = try await fetcher.loadTokenSnapshot(
            provider: .bedrock,
            environment: environment,
            now: later,
            allowPricingRefresh: false,
            includePiSessions: false)
        #expect(capture.requests.count == 2)
        #expect(cached.updatedAt == daily.updatedAt)
        _ = try await fetcher.loadTokenSnapshot(
            provider: .bedrock,
            environment: environment,
            now: later,
            forceRefresh: true,
            allowPricingRefresh: false,
            includePiSessions: false)
        #expect(capture.requests.count == 3)
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
        ["bedrock.test", "ce.us-east-1.amazonaws.com"].contains(request.url?.host ?? "")
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
