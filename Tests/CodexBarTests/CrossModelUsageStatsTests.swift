import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CrossModelUsageStatsTests {
    @Test
    func `to usage snapshot exposes balance identity and omits rate windows`() {
        let snapshot = CrossModelUsageSnapshot(
            currency: "USD",
            balance: 8.059489,
            uncollected: 0,
            daily: CrossModelUsageWindow(
                cost: 0.005746,
                promptTokens: 9176,
                completionTokens: 3291,
                totalTokens: 12467,
                requestCount: 9,
                successCount: 9),
            weekly: nil,
            monthly: nil,
            updatedAt: Date(timeIntervalSince1970: 1_739_841_600))

        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary == nil)
        #expect(usage.dataConfidence == .exact)
        #expect(usage.identity?.providerID == .crossmodel)
        #expect(usage.identity?.loginMethod == "API key")
        #expect(usage.crossModelUsage?.balance == 8.059489)
        #expect(usage.crossModelUsage?.daily?.totalTokens == 12467)
    }

    @Test
    func `fetch usage converts micro units and reads both endpoints`() async throws {
        let registered = URLProtocol.registerClass(CrossModelStubURLProtocol.self)
        defer {
            if registered {
                URLProtocol.unregisterClass(CrossModelStubURLProtocol.self)
            }
            CrossModelStubURLProtocol.handler = nil
        }

        CrossModelStubURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            switch url.path {
            case "/v1/credits":
                #expect(request.timeoutInterval == 15)
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer cm-test")
                let body = #"{"currency":"USD","balance_micro":8059489,"uncollected_micro":0}"#
                return Self.makeResponse(url: url, body: body, statusCode: 200)
            case "/v1/usage":
                #expect(request.timeoutInterval == 3)
                let body = #"""
                {"currency":"USD",
                 "daily":{"cost_micro":5746,"prompt_tokens":9176,"completion_tokens":3291,
                          "total_tokens":12467,"request_count":9,"success_count":9},
                 "weekly":{"cost_micro":665033,"prompt_tokens":1368222,"completion_tokens":557568,
                           "total_tokens":1925790,"request_count":529,"success_count":529},
                 "monthly":{"cost_micro":5368746,"prompt_tokens":33488242,"completion_tokens":1924229,
                            "total_tokens":35412471,"request_count":3166,"success_count":3057}}
                """#
                return Self.makeResponse(url: url, body: body, statusCode: 200)
            default:
                return Self.makeResponse(url: url, body: "{}", statusCode: 404)
            }
        }

        let usage = try await CrossModelUsageFetcher.fetchUsage(
            apiKey: "cm-test",
            environment: ["CROSSMODEL_API_URL": "https://crossmodel.test/v1"])

        #expect(usage.currency == "USD")
        #expect(usage.balance == 8.059489)
        #expect(usage.uncollected == 0)
        #expect(usage.daily?.cost == 0.005746)
        #expect(usage.weekly?.cost == 0.665033)
        #expect(usage.monthly?.cost == 5.368746)
        #expect(usage.monthly?.requestCount == 3166)
        #expect(usage.monthly?.successCount == 3057)
        #expect(usage.balanceDisplay == "$8.06")
    }

    @Test
    func `fetch usage propagates cancellation from optional enrichment`() async throws {
        let transport = ProviderHTTPTransportHandler { request in
            guard let url = request.url else { throw URLError(.badURL) }
            if url.path == "/v1/credits" {
                let body = #"{"currency":"USD","balance_micro":1500000,"uncollected_micro":0}"#
                let (response, data) = Self.makeResponse(url: url, body: body)
                return (data, response)
            }
            throw CancellationError()
        }

        do {
            _ = try await CrossModelUsageFetcher.fetchUsage(
                apiKey: "cm-test",
                environment: ["CROSSMODEL_API_URL": "https://crossmodel.test/v1"],
                transport: transport)
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            // Expected: best-effort enrichment must not swallow parent task cancellation.
        }
    }

    @Test
    func `fetch usage maps url session cancellation from optional enrichment`() async throws {
        let transport = ProviderHTTPTransportHandler { request in
            guard let url = request.url else { throw URLError(.badURL) }
            if url.path == "/v1/credits" {
                let body = #"{"currency":"USD","balance_micro":1500000,"uncollected_micro":0}"#
                let (response, data) = Self.makeResponse(url: url, body: body)
                return (data, response)
            }
            throw URLError(.cancelled)
        }

        await #expect(throws: CancellationError.self) {
            _ = try await CrossModelUsageFetcher.fetchUsage(
                apiKey: "cm-test",
                environment: ["CROSSMODEL_API_URL": "https://crossmodel.test/v1"],
                transport: transport)
        }
    }

    @Test
    func `fetch usage keeps balance when usage endpoint fails`() async throws {
        let registered = URLProtocol.registerClass(CrossModelStubURLProtocol.self)
        defer {
            if registered {
                URLProtocol.unregisterClass(CrossModelStubURLProtocol.self)
            }
            CrossModelStubURLProtocol.handler = nil
        }

        CrossModelStubURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            switch url.path {
            case "/v1/credits":
                let body = #"{"currency":"USD","balance_micro":1500000,"uncollected_micro":250000}"#
                return Self.makeResponse(url: url, body: body, statusCode: 200)
            case "/v1/usage":
                return Self.makeResponse(url: url, body: "{}", statusCode: 500)
            default:
                return Self.makeResponse(url: url, body: "{}", statusCode: 404)
            }
        }

        let usage = try await CrossModelUsageFetcher.fetchUsage(
            apiKey: "cm-test",
            environment: ["CROSSMODEL_API_URL": "https://crossmodel.test/v1"])

        #expect(usage.balance == 1.5)
        #expect(usage.uncollected == 0.25)
        #expect(usage.daily == nil)
        #expect(usage.weekly == nil)
        #expect(usage.monthly == nil)
    }

    @Test
    func `fetch usage skips optional usage endpoint when disabled`() async throws {
        let requestedPaths = CrossModelRequestPathRecorder()
        let transport = ProviderHTTPTransportHandler { request in
            guard let url = request.url else { throw URLError(.badURL) }
            requestedPaths.append(url.path)
            switch url.path {
            case "/v1/credits":
                let body = #"{"currency":"USD","balance_micro":1500000,"uncollected_micro":250000}"#
                let (response, data) = Self.makeResponse(url: url, body: body)
                return (data, response)
            case "/v1/usage":
                Issue.record("Optional usage endpoint must not be requested")
                throw URLError(.badURL)
            default:
                throw URLError(.badURL)
            }
        }

        let usage = try await CrossModelUsageFetcher.fetchUsage(
            apiKey: "cm-test",
            environment: ["CROSSMODEL_API_URL": "https://crossmodel.test/v1"],
            includeOptionalUsage: false,
            transport: transport)

        #expect(requestedPaths.snapshot() == ["/v1/credits"])
        #expect(usage.balance == 1.5)
        #expect(usage.uncollected == 0.25)
        #expect(usage.daily == nil)
        #expect(usage.weekly == nil)
        #expect(usage.monthly == nil)
    }

    @Test
    func `fetch usage throws invalid credentials on 401`() async throws {
        let registered = URLProtocol.registerClass(CrossModelStubURLProtocol.self)
        defer {
            if registered {
                URLProtocol.unregisterClass(CrossModelStubURLProtocol.self)
            }
            CrossModelStubURLProtocol.handler = nil
        }

        CrossModelStubURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            let body = #"{"error":{"message":"Invalid API key.","code":"invalid_api_key"}}"#
            return Self.makeResponse(url: url, body: body, statusCode: 401)
        }

        do {
            _ = try await CrossModelUsageFetcher.fetchUsage(
                apiKey: "cm-bogus",
                environment: ["CROSSMODEL_API_URL": "https://crossmodel.test/v1"])
            Issue.record("Expected CrossModelUsageError.invalidCredentials")
        } catch let error as CrossModelUsageError {
            guard case .invalidCredentials = error else {
                Issue.record("Expected invalidCredentials, got: \(error)")
                return
            }
        }
    }

    @Test
    func `fetch usage formats non USD currency without false dollar labels`() async throws {
        let transport = ProviderHTTPTransportHandler { request in
            guard let url = request.url else { throw URLError(.badURL) }
            switch url.path {
            case "/v1/credits":
                let body = #"{"currency":"EUR","balance_micro":8059489,"uncollected_micro":0}"#
                let (response, data) = Self.makeResponse(url: url, body: body)
                return (data, response)
            case "/v1/usage":
                let body = #"""
                {"currency":"EUR",
                 "daily":{"cost_micro":5746,"prompt_tokens":9176,"completion_tokens":3291,
                          "total_tokens":12467,"request_count":9,"success_count":9},
                 "weekly":{"cost_micro":665033,"prompt_tokens":1368222,"completion_tokens":557568,
                           "total_tokens":1925790,"request_count":529,"success_count":529},
                 "monthly":{"cost_micro":5368746,"prompt_tokens":33488242,"completion_tokens":1924229,
                            "total_tokens":35412471,"request_count":3166,"success_count":3057}}
                """#
                let (response, data) = Self.makeResponse(url: url, body: body)
                return (data, response)
            default:
                throw URLError(.badURL)
            }
        }

        let usage = try await CrossModelUsageFetcher.fetchUsage(
            apiKey: "cm-test",
            environment: ["CROSSMODEL_API_URL": "https://crossmodel.test/v1"],
            transport: transport)

        #expect(usage.currency == "EUR")
        #expect(usage.balance == 8.059489)
        #expect(usage.daily?.cost == 0.005746)
        #expect(usage.balanceDisplay.hasPrefix("€"))
        #expect(!usage.balanceDisplay.contains("$"))
    }

    @Test
    func `fetch usage omits usage windows when endpoint currencies differ`() async throws {
        let transport = ProviderHTTPTransportHandler { request in
            guard let url = request.url else { throw URLError(.badURL) }
            switch url.path {
            case "/v1/credits":
                let body = #"{"currency":"EUR","balance_micro":8059489,"uncollected_micro":0}"#
                let (response, data) = Self.makeResponse(url: url, body: body)
                return (data, response)
            case "/v1/usage":
                let body = #"""
                {"currency":"USD",
                 "daily":{"cost_micro":5746,"prompt_tokens":9176,"completion_tokens":3291,
                          "total_tokens":12467,"request_count":9,"success_count":9},
                 "weekly":{"cost_micro":665033,"prompt_tokens":1368222,"completion_tokens":557568,
                           "total_tokens":1925790,"request_count":529,"success_count":529},
                 "monthly":{"cost_micro":5368746,"prompt_tokens":33488242,"completion_tokens":1924229,
                            "total_tokens":35412471,"request_count":3166,"success_count":3057}}
                """#
                let (response, data) = Self.makeResponse(url: url, body: body)
                return (data, response)
            default:
                throw URLError(.badURL)
            }
        }

        let usage = try await CrossModelUsageFetcher.fetchUsage(
            apiKey: "cm-test",
            environment: ["CROSSMODEL_API_URL": "https://crossmodel.test/v1"],
            transport: transport)

        #expect(usage.currency == "EUR")
        #expect(usage.balance == 8.059489)
        #expect(usage.daily == nil)
        #expect(usage.weekly == nil)
        #expect(usage.monthly == nil)
    }

    @Test
    func `fetch usage omits usage windows when usage currency is invalid`() async throws {
        let transport = ProviderHTTPTransportHandler { request in
            guard let url = request.url else { throw URLError(.badURL) }
            switch url.path {
            case "/v1/credits":
                let body = #"{"currency":"EUR","balance_micro":8059489,"uncollected_micro":0}"#
                let (response, data) = Self.makeResponse(url: url, body: body)
                return (data, response)
            case "/v1/usage":
                let body = #"""
                {"currency":" ",
                 "daily":{"cost_micro":5746,"prompt_tokens":9176,"completion_tokens":3291,
                          "total_tokens":12467,"request_count":9,"success_count":9},
                 "weekly":{"cost_micro":665033,"prompt_tokens":1368222,"completion_tokens":557568,
                           "total_tokens":1925790,"request_count":529,"success_count":529},
                 "monthly":{"cost_micro":5368746,"prompt_tokens":33488242,"completion_tokens":1924229,
                            "total_tokens":35412471,"request_count":3166,"success_count":3057}}
                """#
                let (response, data) = Self.makeResponse(url: url, body: body)
                return (data, response)
            default:
                throw URLError(.badURL)
            }
        }

        let usage = try await CrossModelUsageFetcher.fetchUsage(
            apiKey: "cm-test",
            environment: ["CROSSMODEL_API_URL": "https://crossmodel.test/v1"],
            transport: transport)

        #expect(usage.currency == "EUR")
        #expect(usage.balance == 8.059489)
        #expect(usage.daily == nil)
        #expect(usage.weekly == nil)
        #expect(usage.monthly == nil)
    }

    @Test
    func `fetch usage rejects unsafe endpoint override before attaching credentials`() async throws {
        await #expect(throws: CrossModelSettingsError.invalidEndpointOverride("CROSSMODEL_API_URL")) {
            _ = try await CrossModelUsageFetcher.fetchUsage(
                apiKey: "cm-test",
                environment: ["CROSSMODEL_API_URL": "http://api.crossmodel.ai/v1"],
                transport: ProviderHTTPTransportHandler { _ in
                    Issue.record("Transport must not be called for invalid endpoint override")
                    throw URLError(.badURL)
                })
        }
    }

    @Test
    func `fetch usage rejects cross origin credits redirect`() async throws {
        let transport = ProviderHTTPTransportHandler { _ in
            let body = #"{"currency":"USD","balance_micro":1500000,"uncollected_micro":0}"#
            let redirectedURL = URL(string: "https://evil.example/v1/credits")!
            let (response, data) = Self.makeResponse(url: redirectedURL, body: body)
            return (data, response)
        }

        await #expect(throws: CrossModelUsageError.apiError("CrossModel /credits redirected to a different origin")) {
            _ = try await CrossModelUsageFetcher.fetchUsage(
                apiKey: "cm-test",
                environment: ["CROSSMODEL_API_URL": "https://crossmodel.test/v1"],
                transport: transport)
        }
    }

    @Test
    func `fetch usage accepts same origin default https port redirect`() async throws {
        let transport = ProviderHTTPTransportHandler { request in
            guard let url = request.url else { throw URLError(.badURL) }
            if url.path == "/v1/credits" {
                let body = #"{"currency":"USD","balance_micro":1500000,"uncollected_micro":0}"#
                let redirectedURL = URL(string: "https://crossmodel.test:443/v1/credits")!
                let (response, data) = Self.makeResponse(url: redirectedURL, body: body)
                return (data, response)
            }

            let body = #"""
            {"currency":"USD",
             "daily":{"cost_micro":5746,"prompt_tokens":9176,"completion_tokens":3291,
                      "total_tokens":12467,"request_count":9,"success_count":9},
             "weekly":{"cost_micro":665033,"prompt_tokens":1368222,"completion_tokens":557568,
                       "total_tokens":1925790,"request_count":529,"success_count":529},
             "monthly":{"cost_micro":5368746,"prompt_tokens":33488242,"completion_tokens":1924229,
                        "total_tokens":35412471,"request_count":3166,"success_count":3057}}
            """#
            let redirectedURL = URL(string: "https://crossmodel.test:443/v1/usage")!
            let (response, data) = Self.makeResponse(url: redirectedURL, body: body)
            return (data, response)
        }

        let usage = try await CrossModelUsageFetcher.fetchUsage(
            apiKey: "cm-test",
            environment: ["CROSSMODEL_API_URL": "https://crossmodel.test/v1"],
            transport: transport)

        #expect(usage.balance == 1.5)
        #expect(usage.daily?.cost == 0.005746)
    }

    @Test
    func `fetch usage rejects credits redirect to different port`() async throws {
        let transport = ProviderHTTPTransportHandler { _ in
            let body = #"{"currency":"USD","balance_micro":1500000,"uncollected_micro":0}"#
            let redirectedURL = URL(string: "https://crossmodel.test:444/v1/credits")!
            let (response, data) = Self.makeResponse(url: redirectedURL, body: body)
            return (data, response)
        }

        await #expect(throws: CrossModelUsageError.apiError("CrossModel /credits redirected to a different origin")) {
            _ = try await CrossModelUsageFetcher.fetchUsage(
                apiKey: "cm-test",
                environment: ["CROSSMODEL_API_URL": "https://crossmodel.test/v1"],
                transport: transport)
        }
    }

    @Test
    func `fetch usage omits cross origin usage redirect`() async throws {
        let transport = ProviderHTTPTransportHandler { request in
            guard let url = request.url else { throw URLError(.badURL) }
            if url.path == "/v1/credits" {
                let body = #"{"currency":"USD","balance_micro":1500000,"uncollected_micro":0}"#
                let (response, data) = Self.makeResponse(url: url, body: body)
                return (data, response)
            }
            let body = #"""
            {"currency":"USD",
             "daily":{"cost_micro":5746,"prompt_tokens":9176,"completion_tokens":3291,
                      "total_tokens":12467,"request_count":9,"success_count":9},
             "weekly":{"cost_micro":665033,"prompt_tokens":1368222,"completion_tokens":557568,
                       "total_tokens":1925790,"request_count":529,"success_count":529},
             "monthly":{"cost_micro":5368746,"prompt_tokens":33488242,"completion_tokens":1924229,
                        "total_tokens":35412471,"request_count":3166,"success_count":3057}}
            """#
            let redirectedURL = URL(string: "https://evil.example/v1/usage")!
            let (response, data) = Self.makeResponse(url: redirectedURL, body: body)
            return (data, response)
        }

        let usage = try await CrossModelUsageFetcher.fetchUsage(
            apiKey: "cm-test",
            environment: ["CROSSMODEL_API_URL": "https://crossmodel.test/v1"],
            transport: transport)

        #expect(usage.balance == 1.5)
        #expect(usage.daily == nil)
    }

    @Test
    func `fetch usage omits usage redirect to different port`() async throws {
        let transport = ProviderHTTPTransportHandler { request in
            guard let url = request.url else { throw URLError(.badURL) }
            if url.path == "/v1/credits" {
                let body = #"{"currency":"USD","balance_micro":1500000,"uncollected_micro":0}"#
                let (response, data) = Self.makeResponse(url: url, body: body)
                return (data, response)
            }
            let body = #"""
            {"currency":"USD",
             "daily":{"cost_micro":5746,"prompt_tokens":9176,"completion_tokens":3291,
                      "total_tokens":12467,"request_count":9,"success_count":9},
             "weekly":{"cost_micro":665033,"prompt_tokens":1368222,"completion_tokens":557568,
                       "total_tokens":1925790,"request_count":529,"success_count":529},
             "monthly":{"cost_micro":5368746,"prompt_tokens":33488242,"completion_tokens":1924229,
                        "total_tokens":35412471,"request_count":3166,"success_count":3057}}
            """#
            let redirectedURL = URL(string: "https://crossmodel.test:444/v1/usage")!
            let (response, data) = Self.makeResponse(url: redirectedURL, body: body)
            return (data, response)
        }

        let usage = try await CrossModelUsageFetcher.fetchUsage(
            apiKey: "cm-test",
            environment: ["CROSSMODEL_API_URL": "https://crossmodel.test/v1"],
            transport: transport)

        #expect(usage.balance == 1.5)
        #expect(usage.daily == nil)
    }

    @Test
    func `fetch usage hard deadlines never returning optional usage`() async throws {
        let transport = ProviderHTTPTransportHandler { request in
            guard let url = request.url else { throw URLError(.badURL) }
            if url.path == "/v1/credits" {
                let body = #"{"currency":"USD","balance_micro":1500000,"uncollected_micro":0}"#
                let (response, data) = Self.makeResponse(url: url, body: body)
                return (data, response)
            }
            try await Task.sleep(for: .seconds(60))
            throw CancellationError()
        }

        let start = ContinuousClock.now
        let usage = try await CrossModelUsageFetcher.fetchUsage(
            apiKey: "cm-test",
            environment: ["CROSSMODEL_API_URL": "https://crossmodel.test/v1"],
            transport: transport,
            usageJoinGrace: .milliseconds(50))
        let elapsed = start.duration(to: .now)

        #expect(usage.balance == 1.5)
        #expect(usage.daily == nil)
        #expect(elapsed < .seconds(2))
    }

    @Test
    func `fetch usage cancels bounded optional usage join with parent task`() async throws {
        let transport = ProviderHTTPTransportHandler { request in
            guard let url = request.url else { throw URLError(.badURL) }
            if url.path == "/v1/credits" {
                let body = #"{"currency":"USD","balance_micro":1500000,"uncollected_micro":0}"#
                let (response, data) = Self.makeResponse(url: url, body: body)
                return (data, response)
            }
            try await Task.sleep(for: .seconds(60))
            let body = #"""
            {"currency":"USD",
             "daily":{"cost_micro":5746,"prompt_tokens":9176,"completion_tokens":3291,
                      "total_tokens":12467,"request_count":9,"success_count":9},
             "weekly":{"cost_micro":665033,"prompt_tokens":1368222,"completion_tokens":557568,
                       "total_tokens":1925790,"request_count":529,"success_count":529},
             "monthly":{"cost_micro":5368746,"prompt_tokens":33488242,"completion_tokens":1924229,
                        "total_tokens":35412471,"request_count":3166,"success_count":3057}}
            """#
            let (response, data) = Self.makeResponse(url: url, body: body)
            return (data, response)
        }

        let task = Task {
            try await CrossModelUsageFetcher.fetchUsage(
                apiKey: "cm-test",
                environment: ["CROSSMODEL_API_URL": "https://crossmodel.test/v1"],
                transport: transport,
                usageJoinGrace: .seconds(30))
        }

        try await Task.sleep(for: .milliseconds(50))
        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }

    @Test
    func `sanitizer redacts cm token shapes`() {
        let body = #"{"error":"bad token cm-abc123","authorization":"Bearer cm-xyz789"}"#
        let summary = CrossModelUsageFetcher._sanitizedResponseBodySummaryForTesting(body)
        #expect(summary.contains("cm-[REDACTED]"))
        #expect(!summary.contains("cm-abc123"))
        #expect(!summary.contains("cm-xyz789"))
    }

    @Test
    func `usage snapshot round trip persists cross model usage metadata`() throws {
        let crossModel = CrossModelUsageSnapshot(
            currency: "USD",
            balance: 8.06,
            uncollected: 0,
            daily: nil,
            weekly: nil,
            monthly: CrossModelUsageWindow(
                cost: 5.368746,
                promptTokens: 33_488_242,
                completionTokens: 1_924_229,
                totalTokens: 35_412_471,
                requestCount: 3166,
                successCount: 3057),
            updatedAt: Date(timeIntervalSince1970: 1_739_841_600))
        let snapshot = crossModel.toUsageSnapshot()

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(UsageSnapshot.self, from: data)

        #expect(decoded.crossModelUsage?.balance == 8.06)
        #expect(decoded.crossModelUsage?.monthly?.cost == 5.368746)
        #expect(decoded.crossModelUsage?.monthly?.requestCount == 3166)
        #expect(decoded.identity?.loginMethod == "API key")
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

private final class CrossModelRequestPathRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []

    func append(_ path: String) {
        self.lock.withLock {
            self.paths.append(path)
        }
    }

    func snapshot() -> [String] {
        self.lock.withLock {
            self.paths
        }
    }
}

final class CrossModelStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "crossmodel.test"
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
