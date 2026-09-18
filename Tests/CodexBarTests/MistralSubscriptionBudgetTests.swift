import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

private final class MistralSubscriptionRequestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequest: URLRequest?

    var request: URLRequest? {
        self.lock.withLock { self.storedRequest }
    }

    func record(_ request: URLRequest) {
        self.lock.withLock { self.storedRequest = request }
    }
}

@Suite
struct MistralSubscriptionBudgetTests {
    private static func flightPush(_ chunk: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [1, chunk])
        let encoded = String(bytes: data, encoding: .utf8) ?? ""
        return "<script>self.__next_f.push(\(encoded))</script>"
    }

    /// A single-budget flight record with only an `api_budget`.
    private static let apiOnlyRecord = // swiftlint:disable:next line_length
        #"7:["$",null,null,{"budget":{"api_budget":{"usage_percentage":1.1,"initial_budget":25.5,"currency":"eur","reset_at":"2026-10-01T00:00:00.000Z","payg_enabled":true}}}]"# +
        "\n"

    /// A full flight record with both `api_budget` and `vibe_budget`.
    private static let fullRecord = // swiftlint:disable:next line_length
        #"7:["$","$L1",null,{"budget":{"api_budget":{"usage_percentage":2.0,"initial_budget":25.5,"currency":"eur","reset_at":"2026-10-01T00:00:00.000Z","payg_enabled":false},"vibe_budget":{"usage_percentage":0.0,"initial_budget":255.0,"currency":"eur","reset_at":"2026-10-01T00:00:00.000Z","payg_enabled":false}}}]"# +
        "\n"

    @Test
    func `parses API allowance from subscription flight payload`() throws {
        // The escaped-HTML form mirrors what the browser actually ships; `fullRecord` is the raw record.
        let html = try Self.flightPush(Self.fullRecord)

        let result = try MistralSubscriptionBudgetParser.parse(html: html)

        let api = try #require(result.api)
        #expect(api.usagePercentage == 2)
        #expect(api.limit == 25.5)
        #expect(api.currencyCode == "EUR")
        #expect(api.usedAmount == 0.51)
        #expect(api.remainingAmount == 24.99)
        let expectedReset = try #require(ISO8601DateParser.parse("2026-10-01T00:00:00.000Z"))
        #expect(api.resetsAt == expectedReset)
        #expect(try #require(result.vibe).resetsAt == expectedReset)
    }

    @Test
    func `parses API allowance when Vibe allowance is absent`() throws {
        let html = try Self.flightPush(Self.apiOnlyRecord)

        let result = try MistralSubscriptionBudgetParser.parse(html: html)

        #expect(result.api?.usagePercentage == 1.1)
        #expect(result.api?.limit == 25.5)
        #expect(result.vibe == nil)
    }

    @Test
    func `reassembles subscription budget split across flight pushes`() throws {
        let record = Self.fullRecord
        let split = record.index(record.startIndex, offsetBy: record.count / 2)
        let html = try Self.flightPush(String(record[..<split]))
            + Self.flightPush(String(record[split...]))

        let result = try MistralSubscriptionBudgetParser.parse(html: html)

        #expect(result.api?.limit == 25.5)
        #expect(try #require(result.vibe).limit == 255)
    }

    @Test
    func `subscription request fetches authenticated budget page`() async throws {
        let data = try Data(Self.flightPush(Self.fullRecord).utf8)
        let capture = MistralSubscriptionRequestCapture()
        let transport = ProviderHTTPTransportHandler { request in
            capture.record(request)
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/html"]))
            return (data, response)
        }

        let result = try await MistralUsageFetcher.fetchSubscriptionBudgets(
            cookieHeader: "ory_session_test=abc; csrftoken=csrf",
            timeout: 2,
            transport: transport)
        let request = try #require(capture.request)

        #expect(result.api?.limit == 25.5)
        #expect(request.url?.absoluteString == "https://admin.mistral.ai/subscription")
        #expect(request.timeoutInterval == 2)
        #expect(request.httpShouldHandleCookies == false)
        #expect(request.value(forHTTPHeaderField: "Cookie") == "ory_session_test=abc; csrftoken=csrf")
        #expect(request.value(forHTTPHeaderField: "Accept") == "text/html")
    }

    @Test
    func `subscription budgets become API and Vibe windows`() throws {
        let html = try Self.flightPush(Self.fullRecord)
        let budgets = try MistralSubscriptionBudgetParser.parse(html: html)
        let existing = NamedRateWindow(
            id: "existing",
            title: "Existing",
            window: RateWindow(usedPercent: 4, windowMinutes: nil, resetsAt: nil, resetDescription: nil))
        let base = UsageSnapshot(
            primary: nil,
            secondary: nil,
            extraRateWindows: [existing],
            updatedAt: Date())

        let result = MistralWebFetchStrategy.attachSubscriptionBudgets(to: base, budgets: budgets)

        #expect(result.primary?.usedPercent == 2)
        #expect(result.primary?.resetsAt == budgets.api?.resetsAt)
        #expect(result.primary?.resetDescription == "€0.51 / €25.50 · €24.99 left")
        #expect(result.extraRateWindows?.contains(where: { $0.id == "existing" }) == true)
        let vibe = try #require(result.extraRateWindows?.first { $0.id == "mistral-monthly-plan" })
        #expect(vibe.window.usedPercent == 0)
        #expect(vibe.window.resetDescription == "€0.00 / €255.00 · €255.00 left")
    }

    @Test
    func `Mistral exposes included API as a selectable primary metric`() {
        let descriptor = MistralProviderDescriptor.descriptor
        let budgetWindow = RateWindow(
            usedPercent: 1.1,
            windowMinutes: nil,
            resetsAt: nil,
            resetDescription: "€0.28 / €25.50 · €25.22 left")

        #expect(descriptor.menuBarMetrics.supports(.primary))
        #expect(descriptor.metadata.sessionLabel == "Balance")
        #expect(descriptor.presentation.rateWindowLabels(
            metadata: descriptor.metadata,
            snapshot: UsageSnapshot(primary: budgetWindow, secondary: nil, updatedAt: Date()))
            .primary == "Included API")
        #expect(descriptor.presentation.rateWindowLabels(
            metadata: descriptor.metadata,
            snapshot: UsageSnapshot(primary: nil, secondary: nil, updatedAt: Date()))
            .primary == "Balance")
    }

    @Test
    func `Mistral renders only its own allowance window as a detail line`() {
        let menuCard = MistralProviderDescriptor.descriptor.presentation.menuCard
        let window = RateWindow(usedPercent: 0, windowMinutes: nil, resetsAt: nil, resetDescription: "detail")

        #expect(menuCard.extraRateWindowShowsResetDescriptionAsDetail(NamedRateWindow(
            id: "mistral-monthly-plan",
            title: "Monthly Plan",
            window: window)))
        #expect(!menuCard.extraRateWindowShowsResetDescriptionAsDetail(NamedRateWindow(
            id: "other-window",
            title: "Other",
            window: window)))
    }

    @Test
    func `normalizes repeated budgets and ignores unused PAYG metadata`() throws {
        let repeated = Self.apiOnlyRecord
            .replacingOccurrences(of: "eur", with: "EUR")
            .replacingOccurrences(of: ",\"payg_enabled\":true", with: "")
        let result = try MistralSubscriptionBudgetParser.parse(
            html: Self.flightPush(Self.apiOnlyRecord + repeated))
        #expect(result.api?.currencyCode == "EUR")

        let conflicting = repeated.replacingOccurrences(of: "25.5", with: "26.5")
        #expect(throws: MistralSubscriptionBudgetParser.ParseError.ambiguousBudgets) {
            try MistralSubscriptionBudgetParser.parse(html: Self.flightPush(Self.apiOnlyRecord + conflicting))
        }
    }

    @Test
    func `text and control records cannot supply allowance data`() throws {
        let text = "untrusted text 🦞\n" + Self.apiOnlyRecord
        let record = "3:T\(String(text.utf8.count, radix: 16)),\(text)"
        #expect(throws: MistralSubscriptionBudgetParser.ParseError.budgetNotFound) {
            try MistralSubscriptionBudgetParser.parse(html: Self.flightPush(record))
        }
        let result = try MistralSubscriptionBudgetParser.parse(html: Self.flightPush(record + Self.fullRecord))
        #expect(result.api?.usagePercentage == 2)

        #expect(throws: MistralSubscriptionBudgetParser.ParseError.budgetNotFound) {
            try MistralSubscriptionBudgetParser.parse(html: Self.flightPush("3:D" + Self.apiOnlyRecord.dropFirst(2)))
        }
        #expect(throws: MistralSubscriptionBudgetParser.ParseError.invalidRecord) {
            try MistralSubscriptionBudgetParser.parse(html: Self.flightPush("3:Tffff," + Self.fullRecord))
        }
    }

    @Test
    func `zero and malformed allowances preserve their valid sibling`() throws {
        let zeroAPI = try Self.budgetRecord(
            api: ["usage_percentage": 0, "initial_budget": 0, "currency": "EUR"],
            vibe: ["usage_percentage": 20, "initial_budget": 100, "currency": "EUR"])
        let budgets = try MistralSubscriptionBudgetParser.parse(html: Self.flightPush(zeroAPI))
        #expect(budgets.api == nil)
        #expect(budgets.vibe?.limit == 100)
        let snapshot = MistralWebFetchStrategy.attachSubscriptionBudgets(
            to: UsageSnapshot(primary: nil, secondary: nil, updatedAt: Date()), budgets: budgets)
        #expect(snapshot.primary == nil)
        #expect(snapshot.extraRateWindows?.first?.window.usedPercent == 20)

        let invalidVibe = try Self.budgetRecord(
            api: ["usage_percentage": 2, "initial_budget": 25.5, "currency": "EUR"],
            vibe: ["usage_percentage": "invalid", "initial_budget": 100, "currency": "EUR"])
        let partial = try MistralSubscriptionBudgetParser.parse(html: Self.flightPush(invalidVibe))
        #expect(partial.api?.limit == 25.5)
        #expect(partial.vibe == nil)
    }

    @Test
    func `derived spend stays finite without intermediate overflow`() throws {
        let finite = try Self.budgetRecord(
            api: ["usage_percentage": 100, "initial_budget": 1e308, "currency": "EUR"])
        let result = try MistralSubscriptionBudgetParser.parse(html: Self.flightPush(finite))
        #expect(result.api?.usedAmount == 1e308)
        let overflow = try Self.budgetRecord(
            api: ["usage_percentage": 200, "initial_budget": 1e308, "currency": "EUR"])
        #expect(throws: MistralSubscriptionBudgetParser.ParseError.budgetNotFound) {
            try MistralSubscriptionBudgetParser.parse(html: Self.flightPush(overflow))
        }
    }

    private static func budgetRecord(api: [String: Any], vibe: [String: Any]? = nil) throws -> String {
        var budgets = ["api_budget": api]
        budgets["vibe_budget"] = vibe
        let data = try JSONSerialization.data(withJSONObject: ["budget": budgets], options: .sortedKeys)
        let json = try #require(String(bytes: data, encoding: .utf8))
        return "7:\(json)\n"
    }
}
