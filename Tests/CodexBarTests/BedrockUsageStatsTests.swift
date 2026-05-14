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

final class BedrockStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

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
