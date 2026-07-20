import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct AiAndProviderTests {
    @Test
    func `single log page maps to summed spend in the org billing currency`() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            #expect(url.absoluteString == "https://api.aiand.com/logs?range=30days&limit=100")
            #expect(url.scheme == "https")
            #expect(url.host == "api.aiand.com")
            #expect(url.user == nil)
            #expect(url.password == nil)
            #expect(url.fragment == nil)
            return Self.response(url: url, body: Self.finalPageFixture)
        }

        let usage = try await AiAndUsageFetcher.fetchUsage(
            "fixture-key",
            transport: transport,
            now: now)
        let snapshot = usage.toUsageSnapshot()

        // "7.02344000" + "1.10000000"; the null-cost row is skipped.
        #expect(usage.last30DaysSpend?.amount == Decimal(string: "8.12344"))
        #expect(usage.last30DaysSpend?.currencyCode == "JPY")
        #expect(usage.isComplete)
        #expect(snapshot.primary == nil)
        #expect(snapshot.secondary == nil)
        #expect(snapshot.tertiary == nil)
        #expect(snapshot.extraRateWindows == nil)
        #expect(snapshot.providerCost?.limit == 0)
        #expect(snapshot.providerCost?.currencyCode == "JPY")
        #expect(snapshot.providerCost?.period == "Last 30 days")
        #expect(snapshot.identity == nil)
        #expect(snapshot.dataConfidence == .exact)
        #expect(snapshot.updatedAt == now)
    }

    @Test
    func `pagination sends both cursors and sums across pages`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            let query = url.query ?? ""
            if query.contains("after=") {
                #expect(url.absoluteString ==
                    "https://api.aiand.com/logs?range=30days&limit=100" +
                    "&after=2026-07-17%2010:24:30.094374%2B00&after_id=912bf992-0000-4000-8000-000000000002")
                return Self.response(url: url, body: Self.finalPageFixture)
            }
            return Self.response(url: url, body: Self.firstPageFixture)
        }

        let usage = try await AiAndUsageFetcher.fetchUsage("fixture-key", transport: transport)

        let requests = await transport.requests()
        #expect(requests.count == 2)
        let secondQuery = try #require(requests.last?.url?.query)
        #expect(secondQuery.contains("after="))
        #expect(secondQuery.contains("after_id=912bf992-0000-4000-8000-000000000002"))
        // Page 1: "12.00000000" + "0.50000000"; page 2: "7.02344000" + "1.10000000".
        #expect(usage.last30DaysSpend?.amount == Decimal(string: "20.62344"))
        #expect(usage.last30DaysSpend?.currencyCode == "JPY")
        #expect(usage.isComplete)
    }

    @Test
    func `hitting the page cap marks the spend partial`() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            return Self.response(url: url, body: Self.firstPageFixture)
        }

        let usage = try await AiAndUsageFetcher.fetchUsage(
            "fixture-key",
            transport: transport,
            now: now)
        let snapshot = usage.toUsageSnapshot()

        let requests = await transport.requests()
        #expect(requests.count == AiAndUsageFetcher.maxPages)
        #expect(!usage.isComplete)
        #expect(usage.last30DaysSpend?.amount == Decimal(string: "125.0"))
        #expect(snapshot.providerCost?.period == "Last 30 days (partial)")
        #expect(snapshot.dataConfidence == .estimated)
    }

    @Test
    func `missing pagination cursor marks the spend partial`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            return Self.response(url: url, body: #"""
            {
              "data": [{"cost": "2.50000000", "currency": "jpy"}],
              "has_more": true,
              "next_after": null,
              "next_after_id": null
            }
            """#)
        }

        let usage = try await AiAndUsageFetcher.fetchUsage("fixture-key", transport: transport)
        let snapshot = usage.toUsageSnapshot()

        #expect(await transport.requests().count == 1)
        #expect(!usage.isComplete)
        #expect(snapshot.providerCost?.period == "Last 30 days (partial)")
        #expect(snapshot.dataConfidence == .estimated)
    }

    @Test
    func `mixed currencies keep the newest row's currency and skip the rest`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            return Self.response(url: url, body: Self.mixedCurrencyFixture)
        }

        let usage = try await AiAndUsageFetcher.fetchUsage("fixture-key", transport: transport)

        // The newest row is JPY, so the USD row is not added to the total.
        #expect(usage.last30DaysSpend?.currencyCode == "JPY")
        #expect(usage.last30DaysSpend?.amount == Decimal(string: "9.5"))
    }

    @Test
    func `empty window omits the cost snapshot instead of guessing a currency`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            return Self.response(url: url, body: #"{"data": [], "has_more": false}"#)
        }

        let usage = try await AiAndUsageFetcher.fetchUsage("fixture-key", transport: transport)
        let snapshot = usage.toUsageSnapshot()

        // The billing currency is only observable from log rows; with none, report
        // no cost at all rather than a zero in a guessed currency.
        #expect(usage.last30DaysSpend == nil)
        #expect(usage.isComplete)
        #expect(snapshot.providerCost == nil)
    }

    @Test
    func `rows without a currency are skipped and alone yield no cost snapshot`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            return Self.response(url: url, body: Self.missingCurrencyFixture)
        }

        let usage = try await AiAndUsageFetcher.fetchUsage("fixture-key", transport: transport)

        #expect(usage.last30DaysSpend == nil)
        #expect(usage.toUsageSnapshot().providerCost == nil)
    }

    @Test
    func `decimal money strings sum exactly`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            return Self.response(url: url, body: Self.decimalFixture)
        }

        let usage = try await AiAndUsageFetcher.fetchUsage("fixture-key", transport: transport)

        // 0.1 + 0.1 + 0.1 must be exactly 0.3 — Double summation would drift.
        #expect(usage.last30DaysSpend?.amount == Decimal(string: "0.3"))
    }

    @Test
    func `credential is only sent as a bearer header`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            return Self.response(url: url, body: Self.finalPageFixture)
        }

        _ = try await AiAndUsageFetcher.fetchUsage("fixture-key", transport: transport)

        let request = try #require(await transport.requests().first)
        let url = try #require(request.url)
        #expect(!url.absoluteString.contains("fixture-key"))
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
    }

    @Test
    func `invalid api key maps to an actionable error`() async {
        let transport = Self.errorTransport(statusCode: 401, code: "invalid_api_key")

        await #expect {
            _ = try await AiAndUsageFetcher.fetchUsage("wrong-key", transport: transport)
        } throws: { error in
            error as? AiAndUsageError == .authenticationRejected
        }
        #expect(AiAndUsageError.authenticationRejected.errorDescription?.contains("console.aiand.com") == true)
    }

    @Test
    func `insufficient credits maps to an actionable error`() async {
        let transport = Self.errorTransport(statusCode: 402, code: "insufficient_credits")

        await #expect {
            _ = try await AiAndUsageFetcher.fetchUsage("fixture-key", transport: transport)
        } throws: { error in
            error as? AiAndUsageError == .insufficientCredits
        }
        #expect(AiAndUsageError.insufficientCredits.errorDescription?.contains("credits") == true)
    }

    @Test
    func `rate limit is surfaced politely`() async {
        let transport = Self.errorTransport(statusCode: 429, code: "rate_limit_exceeded")

        await #expect {
            _ = try await AiAndUsageFetcher.fetchUsage("fixture-key", transport: transport)
        } throws: { error in
            error as? AiAndUsageError == .rateLimited
        }
    }

    @Test
    func `unexpected status is reported with its code`() async {
        let transport = Self.errorTransport(statusCode: 500, code: "internal_error")

        await #expect {
            _ = try await AiAndUsageFetcher.fetchUsage("fixture-key", transport: transport)
        } throws: { error in
            error as? AiAndUsageError == .apiError(500)
        }
    }

    @Test
    func `missing or whitespace credential fails clearly`() async {
        await #expect {
            _ = try await AiAndUsageFetcher.fetchUsage("   ")
        } throws: { error in
            error as? AiAndUsageError == .notConfigured
        }
    }

    @Test
    func `malformed logs payload fails parsing`() async {
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            return Self.response(url: url, body: #"{"object":"list"}"#)
        }

        await #expect {
            _ = try await AiAndUsageFetcher.fetchUsage("fixture-key", transport: transport)
        } throws: { error in
            guard case .parseFailed = error as? AiAndUsageError else { return false }
            return true
        }
    }

    @Test
    func `settings reader trims whitespace and quotes`() {
        #expect(AiAndSettingsReader.apiKey(environment: [
            AiAndSettingsReader.apiKeyEnvironmentKey: "  'fixture-key'  ",
        ]) == "fixture-key")
        #expect(AiAndSettingsReader.apiKey(environment: [:]) == nil)
        #expect(AiAndSettingsReader.apiKey(environment: [
            AiAndSettingsReader.apiKeyEnvironmentKey: "   ",
        ]) == nil)
    }

    @Test
    func `config API key projects into the fetch environment`() {
        let env = ProviderConfigEnvironment.applyAPIKeyOverride(
            base: [AiAndSettingsReader.apiKeyEnvironmentKey: "environment-key"],
            provider: .aiand,
            config: ProviderConfig(id: .aiand, apiKey: "test"))

        #expect(AiAndSettingsReader.apiKey(environment: env) == "test")
        #expect(ProviderConfigEnvironment.supportsAPIKeyOverride(for: .aiand))
    }

    @Test @MainActor
    func `descriptor and app registry include aiand`() throws {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .aiand)
        #expect(descriptor.metadata.displayName == "ai&")
        #expect(descriptor.metadata.cliName == "aiand")
        #expect(descriptor.metadata.defaultEnabled == false)
        #expect(!descriptor.metadata.supportsCredits)
        #expect(!descriptor.tokenCost.supportsTokenCost)
        #expect(descriptor.fetchPlan.sourceModes == [.auto, .api])
        #expect(descriptor.cli.aliases == ["ai&", "ai-and"])

        let implementation = try #require(ProviderImplementationRegistry.implementation(for: .aiand))
        #expect(implementation is AiAndProviderImplementation)
    }

    @Test @MainActor
    func `menu card renders spend through the generic API-spend path`() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            return Self.response(url: url, body: Self.finalPageFixture)
        }
        let usage = try await AiAndUsageFetcher.fetchUsage(
            "fixture-key",
            transport: transport,
            now: now)
        let model = UsageMenuCardView.Model.make(.init(
            provider: .aiand,
            metadata: AiAndProviderDescriptor.descriptor.metadata,
            snapshot: usage.toUsageSnapshot(),
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: true,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        #expect(model.metrics.isEmpty)
        #expect(model.creditsText == nil)
        #expect(model.providerCost?.title == "API spend")
        #expect(model.providerCost?.spendLine == "Last 30 days: ¥8")
        #expect(model.providerCost?.percentUsed == nil)
        #expect(model.providerCost?.percentLine == nil)
    }

    /// Sanitized from a live `/logs` response (2026-07-17); `api_key` arrives pre-masked by the server.
    private static let finalPageFixture = #"""
    {
      "data": [
        {
          "id": "cdd2b25d-0000-4000-8000-000000000001",
          "model": "zai-org/glm-5.2",
          "api_key": "masked",
          "status_code": 200,
          "ttft_ms": 1449,
          "latency_ms": 3163,
          "input_tokens": 170569,
          "output_tokens": 248,
          "cached_tokens": 170240,
          "cost": "7.02344000",
          "currency": "jpy",
          "created_at": "2026-07-17 10:24:30.094374+00"
        },
        {
          "id": "cdd2b25d-0000-4000-8000-000000000002",
          "model": "zai-org/glm-5.2",
          "api_key": "masked",
          "status_code": 200,
          "ttft_ms": 512,
          "latency_ms": 1201,
          "input_tokens": 1200,
          "output_tokens": 90,
          "cached_tokens": 0,
          "cost": "1.10000000",
          "currency": "jpy",
          "created_at": "2026-07-17 10:20:00.000000+00"
        },
        {
          "id": "cdd2b25d-0000-4000-8000-000000000003",
          "model": "zai-org/glm-5.2",
          "api_key": "masked",
          "status_code": 500,
          "ttft_ms": 0,
          "latency_ms": 42,
          "input_tokens": 0,
          "output_tokens": 0,
          "cached_tokens": null,
          "cost": null,
          "currency": "jpy",
          "created_at": "2026-07-17 10:15:00.000000+00"
        }
      ],
      "has_more": false,
      "next_after": null,
      "next_after_id": null
    }
    """#

    private static let firstPageFixture = #"""
    {
      "data": [
        {
          "id": "912bf992-0000-4000-8000-000000000001",
          "model": "zai-org/glm-5.2",
          "api_key": "masked",
          "status_code": 200,
          "ttft_ms": 800,
          "latency_ms": 2400,
          "input_tokens": 52000,
          "output_tokens": 700,
          "cached_tokens": 0,
          "cost": "12.00000000",
          "currency": "jpy",
          "created_at": "2026-07-17 10:24:30.094374+00"
        },
        {
          "id": "912bf992-0000-4000-8000-000000000002",
          "model": "zai-org/glm-5.2",
          "api_key": "masked",
          "status_code": 200,
          "ttft_ms": 300,
          "latency_ms": 900,
          "input_tokens": 2100,
          "output_tokens": 55,
          "cached_tokens": 0,
          "cost": "0.50000000",
          "currency": "jpy",
          "created_at": "2026-07-17 10:24:30.094374+00"
        }
      ],
      "has_more": true,
      "next_after": "2026-07-17 10:24:30.094374+00",
      "next_after_id": "912bf992-0000-4000-8000-000000000002"
    }
    """#

    private static let mixedCurrencyFixture = #"""
    {
      "data": [
        {
          "id": "aaaa0000-0000-4000-8000-000000000001",
          "cost": "9.50000000",
          "currency": "jpy",
          "created_at": "2026-07-17 10:24:30.094374+00"
        },
        {
          "id": "aaaa0000-0000-4000-8000-000000000002",
          "cost": "1.25000000",
          "currency": "usd",
          "created_at": "2026-07-17 10:20:00.000000+00"
        }
      ],
      "has_more": false,
      "next_after": null,
      "next_after_id": null
    }
    """#

    private static let missingCurrencyFixture = #"""
    {
      "data": [
        {
          "id": "aaaa0000-0000-4000-8000-000000000003",
          "cost": "4.20000000",
          "currency": null,
          "created_at": "2026-07-17 10:24:30.094374+00"
        },
        {
          "id": "aaaa0000-0000-4000-8000-000000000004",
          "cost": "1.00000000",
          "currency": "  ",
          "created_at": "2026-07-17 10:20:00.000000+00"
        }
      ],
      "has_more": false,
      "next_after": null,
      "next_after_id": null
    }
    """#

    private static let decimalFixture = #"""
    {
      "data": [
        {"id": "bbbb0000-0000-4000-8000-000000000001", "cost": "0.10000000", "currency": "jpy"},
        {"id": "bbbb0000-0000-4000-8000-000000000002", "cost": "0.10000000", "currency": "jpy"},
        {"id": "bbbb0000-0000-4000-8000-000000000003", "cost": "0.10000000", "currency": "jpy"}
      ],
      "has_more": false,
      "next_after": null,
      "next_after_id": null
    }
    """#

    private static func errorTransport(statusCode: Int, code: String) -> ProviderHTTPTransportStub {
        ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            let body = #"""
            {"error":{"message":"fixture error","type":"fixture","param":null,"code":"\#(code)"}}
            """#
            return Self.response(url: url, body: body, statusCode: statusCode)
        }
    }

    private static func response(
        url: URL,
        body: String,
        statusCode: Int = 200) -> (Data, URLResponse)
    {
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        return (Data(body.utf8), response)
    }
}
