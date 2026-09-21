import CodexBarCore
import Foundation
import Testing
@testable import CodexBarCLI

struct AntigravityCLICostTests {
    @Test(arguments: [1, 30])
    func `local token history shows each selected window once`(historyDays: Int) {
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: 198,
            sessionCostUSD: nil,
            last30DaysTokens: 198,
            last30DaysCostUSD: nil,
            historyDays: historyDays,
            daily: [],
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let text = CodexBarCLI.renderCostText(provider: .antigravity, snapshot: snapshot, useColor: false)
        let lines = text.split(separator: "\n")
        #expect(lines.filter { $0.hasPrefix("Today:") } == ["Today: 198 tokens"])
        #expect(lines.contains("Last 30 days: 198 tokens") == (historyDays == 30))
        #expect(text.contains("dollar costs unavailable"))
    }

    @Test
    func `priced local history shows an estimate and its billing scope`() {
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: 198,
            sessionCostUSD: 0.25,
            last30DaysTokens: 198,
            last30DaysCostUSD: 0.25,
            costProvenance: .listPriceEstimate,
            daily: [],
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let text = CodexBarCLI.renderCostText(provider: .antigravity, snapshot: snapshot, useColor: false)
        #expect(text.contains("Antigravity Cost (API-rate estimate)"))
        #expect(text.contains("Today: $0.25 · 198 tokens"))
        #expect(text.contains("not Antigravity charges or credits"))
        #expect(!text.contains("dollar costs unavailable"))
    }

    @Test
    func `priced partial local history names its recorded subtotal`() {
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: 198,
            sessionCostUSD: 0.25,
            last30DaysTokens: 198,
            last30DaysCostUSD: 0.25,
            historyCoverageIsEstablished: false,
            historyScanIsPartial: true,
            costProvenance: .listPriceEstimate,
            daily: [],
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000))

        let text = CodexBarCLI.renderCostText(provider: .antigravity, snapshot: snapshot, useColor: false)

        #expect(text.contains("Antigravity Cost (API-rate estimate)"))
        #expect(text.contains("Partial local history · recorded token subtotal"))
    }

    @Test
    func `priced history names recorded requests without a price`() {
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: 198,
            sessionCostUSD: 0.25,
            last30DaysTokens: 198,
            last30DaysCostUSD: 0.25,
            costProvenance: .listPriceEstimate,
            daily: [.init(
                date: "2026-07-15",
                inputTokens: nil,
                outputTokens: nil,
                totalTokens: 198,
                costUSD: 0.25,
                modelsUsed: nil,
                modelBreakdowns: nil,
                unpricedRequestCount: 1)],
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000))

        let text = CodexBarCLI.renderCostText(provider: .antigravity, snapshot: snapshot, useColor: false)

        #expect(text.contains("Partial estimate: 1 recorded request had no price."))
    }

    @Test
    func `local Antigravity history participates in explicit and combined cost selections`() {
        #expect(CodexBarCLI.costProviders(from: .single(.antigravity)) == [.antigravity])
        #expect(CodexBarCLI.costProviders(from: .custom([.codex, .antigravity])) == [.codex, .antigravity])
        #expect(CodexBarCLI.costProviders(from: .all).contains(.antigravity))
        #expect(CodexBarCLI.costSupportedProviderNames().contains("Antigravity"))
    }

    @Test(arguments: ["valid", "empty", "absent", "corrupt", "unsupported-time"])
    func `local cost transports preserve tokens unknown dollars and unavailable history`(source: String) async throws {
        let fixture = try AntigravityLocalFixture()
        switch source {
        case "valid":
            try fixture.database(blobs: [AntigravityLocalFixture.blob()])
        case "empty":
            try fixture.database()
        case "corrupt":
            let url = try fixture.database()
            try Data("not a database".utf8).write(to: url)
        case "unsupported-time":
            try fixture.database(blobs: [AntigravityLocalFixture.blob(seconds: nil)])
        default: break
        }
        let snapshot = try await fixture.snapshot()
        let providers = CodexBarCLI.costProviders(from: .single(.antigravity))
        let payloads = await CodexBarCLI.collectConfiguredCostPayloads(
            providers: providers,
            config: CodexBarConfig(providers: [ProviderConfig(id: .antigravity, enabled: true)]),
            context: ServeCostCollectionContext(
                configFingerprint: "antigravity-local-cost-fixture",
                providerTimeout: nil,
                requestDeadline: nil,
                now: { ContinuousClock().now },
                providerOperations: CLIServeOperationCoordinator()))
        { provider, header in
            #expect(provider == .antigravity)
            #expect(header == nil)
            return CodexBarCLI.makeCostPayload(
                provider: provider, snapshot: snapshot, error: nil, calendar: AntigravityLocalFixture.calendar)
        }
        let payload = try #require(payloads.first)
        #expect(payloads.count == 1)
        #expect(payload.provider == "antigravity")
        #expect(payload.source == "local")
        let established = source == "valid" || source == "empty"
        let expectedTokens: Int? = source == "empty" ? 0 : (source == "valid" ? 198 : nil)
        let expectedCost: Double? = source == "empty" ? 0 : nil
        #expect(payload.historyCoverageIsEstablished == established)
        #expect(payload.last30DaysTokens == expectedTokens)
        #expect(payload.last30DaysCostUSD == expectedCost)
        #expect(payload.provenance == "unknown")
        #expect(payload.error == nil)

        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])
        #expect(json["last30DaysTokens"] as? Int == expectedTokens)
        #expect(json["last30DaysCostUSD"] as? Double == expectedCost)
        let text = CodexBarCLI.renderCostText(provider: .antigravity, snapshot: snapshot, useColor: false)
        #expect(!text.contains("$0"))
        #expect(text.contains("Antigravity Token History"))
        #expect(!text.contains("API-rate estimate"))
        #expect(text.contains("dollar costs unavailable"))
        #expect(text.contains("Local token history is unavailable or incomplete.") == !established)
        #expect(text.contains("No token usage found in the selected period.") == (source == "empty"))
        if source == "valid" { #expect(text.contains("198")) }
    }
}
