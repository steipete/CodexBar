import Foundation
import Testing
@testable import CodexBarCore

struct MistralUsageParserTests {
    // swiftlint:disable line_length

    private static let novemberResponseJSON = """
    {"completion":{"models":{"mistral-large-latest::mistral-large-2411":{"input":[{"usage_type":"usage","event_type":"api_tokens","billing_metric":"mistral-large-2411","billing_display_name":"mistral-large-latest","billing_group":"input","timestamp":"2025-11-14","value":11121,"value_paid":11121}],"output":[{"usage_type":"usage","event_type":"api_tokens","billing_metric":"mistral-large-2411","billing_display_name":"mistral-large-latest","billing_group":"output","timestamp":"2025-11-14","value":1115,"value_paid":1115}]},"mistral-small-latest::mistral-small-2506":{"input":[{"usage_type":"usage","event_type":"api_tokens","billing_metric":"mistral-small-2506","billing_display_name":"mistral-small-latest","billing_group":"input","timestamp":"2025-11-14","value":20,"value_paid":20},{"usage_type":"usage","event_type":"api_tokens","billing_metric":"mistral-small-2506","billing_display_name":"mistral-small-latest","billing_group":"input","timestamp":"2025-11-24","value":100,"value_paid":100}],"output":[{"usage_type":"usage","event_type":"api_tokens","billing_metric":"mistral-small-2506","billing_display_name":"mistral-small-latest","billing_group":"output","timestamp":"2025-11-14","value":500,"value_paid":500},{"usage_type":"usage","event_type":"api_tokens","billing_metric":"mistral-small-2506","billing_display_name":"mistral-small-latest","billing_group":"output","timestamp":"2025-11-24","value":2482,"value_paid":2482}]}}},"ocr":{"models":{}},"connectors":{"models":{}},"libraries_api":{"pages":{"models":{}},"tokens":{"models":{}}},"fine_tuning":{"training":{},"storage":{}},"audio":{"models":{}},"vibe_usage":0.0,"date":"2025-11-01T00:00:00Z","previous_month":"2025-10","next_month":"2025-12","start_date":"2025-11-01T00:00:00Z","end_date":"2025-11-30T23:59:59.999Z","currency":"EUR","currency_symbol":"\\u20ac","prices":[{"event_type":"api_tokens","billing_metric":"mistral-large-2411","billing_group":"input","price":"0.0000017000"},{"event_type":"api_tokens","billing_metric":"mistral-large-2411","billing_group":"output","price":"0.0000051000"},{"event_type":"api_tokens","billing_metric":"mistral-small-2506","billing_group":"input","price":"8.50E-8"},{"event_type":"api_tokens","billing_metric":"mistral-small-2506","billing_group":"output","price":"2.550E-7"}]}
    """

    private static let emptyResponseJSON = """
    {"completion":{"models":{}},"ocr":{"models":{}},"connectors":{"models":{}},"libraries_api":{"pages":{"models":{}},"tokens":{"models":{}}},"fine_tuning":{"training":{},"storage":{}},"audio":{"models":{}},"vibe_usage":0.0,"date":"2026-02-01T00:00:00Z","previous_month":"2026-01","next_month":"2026-03","start_date":"2026-02-01T00:00:00Z","end_date":"2026-02-28T23:59:59.999Z","currency":"EUR","currency_symbol":"\\u20ac","prices":[]}
    """

    // swiftlint:enable line_length

    @Test
    func `parses response with usage data and computes token totals`() throws {
        let data = try #require(Self.novemberResponseJSON.data(using: .utf8))
        let snapshot = try MistralUsageFetcher.parseResponse(data: data, updatedAt: Date())

        // mistral-large input: 11121, mistral-small input: 20+100=120
        #expect(snapshot.totalInputTokens == 11121 + 120)
        // mistral-large output: 1115, mistral-small output: 500+2482=2982
        #expect(snapshot.totalOutputTokens == 1115 + 2982)
        #expect(snapshot.totalCachedTokens == 0)
        #expect(snapshot.modelCount == 2)
        #expect(snapshot.currency == "EUR")
        #expect(snapshot.currencySymbol == "€")
        #expect(snapshot.daily.map(\.day) == ["2025-11-14", "2025-11-24"])
        #expect(snapshot.daily.first?.totalTokens == 11121 + 1115 + 20 + 500)
        #expect(snapshot.daily.first?.models.first?.name == "mistral-large-latest")
    }

    @Test
    func `computes cost from tokens and prices`() throws {
        let data = try #require(Self.novemberResponseJSON.data(using: .utf8))
        let snapshot = try MistralUsageFetcher.parseResponse(data: data, updatedAt: Date())

        // mistral-large-2411 input: 11121 * 0.0000017 = 0.0189057
        // mistral-large-2411 output: 1115 * 0.0000051 = 0.0056865
        // mistral-small-2506 input: 120 * 0.000000085 = 0.0000102
        // mistral-small-2506 output: 2982 * 0.000000255 = 0.00076041
        let expectedCost = 0.0189057 + 0.0056865 + 0.0000102 + 0.00076041
        #expect(abs(snapshot.totalCost - expectedCost) < 0.0001)
        #expect(snapshot.totalCost > 0)
    }

    @Test(arguments: ["NaN", "Infinity", "1e308"])
    func `ignores prices that produce nonfinite costs`(price: String) async throws {
        let json = """
        {
          "completion": {
            "models": {
              "mistral-small": {
                "input": [{
                  "billing_metric": "tokens",
                  "billing_group": "input",
                  "timestamp": "2026-07-04",
                  "value": 2
                }]
              }
            }
          },
          "prices": [{
            "billing_metric": "tokens",
            "billing_group": "input",
            "price": "\(price)"
          }]
        }
        """
        let transport = ProviderHTTPTransportHandler { request in
            #expect(request.url?.path == "/api/billing/v2/usage")
            #expect(request.value(forHTTPHeaderField: "Cookie") == "ory_session_test=abc")
            let requestURL = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: requestURL,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil))
            return (Data(json.utf8), response)
        }

        let snapshot = try await MistralUsageFetcher.fetchUsage(
            cookieHeader: "ory_session_test=abc",
            csrfToken: nil,
            transport: transport)

        #expect(snapshot.totalCost == 0)
        #expect(snapshot.totalCost.isFinite)
        #expect(snapshot.daily.first?.cost == 0)
        #expect(snapshot.daily.first?.models.first?.cost == 0)
    }

    @Test
    func `keeps cost totals finite when individually valid costs overflow their sum`() throws {
        let json = """
        {
          "completion": {
            "models": {
              "mistral-small": {
                "input": [
                  {
                    "billing_metric": "tokens",
                    "billing_group": "input",
                    "timestamp": "2026-07-04",
                    "value": 1
                  },
                  {
                    "billing_metric": "tokens",
                    "billing_group": "input",
                    "timestamp": "2026-07-04",
                    "value": 1
                  }
                ]
              },
              "mistral-large": {
                "input": [{
                  "billing_metric": "tokens",
                  "billing_group": "input",
                  "timestamp": "2026-07-04",
                  "value": 1
                }]
              }
            }
          },
          "prices": [{
            "billing_metric": "tokens",
            "billing_group": "input",
            "price": "1e308"
          }]
        }
        """

        let snapshot = try MistralUsageFetcher.parseResponse(data: Data(json.utf8), updatedAt: Date())

        #expect(snapshot.totalCost == 1e308)
        #expect(snapshot.totalCost.isFinite)
        #expect(snapshot.daily.first?.cost == 1e308)
        #expect(snapshot.daily.first?.models.count == 2)
        #expect(snapshot.daily.first?.models.allSatisfy { $0.cost == 1e308 } == true)
    }

    @Test
    func `parses empty response with no usage`() throws {
        let data = try #require(Self.emptyResponseJSON.data(using: .utf8))
        let snapshot = try MistralUsageFetcher.parseResponse(data: data, updatedAt: Date())

        #expect(snapshot.totalInputTokens == 0)
        #expect(snapshot.totalOutputTokens == 0)
        #expect(snapshot.totalCost == 0)
        #expect(snapshot.modelCount == 0)
        #expect(snapshot.currency == "EUR")
    }

    @Test
    func `parses credits response`() throws {
        let json = """
        {
          "wallet_amount": 12.5,
          "credit_notes_amount": 2.25,
          "ongoing_usage_balance": 1.5,
          "currency": "USD",
          "minimum_credits_purchase": 10,
          "maximum_credits_purchase": 1000
        }
        """

        let credits = try MistralUsageFetcher.parseCredits(data: Data(json.utf8))

        #expect(credits.walletAmount == 12.5)
        #expect(credits.creditNotesAmount == 2.25)
        #expect(credits.ongoingUsageBalance == 1.5)
        #expect(credits.currency == "USD")
        #expect(credits.availableAmount == 13.25)
        #expect(credits.formattedAvailableAmount == "$13.25")
    }

    @Test
    func `credits available amount floors after ongoing usage`() {
        let credits = MistralCreditsSnapshot(
            walletAmount: 1,
            creditNotesAmount: 0.5,
            ongoingUsageBalance: 3,
            currency: "USD")

        #expect(credits.availableAmount == 0)
        #expect(credits.formattedAvailableAmount == "$0.00")
    }

    @Test
    func `rejects credit amounts whose sum overflows`() throws {
        let json = """
        {
          "wallet_amount": 1e308,
          "credit_notes_amount": 1e308,
          "ongoing_usage_balance": 0,
          "currency": "USD"
        }
        """

        #expect(throws: MistralUsageError.self) {
            try MistralUsageFetcher.parseCredits(data: Data(json.utf8))
        }

        let credits = MistralCreditsSnapshot(
            walletAmount: 1e308,
            creditNotesAmount: 1e308,
            ongoingUsageBalance: 0,
            currency: "USD")
        #expect(credits.availableAmount == 0)
        #expect(credits.formattedAvailableAmount == "$0.00")
    }

    @Test
    func `fetches credits from dashboard endpoint with existing web session`() async throws {
        let json = """
        {
          "wallet_amount": 3,
          "credit_notes_amount": 4,
          "ongoing_usage_balance": 0,
          "currency": "EUR"
        }
        """
        let transport = ProviderHTTPTransportHandler { request in
            #expect(request.url?.absoluteString == "https://admin.mistral.ai/api/billing/credits")
            #expect(request.value(forHTTPHeaderField: "Cookie") == "ory_session_test=abc; csrftoken=csrf")
            #expect(request.value(forHTTPHeaderField: "X-CSRFTOKEN") == "csrf")
            #expect(request.value(forHTTPHeaderField: "Referer") == "https://admin.mistral.ai/organization/billing")
            let requestURL = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: requestURL,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil))
            return (Data(json.utf8), response)
        }

        let credits = try await MistralUsageFetcher.fetchCredits(
            cookieHeader: "ory_session_test=abc; csrftoken=csrf",
            csrfToken: "csrf",
            transport: transport)

        #expect(credits.availableAmount == 7)
        #expect(credits.formattedAvailableAmount == "€7.00")
    }

    @Test
    func `daily spend keeps non token Mistral units out of token totals`() throws {
        let json = """
        {
          "libraries_api": {
            "pages": {
              "models": {
                "mistral-ocr-latest": {
                  "input": [
                    {
                      "billing_metric": "pages",
                      "billing_display_name": "OCR pages",
                      "billing_group": "input",
                      "timestamp": "2025-11-15",
                      "value": 42,
                      "value_paid": 42
                    }
                  ]
                }
              }
            }
          },
          "currency": "EUR",
          "currency_symbol": "€",
          "prices": [
            {
              "billing_metric": "pages",
              "billing_group": "input",
              "price": "0.01"
            }
          ]
        }
        """
        let snapshot = try MistralUsageFetcher.parseResponse(data: Data(json.utf8), updatedAt: Date())

        #expect(abs(snapshot.totalCost - 0.42) < 0.0001)
        #expect(snapshot.totalInputTokens == 0)
        #expect(abs((snapshot.daily.first?.cost ?? 0) - 0.42) < 0.0001)
        #expect(snapshot.daily.first?.totalTokens == 0)
        #expect(abs((snapshot.daily.first?.models.first?.cost ?? 0) - 0.42) < 0.0001)
        #expect(snapshot.daily.first?.models.first?.totalTokens == 0)
    }

    @Test
    func `parses dates from response`() throws {
        let data = try #require(Self.novemberResponseJSON.data(using: .utf8))
        let snapshot = try MistralUsageFetcher.parseResponse(data: data, updatedAt: Date())

        #expect(snapshot.startDate != nil)
        #expect(snapshot.endDate != nil)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        if let start = snapshot.startDate {
            #expect(calendar.component(.month, from: start) == 11)
            #expect(calendar.component(.year, from: start) == 2025)
        }
    }

    @Test
    func `throws parseFailed for invalid JSON`() {
        let data = Data("not json".utf8)
        #expect(throws: MistralUsageError.self) {
            try MistralUsageFetcher.parseResponse(data: data, updatedAt: Date())
        }
    }
}

struct MistralUsageSnapshotConversionTests {
    @Test
    func `converts cost into text only current month api spend`() {
        let snapshot = MistralUsageSnapshot(
            totalCost: 1.2345,
            currency: "EUR",
            currencySymbol: "€",
            totalInputTokens: 10000,
            totalOutputTokens: 5000,
            totalCachedTokens: 0,
            modelCount: 2,
            startDate: nil,
            endDate: Date(),
            updatedAt: Date())

        let usage = snapshot.toUsageSnapshot()
        #expect(usage.primary == nil)
        #expect(usage.identity?.providerID == .mistral)
        #expect(usage.identity?.loginMethod == "API spend: €1.2345 this month")
        #expect(usage.providerCost == nil)
    }

    @Test
    func `converts credits into balance data without replacing api spend or primary percent`() {
        let credits = MistralCreditsSnapshot(
            walletAmount: 10,
            creditNotesAmount: 2.5,
            ongoingUsageBalance: 1,
            currency: "USD")
        let snapshot = MistralUsageSnapshot(
            totalCost: 1.2345,
            currency: "USD",
            currencySymbol: "$",
            totalInputTokens: 10000,
            totalOutputTokens: 5000,
            totalCachedTokens: 0,
            modelCount: 2,
            credits: credits,
            startDate: nil,
            endDate: Date(),
            updatedAt: Date())

        let usage = snapshot.toUsageSnapshot()
        #expect(usage.primary == nil)
        #expect(usage.identity?.loginMethod == "API spend: $1.2345 this month")
        #expect(usage.mistralUsage?.credits == credits)
        #expect(usage.mistralUsage?.credits?.formattedAvailableAmount == "$11.50")
    }

    @Test
    func `converts zero cost into zero spend text`() {
        let snapshot = MistralUsageSnapshot(
            totalCost: 0,
            currency: "USD",
            currencySymbol: "$",
            totalInputTokens: 0,
            totalOutputTokens: 0,
            totalCachedTokens: 0,
            modelCount: 0,
            startDate: nil,
            endDate: nil,
            updatedAt: Date())

        let usage = snapshot.toUsageSnapshot()
        #expect(usage.primary == nil)
        #expect(usage.identity?.loginMethod == "API spend: $0.0000 this month")
    }

    @Test
    func `converts billing usage into cost token snapshot`() {
        let now = Date(timeIntervalSince1970: 1_700_179_200)
        let snapshot = MistralUsageSnapshot(
            totalCost: 1.75,
            currency: "eur",
            currencySymbol: "€",
            totalInputTokens: 300,
            totalOutputTokens: 150,
            totalCachedTokens: 50,
            modelCount: 2,
            daily: [
                MistralDailyUsageBucket(
                    day: "2023-11-14",
                    cost: 1.5,
                    inputTokens: 100,
                    cachedTokens: 20,
                    outputTokens: 50,
                    models: [
                        MistralDailyUsageBucket.ModelBreakdown(
                            name: "mistral-large",
                            cost: 1.5,
                            inputTokens: 100,
                            cachedTokens: 20,
                            outputTokens: 50),
                    ]),
                MistralDailyUsageBucket(
                    day: "2023-11-15",
                    cost: 0.25,
                    inputTokens: 200,
                    cachedTokens: 30,
                    outputTokens: 100,
                    models: [
                        MistralDailyUsageBucket.ModelBreakdown(
                            name: "mistral-small",
                            cost: 0.25,
                            inputTokens: 200,
                            cachedTokens: 30,
                            outputTokens: 100),
                    ]),
            ],
            startDate: nil,
            endDate: nil,
            updatedAt: now)

        let cost = snapshot.toCostUsageTokenSnapshot(historyDays: 1)
        #expect(cost.currencyCode == "EUR")
        #expect(cost.historyLabel == "This month")
        #expect(cost.historyDays == 2)
        #expect(cost.sessionCostUSD == 0.25)
        #expect(cost.sessionTokens == 330)
        #expect(cost.last30DaysCostUSD == 1.75)
        #expect(cost.last30DaysTokens == 500)
        #expect(cost.daily.count == 2)
        #expect(cost.daily.last?.modelsUsed == ["mistral-small"])
    }

    @Test
    func `clamps negative billing adjustments in cost token snapshot`() {
        let now = Date(timeIntervalSince1970: 1_700_179_200)
        let snapshot = MistralUsageSnapshot(
            totalCost: -2,
            currency: "EUR",
            currencySymbol: "€",
            totalInputTokens: 100,
            totalOutputTokens: 25,
            totalCachedTokens: 0,
            modelCount: 1,
            daily: [
                MistralDailyUsageBucket(
                    day: "2023-11-14",
                    cost: -1.5,
                    inputTokens: 100,
                    cachedTokens: 0,
                    outputTokens: 25,
                    models: [
                        MistralDailyUsageBucket.ModelBreakdown(
                            name: "mistral-large",
                            cost: -1.5,
                            inputTokens: 100,
                            cachedTokens: 0,
                            outputTokens: 25),
                    ]),
            ],
            startDate: nil,
            endDate: nil,
            updatedAt: now)

        let cost = snapshot.toCostUsageTokenSnapshot()
        #expect(cost.sessionCostUSD == 0)
        #expect(cost.last30DaysCostUSD == 0)
        #expect(cost.daily.first?.costUSD == 0)
        #expect(cost.daily.first?.modelBreakdowns?.first?.costUSD == 0)
    }

    @Test
    func `preserves net monthly cost when billing includes credits`() {
        let now = Date(timeIntervalSince1970: 1_700_179_200)
        let snapshot = MistralUsageSnapshot(
            totalCost: 8,
            currency: "EUR",
            currencySymbol: "€",
            totalInputTokens: 100,
            totalOutputTokens: 25,
            totalCachedTokens: 0,
            modelCount: 1,
            daily: [
                MistralDailyUsageBucket(
                    day: "2023-11-14",
                    cost: 10,
                    inputTokens: 100,
                    cachedTokens: 0,
                    outputTokens: 25,
                    models: []),
                MistralDailyUsageBucket(
                    day: "2023-11-15",
                    cost: -2,
                    inputTokens: 0,
                    cachedTokens: 0,
                    outputTokens: 0,
                    models: []),
            ],
            startDate: nil,
            endDate: nil,
            updatedAt: now)

        let cost = snapshot.toCostUsageTokenSnapshot()
        #expect(cost.last30DaysCostUSD == 8)
        #expect(cost.sessionCostUSD == 0)
        #expect(cost.daily.map(\.costUSD) == [10, 0])
    }
}

struct MistralStrategyTests {
    private struct StubClaudeFetcher: ClaudeUsageFetching {
        func loadLatestUsage(model _: String) async throws -> ClaudeUsageSnapshot {
            throw ClaudeUsageError.parseFailed("stub")
        }

        func debugRawProbe(model _: String) async -> String {
            "stub"
        }

        func detectVersion() -> String? {
            nil
        }
    }

    private func makeContext(
        sourceMode: ProviderSourceMode = .auto,
        settings: ProviderSettingsSnapshot? = nil,
        env: [String: String] = [:]) -> ProviderFetchContext
    {
        let browserDetection = BrowserDetection(cacheTTL: 0)
        return ProviderFetchContext(
            runtime: .cli,
            sourceMode: sourceMode,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: env,
            settings: settings,
            fetcher: UsageFetcher(environment: env),
            claudeFetcher: StubClaudeFetcher(),
            browserDetection: browserDetection)
    }

    @Test
    func `strategy is unavailable when cookie source is off`() async {
        let settings = ProviderSettingsSnapshot.make(
            mistral: ProviderSettingsSnapshot.MistralProviderSettings(
                cookieSource: .off,
                manualCookieHeader: nil))
        let context = self.makeContext(settings: settings)
        let strategy = MistralWebFetchStrategy()

        let available = await strategy.isAvailable(context)
        #expect(available == false)
    }

    @Test
    func `strategy is available when cookie source is auto`() async {
        let settings = ProviderSettingsSnapshot.make(
            mistral: ProviderSettingsSnapshot.MistralProviderSettings(
                cookieSource: .auto,
                manualCookieHeader: nil))
        let context = self.makeContext(settings: settings)
        let strategy = MistralWebFetchStrategy()

        let available = await strategy.isAvailable(context)
        #expect(available == true)
    }

    @Test
    func `strategy is available when cookie source is manual`() async {
        let settings = ProviderSettingsSnapshot.make(
            mistral: ProviderSettingsSnapshot.MistralProviderSettings(
                cookieSource: .manual,
                manualCookieHeader: "ory_session_x=abc; csrftoken=xyz"))
        let context = self.makeContext(settings: settings)
        let strategy = MistralWebFetchStrategy()

        let available = await strategy.isAvailable(context)
        #expect(available == true)
    }

    @Test
    func `strategy never falls back (single strategy provider)`() {
        let strategy = MistralWebFetchStrategy()
        let context = self.makeContext()
        let shouldFallback = strategy.shouldFallback(
            on: MistralUsageError.invalidCredentials,
            context: context)
        #expect(shouldFallback == false)
    }

    @Test
    func `descriptor metadata is correct`() {
        let descriptor = MistralProviderDescriptor.descriptor
        #expect(descriptor.id == .mistral)
        #expect(descriptor.metadata.displayName == "Mistral")
        #expect(descriptor.metadata.cliName == "mistral")
        #expect(descriptor.metadata.defaultEnabled == false)
        #expect(descriptor.cli.name == "mistral")
        #expect(descriptor.fetchPlan.sourceModes == [.auto, .web])
        #expect(descriptor.branding.iconResourceName == "ProviderIcon-mistral")
        #expect(descriptor.tokenCost.supportsTokenCost)
    }
}
