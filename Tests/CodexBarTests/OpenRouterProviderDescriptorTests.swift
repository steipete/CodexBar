import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCLI
@testable import CodexBarCore

struct OpenRouterProviderDescriptorTests {
    @Test
    func `usage dashboard opens Activity rather than credit settings`() {
        #expect(OpenRouterProviderDescriptor.descriptor.metadata.dashboardURL == "https://openrouter.ai/activity")
    }

    @Test(arguments: BundledPluginTestSupport.engines, ["daily", "weekly", "monthly", ""])
    @MainActor
    func `capped keys retain one quota meter without relabeling lifetime spend`(
        engine: ProviderPluginEngineKind, reset: String) async throws
    {
        let snapshot = try await OpenRouterLimitTestSupport.snapshot(
            engine: engine,
            keyBody: """
            {"data":{"limit":30,"usage":20,"limit_reset":"\(reset)"}}
            """)
        #expect(try abs(#require(snapshot.primary?.usedPercent) - 2000.0 / 30) < 0.00001)
        #expect(snapshot.providerCost == nil)
        let model = try OpenRouterLimitTestSupport.model(snapshot, showSummary: true)
        #expect(model.metrics.count == 1)
        #expect(model.providerCost == nil)
        #expect(model.providerDetails.first { $0.title == "Credits" }?.rows
            .contains { $0.label == "Remaining" } == true)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `capped unknown usage remains unavailable`(engine: ProviderPluginEngineKind) async throws {
        let snapshot = try await OpenRouterLimitTestSupport.snapshot(
            engine: engine, keyBody: #"{"data":{"limit":30}}"#)
        #expect(snapshot.primary == nil)
        #expect(snapshot.providerCost == nil)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `uncapped spend preserves its reported period and optional account balance`(
        engine: ProviderPluginEngineKind) async throws
    {
        let monthly = try await OpenRouterLimitTestSupport.snapshot(
            engine: engine,
            keyBody: #"{"data":{"usage_monthly":12.50,"usage":90,"limit_reset":"daily"}}"#)
        let monthlyCost = try #require(monthly.providerCost)
        #expect(monthly.primary == nil)
        #expect(monthlyCost.used == 12.50)
        #expect(monthlyCost.limit == 0)
        #expect(monthlyCost.period == "This month (API key)")
        #expect(monthlyCost.balance == 1.90)

        let lifetime = try await OpenRouterLimitTestSupport.snapshot(
            engine: engine, keyBody: #"{"data":{"usage":20}}"#, creditsStatus: 403)
        let lifetimeCost = try #require(lifetime.providerCost)
        #expect(lifetimeCost.used == 20)
        #expect(lifetimeCost.period == "Total key usage")
        #expect(lifetimeCost.balance == nil)

        let creditsOnly = try await OpenRouterLimitTestSupport.snapshot(engine: engine, keyStatus: 503)
        let accountCost = try #require(creditsOnly.providerCost)
        #expect(accountCost.used == 3.10)
        #expect(accountCost.period == "Total account usage")
        #expect(accountCost.balance == 1.90)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `unavailable spend differs from a reported zero`(engine: ProviderPluginEngineKind) async throws {
        let missing = try await OpenRouterLimitTestSupport.snapshot(
            engine: engine, keyBody: #"{"data":{}}"#, creditsStatus: 403)
        #expect(missing.providerCost == nil)

        let zero = try await OpenRouterLimitTestSupport.snapshot(
            engine: engine, keyBody: #"{"data":{"usage_monthly":0}}"#, creditsStatus: 403)
        let cost = try #require(zero.providerCost)
        #expect(cost.used == 0)
        #expect(cost.period == "This month (API key)")
        #expect(cost.balance == nil)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    @MainActor
    func `visible summary replaces duplicate rows and hidden summary restores them`(
        engine: ProviderPluginEngineKind) async throws
    {
        let snapshot = try await OpenRouterLimitTestSupport.snapshot(
            engine: engine, keyBody: #"{"data":{"usage_daily":1.25,"usage_monthly":12.50}}"#)
        let model = try OpenRouterLimitTestSupport.model(snapshot, showSummary: true)
        let cost = try #require(model.providerCost)
        #expect(model.metrics.isEmpty)
        #expect(cost.spendLine == "This month (API key): $12.50")
        #expect(cost.balanceLine == "Balance: $1.90")
        #expect(cost.percentUsed == nil)
        let keyDetails = try #require(model.providerDetails.first { $0.title == "API key" })
        #expect(keyDetails.rows.contains { $0.label == "Today" })
        #expect(!keyDetails.rows.contains { $0.label == "This month" })
        #expect(keyDetails.chart?.points.count == 2)
        let creditDetails = try #require(model.providerDetails.first { $0.title == "Credits" })
        #expect(!creditDetails.rows.contains { $0.label == "Remaining" })
        #expect(creditDetails.rows.contains { $0.label == "Used" })

        let hidden = try OpenRouterLimitTestSupport.model(snapshot, showSummary: false)
        #expect(hidden.providerCost == nil)
        #expect(hidden.providerDetails.first { $0.title == "API key" }?.rows
            .contains { $0.label == "This month" } == true)
        #expect(hidden.providerDetails.first { $0.title == "Credits" }?.rows
            .contains { $0.label == "Remaining" } == true)

        let creditsOnly = try await OpenRouterLimitTestSupport.snapshot(engine: engine, keyStatus: 503)
        let accountModel = try OpenRouterLimitTestSupport.model(creditsOnly, showSummary: true)
        #expect(accountModel.providerCost?.spendLine == "Total account usage: $3.10")
        #expect(accountModel.providerDetails.first { $0.title == "Credits" }?.rows.map(\.label) == ["Total added"])
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `uncapped CLI keeps details without a zero dollar budget`(engine: ProviderPluginEngineKind) async throws {
        let snapshot = try await OpenRouterLimitTestSupport.snapshot(
            engine: engine, keyBody: #"{"data":{"usage_monthly":12.50}}"#)
        let text = CLIRenderer.renderText(
            provider: .openrouter,
            snapshot: snapshot,
            credits: nil,
            context: RenderContext(header: "OpenRouter", status: nil, useColor: false, resetStyle: .countdown),
            now: OpenRouterLimitTestSupport.now)
        #expect(text.contains("This month: $12.50"))
        #expect(text.contains("Remaining: $1.90"))
        #expect(!text.contains("Cost:"))
        let decoded = try JSONDecoder().decode(UsageSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded.providerCost?.used == 12.50)
        #expect(decoded.providerCost?.period == "This month (API key)")
        #expect(decoded.details == snapshot.details)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `management key counters do not represent account spend`(engine: ProviderPluginEngineKind) async throws {
        let snapshot = try await OpenRouterLimitTestSupport.snapshot(
            engine: engine,
            keyBody: #"{"data":{"is_management_key":true,"usage":0,"usage_monthly":0}}"#,
            activityBody: #"{"data":[]}"#)
        #expect(snapshot.providerCost == nil)
        #expect(snapshot.details.first { $0.title == "Credits" }?.rows.contains {
            $0.label == "Used" && $0.value == "$3.10"
        } == true)
    }
}
