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
    func `budget used percent is clamped to 100`() {
        let snapshot = BedrockUsageSnapshot(
            monthlySpend: 250,
            monthlyBudget: 200,
            region: "us-east-1",
            updatedAt: Date())

        #expect(snapshot.budgetUsedPercent == 100)
    }

    @Test
    func `budget used percent is nil when no budget`() {
        let snapshot = BedrockUsageSnapshot(
            monthlySpend: 50,
            monthlyBudget: nil,
            region: "us-east-1",
            updatedAt: Date())

        #expect(snapshot.budgetUsedPercent == nil)
    }

    @Test
    func `budget used percent is nil when budget is zero`() {
        let snapshot = BedrockUsageSnapshot(
            monthlySpend: 50,
            monthlyBudget: 0,
            region: "us-east-1",
            updatedAt: Date())

        #expect(snapshot.budgetUsedPercent == nil)
    }

    @Test
    func `total tokens combines input and output`() {
        let snapshot = BedrockUsageSnapshot(
            monthlySpend: 10,
            monthlyBudget: nil,
            inputTokens: 1_000_000,
            outputTokens: 500_000,
            region: "us-east-1",
            updatedAt: Date())

        #expect(snapshot.totalTokens == 1_500_000)
    }

    @Test
    func `total tokens is nil when tokens not available`() {
        let snapshot = BedrockUsageSnapshot(
            monthlySpend: 10,
            monthlyBudget: nil,
            inputTokens: nil,
            outputTokens: nil,
            region: "us-east-1",
            updatedAt: Date())

        #expect(snapshot.totalTokens == nil)
    }

    @Test
    func `identity shows spend and budget info`() {
        let snapshot = BedrockUsageSnapshot(
            monthlySpend: 42.5,
            monthlyBudget: 100,
            inputTokens: 2_000_000,
            outputTokens: 800_000,
            region: "us-east-1",
            updatedAt: Date())

        let usage = snapshot.toUsageSnapshot()
        let loginMethod = usage.identity?.loginMethod

        #expect(loginMethod?.contains("Spend: $42.50") == true)
        #expect(loginMethod?.contains("Budget: $100.00") == true)
        #expect(loginMethod?.contains("Tokens: 2.8M") == true)
        #expect(usage.identity?.providerID == .bedrock)
    }

    @Test
    func `identity shows only spend when no budget or tokens`() {
        let snapshot = BedrockUsageSnapshot(
            monthlySpend: 15.75,
            monthlyBudget: nil,
            region: "us-east-1",
            updatedAt: Date())

        let usage = snapshot.toUsageSnapshot()

        #expect(usage.identity?.loginMethod == "Spend: $15.75")
    }

    @Test
    func `formatted token count uses appropriate units`() {
        #expect(BedrockUsageSnapshot.formattedTokenCount(500) == "500")
        #expect(BedrockUsageSnapshot.formattedTokenCount(1500) == "1.5K")
        #expect(BedrockUsageSnapshot.formattedTokenCount(1_500_000) == "1.5M")
    }

    @Test
    func `snapshot round trip preserves data`() throws {
        let original = BedrockUsageSnapshot(
            monthlySpend: 99.99,
            monthlyBudget: 500,
            inputTokens: 3_000_000,
            outputTokens: 1_000_000,
            region: "eu-west-1",
            updatedAt: Date(timeIntervalSince1970: 1_739_841_600))

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        let decoded = try JSONDecoder().decode(BedrockUsageSnapshot.self, from: data)

        #expect(decoded.monthlySpend == 99.99)
        #expect(decoded.monthlyBudget == 500)
        #expect(decoded.inputTokens == 3_000_000)
        #expect(decoded.outputTokens == 1_000_000)
        #expect(decoded.region == "eu-west-1")
    }

    @Test
    func `settings reader parses credentials from environment`() {
        let env = [
            "AWS_ACCESS_KEY_ID": "AKIAIOSFODNN7EXAMPLE",
            "AWS_SECRET_ACCESS_KEY": "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
            "AWS_REGION": "eu-west-1",
            "CODEXBAR_BEDROCK_BUDGET": "500",
        ]

        #expect(BedrockSettingsReader.accessKeyID(environment: env) == "AKIAIOSFODNN7EXAMPLE")
        #expect(BedrockSettingsReader.secretAccessKey(environment: env) == "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
        #expect(BedrockSettingsReader.region(environment: env) == "eu-west-1")
        #expect(BedrockSettingsReader.budget(environment: env) == 500)
        #expect(BedrockSettingsReader.hasCredentials(environment: env) == true)
    }

    @Test
    func `settings reader falls back to default region`() {
        let env: [String: String] = [:]
        #expect(BedrockSettingsReader.region(environment: env) == "us-east-1")
    }

    @Test
    func `settings reader detects missing credentials`() {
        let env: [String: String] = [:]
        #expect(BedrockSettingsReader.hasCredentials(environment: env) == false)
    }

    @Test
    func `settings reader ignores empty budget`() {
        let env = ["CODEXBAR_BEDROCK_BUDGET": ""]
        #expect(BedrockSettingsReader.budget(environment: env) == nil)
    }

    @Test
    func `settings reader ignores negative budget`() {
        let env = ["CODEXBAR_BEDROCK_BUDGET": "-100"]
        #expect(BedrockSettingsReader.budget(environment: env) == nil)
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
                        "Total": {
                            "UnblendedCost": {"Amount": "42.50", "Unit": "USD"}
                        }
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
    func `non200 response throws api error`() async throws {
        let registered = URLProtocol.registerClass(BedrockStubURLProtocol.self)
        defer {
            if registered {
                URLProtocol.unregisterClass(BedrockStubURLProtocol.self)
            }
            BedrockStubURLProtocol.handler = nil
        }

        BedrockStubURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            return Self.makeResponse(url: url, body: #"{"message":"Access Denied"}"#, statusCode: 403)
        }

        let credentials = BedrockAWSSigner.Credentials(
            accessKeyID: "AKIATEST",
            secretAccessKey: "testSecret",
            sessionToken: nil)

        do {
            _ = try await BedrockUsageFetcher.fetchUsage(
                credentials: credentials,
                region: "us-east-1",
                budget: nil,
                environment: ["CODEXBAR_BEDROCK_API_URL": "https://bedrock.test"])
            Issue.record("Expected BedrockUsageError.apiError")
        } catch let error as BedrockUsageError {
            guard case let .apiError(message) = error else {
                Issue.record("Expected apiError, got: \(error)")
                return
            }
            #expect(message == "HTTP 403")
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
