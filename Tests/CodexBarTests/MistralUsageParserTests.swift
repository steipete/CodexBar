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
    func `converts cost to UsageSnapshot with provider cost`() {
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
        #expect(usage.primary != nil)
        #expect(usage.primary?.usedPercent == 0)
        #expect(usage.primary?.resetDescription?.contains("€1.2345") == true)
        #expect(usage.providerCost != nil)
        #expect(usage.providerCost?.used == 1.2345)
        #expect(usage.providerCost?.currencyCode == "EUR")
        #expect(usage.providerCost?.period == "Monthly")
    }

    @Test
    func `converts zero cost with no-usage description`() {
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
        #expect(usage.primary?.resetDescription == "No usage this month")
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
    }
}
