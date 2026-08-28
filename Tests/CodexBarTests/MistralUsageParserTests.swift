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

    @Test(arguments: ["{}", #"{"currency":"   ","currency_symbol":"  "}"#])
    func `missing currency stays explicitly unknown`(json: String) throws {
        let snapshot = try MistralUsageFetcher.parseResponse(data: Data(json.utf8), updatedAt: Date())

        #expect(snapshot.currency == "XXX")
        #expect(snapshot.currencySymbol == "¤")
        #expect(snapshot.toCostUsageTokenSnapshot().currencyCode == "XXX")
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
    func `requested one day trims rows totals and latest session to observed UTC day`() throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2023-11-15T12:00:00Z"))
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
        #expect(cost.historyLabel == nil)
        #expect(cost.historyDays == 1)
        #expect(cost.sessionCostUSD == 0.25)
        #expect(cost.sessionTokens == 330)
        #expect(cost.last30DaysCostUSD == 0.25)
        #expect(cost.last30DaysTokens == 330)
        #expect(cost.daily.map(\.date) == ["2023-11-15"])
        #expect(cost.daily.first?.modelsUsed == ["mistral-small"])
    }

    @Test
    func `sparse daily usage reports inclusive covered day span`() throws {
        let updatedAt = try #require(ISO8601DateFormatter().date(from: "2026-07-16T12:00:00Z"))
        let snapshot = Self.coverageSnapshot(
            dailyDays: ["2026-07-01", "2026-07-16"],
            updatedAt: updatedAt)

        #expect(snapshot.toCostUsageTokenSnapshot().historyDays == 16)
        let sevenDays = snapshot.toCostUsageTokenSnapshot(historyDays: 7)
        #expect(sevenDays.historyDays == 1)
        #expect(sevenDays.daily.map(\.date) == ["2026-07-16"])
        #expect(sevenDays.last30DaysCostUSD == 1)
        #expect(sevenDays.last30DaysTokens == 1)
    }

    @Test
    func `metadata free coverage ends on latest valid billing bucket`() throws {
        let formatter = ISO8601DateFormatter()
        let updatedAt = try #require(formatter.date(from: "2026-07-16T12:00:00Z"))
        let fetchDay = try #require(formatter.date(from: "2026-07-16T00:00:00Z"))
        let latestBucket = try #require(formatter.date(from: "2026-07-15T00:00:00Z"))
        let snapshot = Self.coverageSnapshot(
            dailyDays: ["2026-07-14", "2026-07-15"],
            updatedAt: updatedAt)

        let cost = snapshot.toCostUsageTokenSnapshot()
        #expect(cost.historyDays == 2)
        #expect(cost.updatedAt == latestBucket)
        #expect(cost.last30DaysCostUSD == 2)
        #expect(cost.last30DaysTokens == 2)

        let empty = Self.coverageSnapshot(dailyDays: [], updatedAt: updatedAt)
            .toCostUsageTokenSnapshot()
        #expect(empty.historyDays == 1)
        #expect(!empty.historyCoverageIsEstablished)
        #expect(empty.updatedAt == fetchDay)
        #expect(empty.last30DaysCostUSD == nil)
        #expect(empty.last30DaysTokens == nil)

        let invalid = MistralUsageSnapshot(
            totalCost: 1,
            currency: "EUR",
            currencySymbol: "€",
            totalInputTokens: 1,
            totalOutputTokens: 0,
            totalCachedTokens: 0,
            modelCount: 1,
            daily: [Self.bucket(day: "not-a-day")],
            startDate: nil,
            endDate: nil,
            updatedAt: updatedAt)
            .toCostUsageTokenSnapshot()
        #expect(invalid.historyDays == 1)
        #expect(!invalid.historyCoverageIsEstablished)
        #expect(invalid.updatedAt == fetchDay)
        #expect(invalid.last30DaysCostUSD == nil)
        #expect(invalid.last30DaysTokens == nil)

        let outsideWindow = Self.coverageSnapshot(
            dailyDays: ["2026-07-01"],
            updatedAt: updatedAt)
            .toCostUsageTokenSnapshot(historyDays: 7)
        #expect(!outsideWindow.historyCoverageIsEstablished)
        #expect(outsideWindow.daily.isEmpty)
        #expect(outsideWindow.last30DaysCostUSD == nil)
        #expect(outsideWindow.last30DaysTokens == nil)
    }

    @Test
    func `metadata coverage uses UTC dates and stops at earlier boundary`() throws {
        let formatter = ISO8601DateFormatter()
        let start = try #require(formatter.date(from: "2026-07-01T23:59:59Z"))
        let monthEnd = try #require(formatter.date(from: "2026-07-31T23:59:59Z"))
        let updatedAt = try #require(formatter.date(from: "2026-07-16T00:00:01Z"))
        let secondDay = try #require(formatter.date(from: "2026-07-02T00:00:01Z"))
        let longRangeStart = try #require(formatter.date(from: "2020-01-01T00:00:00Z"))

        let currentMonth = Self.coverageSnapshot(
            dailyDays: ["2026-07-16"],
            startDate: start,
            endDate: monthEnd,
            updatedAt: updatedAt)
        let endedRange = Self.coverageSnapshot(
            dailyDays: ["2026-07-01", "2026-07-02"],
            startDate: start,
            endDate: secondDay,
            updatedAt: updatedAt)
        let longRange = Self.coverageSnapshot(
            dailyDays: [],
            startDate: longRangeStart,
            endDate: monthEnd,
            updatedAt: updatedAt)

        #expect(currentMonth.toCostUsageTokenSnapshot().historyDays == 16)
        #expect(currentMonth.toCostUsageTokenSnapshot().historyLabel == "This month")
        let endedCost = endedRange.toCostUsageTokenSnapshot()
        #expect(endedCost.historyDays == 2)
        #expect(endedCost.historyLabel == nil)
        #expect(endedCost.updatedAt == formatter.date(from: "2026-07-02T00:00:00Z"))
        #expect(endedRange.toUsageSnapshot().updatedAt == updatedAt)
        #expect(longRange.toCostUsageTokenSnapshot(historyDays: 900).historyDays == 365)
    }

    @Test
    func `metadata preserves empty covered days while excluding rows before requested window`() throws {
        let formatter = ISO8601DateFormatter()
        let start = try #require(formatter.date(from: "2026-07-01T00:00:00Z"))
        let end = try #require(formatter.date(from: "2026-07-31T23:59:59Z"))
        let updatedAt = try #require(formatter.date(from: "2026-07-16T12:00:00Z"))
        let snapshot = Self.coverageSnapshot(
            dailyDays: ["2026-07-01", "2026-07-10", "2026-07-16"],
            startDate: start,
            endDate: end,
            updatedAt: updatedAt)

        let cost = snapshot.toCostUsageTokenSnapshot(historyDays: 7)
        #expect(cost.historyDays == 7)
        #expect(cost.historyLabel == nil)
        #expect(cost.daily.map(\.date) == ["2026-07-10", "2026-07-16"])
        #expect(cost.last30DaysCostUSD == 2)
        #expect(cost.last30DaysTokens == 2)
    }

    @Test
    func `empty current month still reports metadata coverage`() throws {
        let formatter = ISO8601DateFormatter()
        let start = try #require(formatter.date(from: "2026-07-01T00:00:00Z"))
        let end = try #require(formatter.date(from: "2026-07-31T23:59:59Z"))
        let updatedAt = try #require(formatter.date(from: "2026-07-02T12:00:00Z"))
        let snapshot = Self.coverageSnapshot(
            dailyDays: [],
            startDate: start,
            endDate: end,
            updatedAt: updatedAt)

        #expect(snapshot.toCostUsageTokenSnapshot().historyDays == 2)
        #expect(snapshot.toCostUsageTokenSnapshot().historyLabel == "This month")
    }

    @Test(arguments: [
        "not-a-day",
        "2026-07-01junk",
        "２０２６-０７-０１",
        "2026-02-30",
        " 2026-07-01",
    ])
    func `invalid coverage provenance fails closed after requested clamp`(day: String) {
        let snapshot = Self.coverageSnapshot(
            dailyDays: [day],
            updatedAt: Date())

        #expect(snapshot.toCostUsageTokenSnapshot(historyDays: 900).historyDays == 1)
    }

    @Test
    func `malformed nonzero row keeps requested window unavailable`() throws {
        let updatedAt = try #require(ISO8601DateFormatter().date(from: "2026-07-16T12:00:00Z"))
        let snapshot = Self.coverageSnapshot(
            dailyDays: ["2026-07-01junk", "2026-07-16"],
            updatedAt: updatedAt)

        let cost = snapshot.toCostUsageTokenSnapshot(historyDays: 1)
        #expect(cost.historyDays == 1)
        #expect(cost.daily.map(\.date) == ["2026-07-01junk", "2026-07-16"])
        #expect(cost.daily.allSatisfy { $0.costUSD == nil && $0.totalTokens == nil })
        #expect(cost.sessionCostUSD == nil)
        #expect(cost.sessionTokens == nil)
        #expect(cost.last30DaysCostUSD == nil)
        #expect(cost.last30DaysTokens == nil)
    }

    @Test
    func `negative aggregate token counter fails closed despite equal signed net`() {
        let snapshot = Self.tokenValidationSnapshot(
            totalInputTokens: -5,
            totalOutputTokens: 15,
            daily: [Self.tokenBucket(day: "2026-07-16", inputTokens: 10)])

        Self.expectTokenDataUnavailable(snapshot.toCostUsageTokenSnapshot())
    }

    @Test
    func `negative daily token counter fails closed despite equal signed net`() {
        let snapshot = Self.tokenValidationSnapshot(
            totalInputTokens: 10,
            daily: [Self.tokenBucket(day: "2026-07-16", inputTokens: 15, cachedTokens: -5)])

        Self.expectTokenDataUnavailable(snapshot.toCostUsageTokenSnapshot())
    }

    @Test
    func `negative model token counter fails closed despite equal signed net`() {
        let snapshot = Self.tokenValidationSnapshot(
            totalInputTokens: 10,
            daily: [
                Self.tokenBucket(
                    day: "2026-07-16",
                    inputTokens: 10,
                    modelInputTokens: 15,
                    modelOutputTokens: -5),
            ])

        Self.expectTokenDataUnavailable(snapshot.toCostUsageTokenSnapshot())
    }

    @Test
    func `zero and positive token counters remain complete`() {
        let snapshot = Self.tokenValidationSnapshot(
            totalInputTokens: 4,
            totalCachedTokens: 2,
            totalOutputTokens: 4,
            daily: [
                Self.tokenBucket(day: "2026-07-15", inputTokens: 0),
                Self.tokenBucket(day: "2026-07-16", inputTokens: 4, cachedTokens: 2, outputTokens: 4),
            ])

        let cost = snapshot.toCostUsageTokenSnapshot()
        #expect(cost.last30DaysTokens == 10)
        #expect(cost.sessionTokens == 10)
        #expect(cost.daily.map(\.totalTokens) == [0, 10])
        #expect(cost.daily.map { $0.modelBreakdowns?.first?.totalTokens } == [0, 10])
        #expect(cost.last30DaysCostUSD == 2)
    }

    @Test
    func `negative excluded cost bucket cannot prove selected empty window is zero`() throws {
        let updatedAt = try #require(ISO8601DateFormatter().date(from: "2026-07-16T12:00:00Z"))
        let snapshot = Self.costValidationSnapshot(
            totalCost: 10,
            daily: [
                Self.costBucket(day: "2026-07-14", cost: -5),
                Self.costBucket(day: "2026-07-15", cost: 15),
            ],
            updatedAt: updatedAt)

        let cost = snapshot.toCostUsageTokenSnapshot(historyDays: 1)
        #expect(cost.daily.isEmpty)
        #expect(!cost.historyCoverageIsEstablished)
        #expect(cost.last30DaysCostUSD == nil)
        #expect(cost.sessionCostUSD == nil)
        #expect(cost.last30DaysTokens == nil)
    }

    @Test
    func `negative model cost invalidates cost proof while preserving valid tokens`() {
        let snapshot = Self.costValidationSnapshot(
            totalCost: 1,
            totalInputTokens: 10,
            daily: [
                Self.costBucket(
                    day: "2026-07-16",
                    cost: 1,
                    modelCosts: [-1, 2],
                    tokens: 10),
            ])

        let cost = snapshot.toCostUsageTokenSnapshot()
        #expect(cost.last30DaysCostUSD == nil)
        #expect(cost.sessionCostUSD == nil)
        #expect(cost.daily.first?.costUSD == nil)
        #expect(cost.daily.first?.modelBreakdowns?.allSatisfy { $0.costUSD == nil } == true)
        #expect(cost.last30DaysTokens == 10)
        #expect(cost.sessionTokens == 10)
    }

    @Test
    func `zero and positive costs remain complete`() {
        let snapshot = Self.costValidationSnapshot(
            totalCost: 2,
            daily: [
                Self.costBucket(day: "2026-07-15", cost: 0),
                Self.costBucket(day: "2026-07-16", cost: 2),
            ])

        let cost = snapshot.toCostUsageTokenSnapshot()
        #expect(cost.last30DaysCostUSD == 2)
        #expect(cost.sessionCostUSD == 2)
        #expect(cost.daily.map(\.costUSD) == [0, 2])
        #expect(cost.daily.map { $0.modelBreakdowns?.first?.costUSD } == [0, 2])
        #expect(cost.last30DaysTokens == 0)
    }

    @Test
    func `negative billing adjustment fails closed in cost token snapshot`() {
        let now = Date(timeIntervalSince1970: 1_700_179_200)
        let snapshot = MistralUsageSnapshot(
            totalCost: -1.5,
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
        #expect(cost.sessionCostUSD == nil)
        #expect(cost.last30DaysCostUSD == nil)
        #expect(cost.daily.first?.costUSD == nil)
        #expect(cost.daily.first?.modelBreakdowns?.first?.costUSD == nil)
        #expect(cost.last30DaysTokens == 125)
        #expect(cost.sessionTokens == 125)
        #expect(snapshot.toUsageSnapshot().identity?.loginMethod == "API spend: €0.0000 this month")
    }

    @Test
    func `credit adjusted window fails closed without changing primary monthly spend`() {
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
        #expect(cost.last30DaysCostUSD == nil)
        #expect(cost.sessionCostUSD == nil)
        #expect(cost.daily.map(\.costUSD) == [nil, nil])
        #expect(snapshot.toUsageSnapshot().identity?.loginMethod == "API spend: €8.0000 this month")
    }

    private static func bucket(day: String) -> MistralDailyUsageBucket {
        MistralDailyUsageBucket(
            day: day,
            cost: 1,
            inputTokens: 1,
            cachedTokens: 0,
            outputTokens: 0,
            models: [])
    }

    private static func tokenBucket(
        day: String,
        inputTokens: Int,
        cachedTokens: Int = 0,
        outputTokens: Int = 0,
        modelInputTokens: Int? = nil,
        modelCachedTokens: Int? = nil,
        modelOutputTokens: Int? = nil) -> MistralDailyUsageBucket
    {
        MistralDailyUsageBucket(
            day: day,
            cost: 1,
            inputTokens: inputTokens,
            cachedTokens: cachedTokens,
            outputTokens: outputTokens,
            models: [
                .init(
                    name: "test-model",
                    cost: 1,
                    inputTokens: modelInputTokens ?? inputTokens,
                    cachedTokens: modelCachedTokens ?? cachedTokens,
                    outputTokens: modelOutputTokens ?? outputTokens),
            ])
    }

    private static func costBucket(
        day: String,
        cost: Double,
        modelCosts: [Double]? = nil,
        tokens: Int = 0) -> MistralDailyUsageBucket
    {
        let costs = modelCosts ?? [cost]
        return MistralDailyUsageBucket(
            day: day,
            cost: cost,
            inputTokens: tokens,
            cachedTokens: 0,
            outputTokens: 0,
            models: costs.enumerated().map { index, modelCost in
                .init(
                    name: "test-model-\(index)",
                    cost: modelCost,
                    inputTokens: index == 0 ? tokens : 0,
                    cachedTokens: 0,
                    outputTokens: 0)
            })
    }

    private static func costValidationSnapshot(
        totalCost: Double,
        totalInputTokens: Int = 0,
        daily: [MistralDailyUsageBucket],
        updatedAt: Date = Date(timeIntervalSince1970: 1_784_179_200)) -> MistralUsageSnapshot
    {
        MistralUsageSnapshot(
            totalCost: totalCost,
            currency: "EUR",
            currencySymbol: "€",
            totalInputTokens: totalInputTokens,
            totalOutputTokens: 0,
            totalCachedTokens: 0,
            modelCount: daily.flatMap(\.models).count,
            daily: daily,
            startDate: nil,
            endDate: nil,
            updatedAt: updatedAt)
    }

    private static func tokenValidationSnapshot(
        totalInputTokens: Int,
        totalCachedTokens: Int = 0,
        totalOutputTokens: Int = 0,
        daily: [MistralDailyUsageBucket]) -> MistralUsageSnapshot
    {
        MistralUsageSnapshot(
            totalCost: Double(daily.count),
            currency: "EUR",
            currencySymbol: "€",
            totalInputTokens: totalInputTokens,
            totalOutputTokens: totalOutputTokens,
            totalCachedTokens: totalCachedTokens,
            modelCount: 1,
            daily: daily,
            startDate: nil,
            endDate: nil,
            updatedAt: Date(timeIntervalSince1970: 1_784_179_200))
    }

    private static func expectTokenDataUnavailable(_ snapshot: CostUsageTokenSnapshot) {
        #expect(snapshot.last30DaysTokens == nil)
        #expect(snapshot.sessionTokens == nil)
        #expect(snapshot.daily.allSatisfy {
            $0.inputTokens == nil
                && $0.cacheReadTokens == nil
                && $0.outputTokens == nil
                && $0.totalTokens == nil
                && $0.modelBreakdowns?.allSatisfy { $0.totalTokens == nil } == true
        })
        #expect(snapshot.last30DaysCostUSD == 1)
    }

    private static func coverageSnapshot(
        dailyDays: [String],
        startDate: Date? = nil,
        endDate: Date? = nil,
        updatedAt: Date) -> MistralUsageSnapshot
    {
        MistralUsageSnapshot(
            totalCost: Double(dailyDays.count),
            currency: "EUR",
            currencySymbol: "€",
            totalInputTokens: dailyDays.count,
            totalOutputTokens: 0,
            totalCachedTokens: 0,
            modelCount: dailyDays.isEmpty ? 0 : 1,
            daily: dailyDays.map(self.bucket(day:)),
            startDate: startDate,
            endDate: endDate,
            updatedAt: updatedAt)
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
