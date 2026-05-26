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

        let calendar = Calendar.current
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
