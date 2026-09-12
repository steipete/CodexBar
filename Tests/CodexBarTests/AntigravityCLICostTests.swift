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
