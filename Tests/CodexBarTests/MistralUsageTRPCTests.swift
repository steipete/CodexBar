import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

private final class MistralTRPCPathLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storedPaths: [String] = []

    var paths: [String] {
        self.lock.withLock { self.storedPaths }
    }

    func record(_ path: String) {
        self.lock.withLock { self.storedPaths.append(path) }
    }
}

@Suite
struct MistralUsageTRPCTests {
    // MARK: - Fixtures (shapes captured from admin.mistral.ai on 2026-09-25, identifiers removed)

    private static let usersMe = #"{"email":"dev@example.com","workspace":{"uuid":"ws-1","is_default":true}}"#

    private static let prices = """
    {"currency":"EUR","prices":[
      {"apiZone":"global","billingGroup":"input","billingMetric":"mistral-medium-3-5","eventType":"api_tokens",
       "price":1.275e-06,"serviceTier":"standard"},
      {"apiZone":"global","billingGroup":"input","billingMetric":"mistral-medium-3-5","eventType":"api_audio_seconds",
       "price":0.00014166666666666668,"serviceTier":"standard"},
      {"apiZone":"eu","billingGroup":"input","billingMetric":"mistral-medium-3-5","eventType":"api_tokens",
       "price":1.4025e-06,"serviceTier":"standard"},
      {"apiZone":"global","billingGroup":"cached","billingMetric":"mistral-medium-3-5","eventType":"api_tokens",
       "price":1.275e-07,"serviceTier":"standard"},
      {"apiZone":"global","billingGroup":"output","billingMetric":"mistral-medium-3-5","eventType":"api_tokens",
       "price":6.375e-06,"serviceTier":"standard"},
      {"apiZone":"global","billingGroup":"input","billingMetric":"mistral-ocr-2505","eventType":"api_pages",
       "price":0.001,"serviceTier":"standard"}
    ]}
    """

    /// One September day of Vibe Code completions (the same day the legacy fixture reports), plus an OCR page row.
    private static let costTimeseries = """
    {"groups":[
      {"apiZone":"global","serviceTier":"standard","billingGroup":"cached","billingMetric":"mistral-medium-3-5",
       "count":117,"timeBucket":"2026-09-01T00:00:00.000Z","usageType":"vibe","value":6777856},
      {"apiZone":"global","serviceTier":"standard","billingGroup":"input","billingMetric":"mistral-medium-3-5",
       "count":117,"timeBucket":"2026-09-01T00:00:00.000Z","usageType":"vibe","value":245458},
      {"apiZone":"global","serviceTier":"standard","billingGroup":"output","billingMetric":"mistral-medium-3-5",
       "count":117,"timeBucket":"2026-09-01T00:00:00.000Z","usageType":"vibe","value":29994},
      {"apiZone":"global","serviceTier":"standard","billingGroup":"input","billingMetric":"mistral-ocr-2505",
       "count":3,"timeBucket":"2026-09-02T00:00:00.000Z","usageType":"usage","value":40},
      {"apiZone":"global","serviceTier":"standard","billingGroup":"input","billingMetric":"mistral-medium-3-5",
       "count":2,"timeBucket":"2026-09-02T00:00:00.000Z","usageType":"usage","value":1000},
      {"apiZone":"global","serviceTier":"standard","billingGroup":"output","billingMetric":"mistral-new-2610",
       "count":1,"timeBucket":"2026-09-02T00:00:00.000Z","usageType":"usage","value":500}
    ],"metadata":{"hasMore":false,"queryParams":{"groupBy":["billing_metric","billing_group","usage_type"]}}}
    """

    private static let breakdownByModel = """
    {"groups":[
      {"billingDisplayName":"mistral-vibe-cli-latest","billingGroup":"input","billingMetric":"mistral-medium-3-5",
       "count":117,"timeBucket":"2026-09-01T00:00:00.000Z","usageType":"vibe","value":245458},
      {"billingDisplayName":"mistral-medium-latest","billingGroup":"input","billingMetric":"mistral-medium-3-5",
       "count":2,"timeBucket":"2026-09-01T00:00:00.000Z","usageType":"usage","value":1000}
    ],"metadata":{"hasMore":false}}
    """

    private static func envelope(_ json: String) -> String {
        #"[{"result":{"data":{"json":\#(json)}}}]"#
    }

    private static let tRPCError =
        #"[{"error":{"json":{"message":"No procedure found on path \"usage.costTimeseries\"","code":-32004}}}]"#

    private static func response(url: URL, statusCode: Int) throws -> HTTPURLResponse {
        try #require(HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil))
    }

    // MARK: - Price index

    @Test
    func `price index keeps the token price when a metric is also priced per audio second`() throws {
        let response = try JSONDecoder().decode(
            MistralUsageTRPCFetcher.PricesResponse.self,
            from: Data(Self.prices.utf8))
        let index = MistralUsageTRPCFetcher.priceIndex(from: response)

        let input = MistralPriceIndex.Lookup(
            billingMetric: "mistral-medium-3-5",
            billingGroup: "input",
            apiZone: "global",
            serviceTier: "standard")
        #expect(index.resolvedEventType(for: input) == "api_tokens")
        #expect(index.price(for: input) == 1.275e-06)

        var euInput = input
        euInput.apiZone = "eu"
        #expect(index.price(for: euInput) == 1.4025e-06)

        var explicitSeconds = input
        explicitSeconds.eventType = "api_audio_seconds"
        #expect(index.price(for: explicitSeconds) == 0.00014166666666666668)

        let pages = MistralPriceIndex.Lookup(billingMetric: "mistral-ocr-2505", billingGroup: "input")
        #expect(index.resolvedEventType(for: pages) == "api_pages")
        #expect(index.price(for: pages) == 0.001)

        #expect(index.price(for: MistralPriceIndex.Lookup(billingMetric: "unknown", billingGroup: "input")) == nil)
    }

    @Test
    func `legacy price table prefers the explicit event type of a usage entry`() throws {
        let json = """
        {
          "completion": {"models": {"mistral-medium-latest::mistral-medium-3-5": {
            "input": [{"event_type": "api_tokens", "billing_metric": "mistral-medium-3-5",
                       "billing_group": "input", "timestamp": "2026-09-01", "value": 1000000, "value_paid": 1000000}]
          }}},
          "currency": "EUR",
          "prices": [
            {"event_type": "api_tokens", "billing_metric": "mistral-medium-3-5", "billing_group": "input",
             "api_zone": "global", "service_tier": "standard", "price": "0.0000012750"},
            {"event_type": "api_audio_seconds", "billing_metric": "mistral-medium-3-5", "billing_group": "input",
             "api_zone": "global", "service_tier": "standard", "price": "0.0001416667"}
          ]
        }
        """
        let snapshot = try MistralUsageFetcher.parseResponse(data: Data(json.utf8), updatedAt: Date())

        // 1M input tokens at the token price, not at the audio-seconds price that shares the metric and group.
        #expect(abs(snapshot.totalCost - 1.275) < 0.0001)
        #expect(snapshot.totalInputTokens == 1_000_000)
    }

    // MARK: - tRPC parsing

    @Test
    func `tRPC rows build the same daily buckets as the legacy endpoint`() throws {
        let usage = try JSONDecoder().decode(
            MistralUsageTRPCFetcher.UsageResponse.self,
            from: Data(Self.costTimeseries.utf8))
        let prices = try JSONDecoder().decode(
            MistralUsageTRPCFetcher.PricesResponse.self,
            from: Data(Self.prices.utf8))
        let names = try JSONDecoder().decode(
            MistralUsageTRPCFetcher.UsageResponse.self,
            from: Data(Self.breakdownByModel.utf8))
        let range = MistralUsageTRPCFetcher.monthRange(containing: Date(timeIntervalSince1970: 1_790_000_000))

        let snapshot = try MistralUsageTRPCFetcher.makeSnapshot(
            usage: usage,
            prices: prices,
            displayNames: MistralUsageTRPCFetcher.displayNames(from: names),
            range: range,
            updatedAt: Date(timeIntervalSince1970: 1_790_000_000))

        #expect(snapshot.currency == "EUR")
        #expect(snapshot.currencySymbol == "€")
        // Vibe lanes, plus 1000 API input tokens on the same metric and 500 output tokens of an unpriced model.
        #expect(snapshot.totalInputTokens == 245_458 + 1000)
        #expect(snapshot.totalCachedTokens == 6_777_856)
        #expect(snapshot.totalOutputTokens == 29994 + 500)
        // Same billing metric under Vibe and API usage counts as two models; the unpriced model is a third.
        #expect(snapshot.modelCount == 3)
        #expect(snapshot.daily.map(\.day) == ["2026-09-01", "2026-09-02"])

        let vibeDay = try #require(snapshot.daily.first)
        let expectedVibeCost = 245_458 * 1.275e-06 + 6_777_856 * 1.275e-07 + 29994 * 6.375e-06
        #expect(abs(vibeDay.cost - expectedVibeCost) < 0.0001)
        #expect(vibeDay.totalTokens == 245_458 + 6_777_856 + 29994)
        #expect(vibeDay.models.map(\.name) == ["mistral-vibe-cli-latest"])

        let secondDay = try #require(snapshot.daily.last)
        let expectedSecondDayCost = 0.04 + 1000 * 1.275e-06
        #expect(abs(secondDay.cost - expectedSecondDayCost) < 0.0001)
        #expect(secondDay.totalTokens == 1500)
        #expect(secondDay.models.map(\.name) == ["mistral-medium-latest", "mistral-new-2610", "mistral-ocr-2505"])
        #expect(secondDay.models.first { $0.name == "mistral-new-2610" }?.cost == 0)
        #expect(secondDay.models.first { $0.name == "mistral-new-2610" }?.outputTokens == 500)
        #expect(abs(snapshot.totalCost - (expectedVibeCost + expectedSecondDayCost)) < 0.0001)
        #expect(snapshot.startDate == ISO8601DateFormatter().date(from: "2026-09-01T00:00:00Z"))
    }

    @Test
    func `tRPC input encodes dates with superjson metadata`() throws {
        let start = try #require(ISO8601DateFormatter().date(from: "2026-09-01T00:00:00Z"))
        let url = try MistralUsageTRPCFetcher.url(
            procedure: "usage.costTimeseries",
            input: ["start": .date(start), "granularity": .string("day")])
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))

        #expect(url.host == "admin.mistral.ai")
        #expect(url.path == "/api/local-trpc/usage.costTimeseries")
        #expect(components.queryItems?.first { $0.name == "batch" }?.value == "1")
        let input = try #require(components.queryItems?.first { $0.name == "input" }?.value)
        let decoded = try #require(JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any])
        let call = try #require(decoded["0"] as? [String: Any])
        let json = try #require(call["json"] as? [String: Any])
        #expect(json["start"] as? String == "2026-09-01T00:00:00.000Z")
        #expect(json["granularity"] as? String == "day")
        let meta = try #require(call["meta"] as? [String: Any])
        #expect((meta["values"] as? [String: [String]])?["start"] == ["Date"])
    }

    @Test
    func `tRPC error envelopes surface as API errors`() {
        #expect(throws: MistralUsageError.self) {
            try MistralUsageTRPCFetcher.decode(
                MistralUsageTRPCFetcher.UsageResponse.self,
                statusCode: 404,
                data: Data(Self.tRPCError.utf8))
        }
    }

    @Test(arguments: [401, 403])
    func `session failures wrapped in a tRPC error envelope are invalid credentials`(statusCode: Int) {
        let body = #"[{"error":{"json":{"message":"UNAUTHORIZED","code":-32001}}}]"#
        let error = #expect(throws: MistralUsageError.self) {
            try MistralUsageTRPCFetcher.decode(
                MistralUsageTRPCFetcher.UsageResponse.self,
                statusCode: statusCode,
                data: Data(body.utf8))
        }
        guard case .invalidCredentials = error else {
            Issue.record("Expected invalidCredentials, got \(String(describing: error))")
            return
        }
    }

    // MARK: - Cost basis

    @Test
    func `procedure usage is labelled consumption and never API spend`() throws {
        let usage = try JSONDecoder().decode(
            MistralUsageTRPCFetcher.UsageResponse.self,
            from: Data(Self.costTimeseries.utf8))
        let prices = try JSONDecoder().decode(
            MistralUsageTRPCFetcher.PricesResponse.self,
            from: Data(Self.prices.utf8))
        let snapshot = try MistralUsageTRPCFetcher.makeSnapshot(
            usage: usage,
            prices: prices,
            displayNames: [:],
            range: MistralUsageTRPCFetcher.monthRange(containing: Date(timeIntervalSince1970: 1_790_000_000)),
            updatedAt: Date(timeIntervalSince1970: 1_790_000_000))

        #expect(snapshot.costBasis == .consumption)
        let description = snapshot.toUsageSnapshot().identity?.loginMethod
        #expect(description?.hasPrefix("Consumption: €") == true)
        #expect(description?.contains("API spend") == false)

        let legacy = MistralUsageSnapshot(
            totalCost: 1.5,
            currency: "EUR",
            currencySymbol: "€",
            totalInputTokens: 1,
            totalOutputTokens: 1,
            totalCachedTokens: 0,
            modelCount: 1,
            startDate: nil,
            endDate: nil,
            updatedAt: Date())
        #expect(legacy.costBasis == .billed)
        #expect(legacy.toUsageSnapshot().identity?.loginMethod == "API spend: €1.5000 this month")
    }

    @Test
    func `snapshots serialized before the cost basis existed decode as billed`() throws {
        let legacy = """
        {"totalCost":1.5,"currency":"EUR","currencySymbol":"€","totalInputTokens":10,"totalOutputTokens":5,
         "totalCachedTokens":0,"modelCount":1,"daily":[],"credits":{"walletAmount":2,"creditNotesAmount":0,
         "ongoingUsageBalance":0,"currency":"EUR"},"startDate":null,"endDate":null,"updatedAt":700000000}
        """
        let snapshot = try JSONDecoder().decode(MistralUsageSnapshot.self, from: Data(legacy.utf8))
        #expect(snapshot.costBasis == .billed)
        #expect(snapshot.credits?.walletAmount == 2)

        let consumption = MistralUsageSnapshot(
            totalCost: 3,
            costBasis: .consumption,
            currency: "EUR",
            currencySymbol: "€",
            totalInputTokens: 0,
            totalOutputTokens: 0,
            totalCachedTokens: 0,
            modelCount: 0,
            startDate: nil,
            endDate: nil,
            updatedAt: Date(timeIntervalSince1970: 700_000_000))
        let roundTrip = try JSONDecoder().decode(
            MistralUsageSnapshot.self,
            from: JSONEncoder().encode(consumption))
        #expect(roundTrip.costBasis == .consumption)
        #expect(roundTrip.with(credits: nil).costBasis == .consumption)
    }

    @Test
    func `legacy entries without a timestamp stay in the monthly totals`() throws {
        let json = """
        {
          "completion": {"models": {"mistral-small-latest::mistral-small-2506": {
            "input": [
              {"billing_metric": "mistral-small-2506", "billing_group": "input", "timestamp": "2026-09-03",
               "value": 20, "value_paid": 20},
              {"billing_metric": "mistral-small-2506", "billing_group": "input",
               "value": 5, "value_paid": 5}
            ]
          }}},
          "currency": "EUR",
          "prices": [{"event_type": "api_tokens", "billing_metric": "mistral-small-2506", "billing_group": "input",
                      "price": "0.1"}]
        }
        """
        let snapshot = try MistralUsageFetcher.parseResponse(data: Data(json.utf8), updatedAt: Date())

        #expect(snapshot.totalInputTokens == 25)
        #expect(abs(snapshot.totalCost - 2.5) < 0.0001)
        #expect(snapshot.daily.map(\.day) == ["2026-09-03"])
        #expect(snapshot.daily.first?.inputTokens == 20)
    }

    // MARK: - Source selection

    @Test
    func `usage keeps the legacy endpoint first and never calls the procedures when it answers`() async throws {
        let legacy = """
        {"completion":{"models":{"mistral-small-latest::mistral-small-2506":{"input":[
           {"billing_metric":"mistral-small-2506","billing_group":"input","timestamp":"2026-09-03",
            "value":20,"value_paid":20}]}}},
         "currency":"EUR","currency_symbol":"€",
         "prices":[{"event_type":"api_tokens","billing_metric":"mistral-small-2506","billing_group":"input",
                    "price":"8.50E-8"}]}
        """
        let log = MistralTRPCPathLog()
        let transport = ProviderHTTPTransportHandler { request in
            let url = try #require(request.url)
            log.record(url.path)
            guard url.path == "/api/billing/v2/usage" else { throw URLError(.unsupportedURL) }
            return try (Data(legacy.utf8), Self.response(url: url, statusCode: 200))
        }

        let snapshot = try await MistralUsageFetcher.fetchUsage(
            cookieHeader: "ory_session_test=abc",
            csrfToken: nil,
            timeout: 2,
            transport: transport)

        #expect(snapshot.totalInputTokens == 20)
        #expect(log.paths == ["/api/billing/v2/usage"])
    }

    @Test
    func `usage falls back to the procedures when the legacy endpoint fails`() async throws {
        let log = MistralTRPCPathLog()
        let transport = ProviderHTTPTransportHandler { request in
            let url = try #require(request.url)
            log.record(url.path)
            let body: String
            switch url.path {
            case "/api/billing/v2/usage":
                return try (Data("<html>Server Error (500)</html>".utf8), Self.response(url: url, statusCode: 500))
            case "/api/users/me": body = Self.usersMe
            case "/api/local-trpc/usage.prices": body = Self.envelope(Self.prices)
            case "/api/local-trpc/usage.costTimeseries": body = Self.envelope(Self.costTimeseries)
            case "/api/local-trpc/usage.breakdownByModel": body = Self.envelope(Self.breakdownByModel)
            default: throw URLError(.unsupportedURL)
            }
            return try (Data(body.utf8), Self.response(url: url, statusCode: 200))
        }

        let snapshot = try await MistralUsageFetcher.fetchUsage(
            cookieHeader: "ory_session_test=abc; csrftoken=csrf",
            csrfToken: "csrf",
            timeout: 2,
            transport: transport)

        #expect(snapshot.totalInputTokens == 245_458 + 1000)
        #expect(snapshot.daily.first?.models.first?.name == "mistral-vibe-cli-latest")
        #expect(log.paths == [
            "/api/billing/v2/usage",
            "/api/users/me",
            "/api/local-trpc/usage.prices",
            "/api/local-trpc/usage.costTimeseries",
            "/api/local-trpc/usage.breakdownByModel",
        ])
    }

    @Test
    func `both sources failing surfaces the procedure error`() async throws {
        let log = MistralTRPCPathLog()
        let transport = ProviderHTTPTransportHandler { request in
            let url = try #require(request.url)
            log.record(url.path)
            switch url.path {
            case "/api/billing/v2/usage":
                return try (Data("<html>Server Error (500)</html>".utf8), Self.response(url: url, statusCode: 500))
            case "/api/users/me":
                return try (Data(Self.usersMe.utf8), Self.response(url: url, statusCode: 200))
            default:
                return try (Data(Self.tRPCError.utf8), Self.response(url: url, statusCode: 404))
            }
        }

        let error = await #expect(throws: MistralUsageError.self) {
            try await MistralUsageFetcher.fetchUsage(
                cookieHeader: "ory_session_test=abc",
                csrfToken: nil,
                timeout: 2,
                transport: transport)
        }
        guard case let .apiError(detail) = error else {
            Issue.record("Expected apiError, got \(String(describing: error))")
            return
        }
        #expect(detail.contains("usage.costTimeseries") || detail.contains("404"))
        #expect(log.paths == ["/api/billing/v2/usage", "/api/users/me", "/api/local-trpc/usage.prices"])
    }

    @Test
    func `paginated usage rows are refused rather than under counted`() async throws {
        let paginated = Self.costTimeseries.replacingOccurrences(of: #""hasMore":false"#, with: #""hasMore":true"#)
        let transport = ProviderHTTPTransportHandler { request in
            let url = try #require(request.url)
            switch url.path {
            case "/api/users/me": return try (Data(Self.usersMe.utf8), Self.response(url: url, statusCode: 200))
            case "/api/local-trpc/usage.prices":
                return try (Data(Self.envelope(Self.prices).utf8), Self.response(url: url, statusCode: 200))
            case "/api/local-trpc/usage.costTimeseries":
                return try (Data(Self.envelope(paginated).utf8), Self.response(url: url, statusCode: 200))
            default: return try (Data(), Self.response(url: url, statusCode: 500))
            }
        }

        let error = await #expect(throws: MistralUsageError.self) {
            try await MistralUsageTRPCFetcher.fetchUsage(
                session: MistralUsageTRPCFetcher.Session(cookieHeader: "ory_session_test=abc", csrfToken: nil),
                now: Date(timeIntervalSince1970: 1_790_000_000),
                timeout: 2,
                transport: transport)
        }
        guard case .parseFailed = error else {
            Issue.record("Expected parseFailed, got \(String(describing: error))")
            return
        }
    }

    @Test(arguments: [302, 401, 403])
    func `session failures on the legacy endpoint do not try the procedures`(statusCode: Int) async throws {
        let log = MistralTRPCPathLog()
        let transport = ProviderHTTPTransportHandler { request in
            let url = try #require(request.url)
            log.record(url.path)
            let response = try #require(HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: ["Location": "https://auth.mistral.ai/self-service/login/browser"]))
            return (Data("<html>302 Found</html>".utf8), response)
        }

        let error = await #expect(throws: MistralUsageError.self) {
            try await MistralUsageFetcher.fetchUsage(
                cookieHeader: "ory_session_stale=abc",
                csrfToken: nil,
                timeout: 2,
                transport: transport)
        }
        guard case .invalidCredentials = error else {
            Issue.record("Expected invalidCredentials, got \(String(describing: error))")
            return
        }
        #expect(log.paths == ["/api/billing/v2/usage"])
    }

    @Test(arguments: [302, 401, 403])
    func `session failures on the procedures count as invalid credentials`(statusCode: Int) async throws {
        let transport = ProviderHTTPTransportHandler { request in
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: ["Location": "https://auth.mistral.ai/self-service/login/browser"]))
            return (Data("<html>302 Found</html>".utf8), response)
        }

        let error = await #expect(throws: MistralUsageError.self) {
            try await MistralUsageTRPCFetcher.fetchUsage(
                session: MistralUsageTRPCFetcher.Session(cookieHeader: "ory_session_stale=abc", csrfToken: nil),
                now: Date(timeIntervalSince1970: 1_790_000_000),
                timeout: 2,
                transport: transport)
        }
        guard case .invalidCredentials = error else {
            Issue.record("Expected invalidCredentials, got \(String(describing: error))")
            return
        }
    }

    @Test
    func `legacy endpoint login redirect counts as invalid credentials`() async throws {
        let transport = ProviderHTTPTransportHandler { request in
            let url = try #require(request.url)
            return try (Data(), Self.response(url: url, statusCode: 302))
        }

        let error = await #expect(throws: MistralUsageError.self) {
            try await MistralUsageFetcher.fetchLegacyUsage(
                cookieHeader: "ory_session_stale=abc",
                csrfToken: nil,
                timeout: 2,
                transport: transport)
        }
        guard case .invalidCredentials = error else {
            Issue.record("Expected invalidCredentials, got \(String(describing: error))")
            return
        }
    }
}
