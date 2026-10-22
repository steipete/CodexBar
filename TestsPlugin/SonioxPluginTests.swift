import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct SonioxPluginTests {
    private static let balance = #"{"available_balance_usd":"18.50","invoice_billing_enabled":false}"#
    private static let monthly = #"{"month":"2026-10","usage_usd":"6.00","monthly_budget_usd":"100.00"}"#

    @Test(arguments: BundledPluginTestSupport.engines)
    func `organization billing separates prepaid balance from monthly budget`(
        engine: ProviderPluginEngineKind) async throws
    {
        let usage = try await Self.fetch(engine)
        let window = try #require(usage.primary)
        #expect(window.usedPercent == 6)
        #expect(window.resetDescription == "$6.00 / $100.00")
        #expect(window.resetsAt == ISO8601DateFormatter().date(from: "2026-11-01T00:00:00Z"))
        #expect(usage.providerCost?.used == 6)
        #expect(usage.providerCost?.limit == 100)
        #expect(usage.providerCost?.balance == 18.5)
        #expect(usage.providerCost?.currencyCode == "USD")
        #expect(usage.providerCost?.period == "This month")
        #expect(usage.providerCost?.resetsAt == window.resetsAt)
        #expect(usage.detailRow(label: "Prepaid")?.value == "USD")
        #expect(usage.secondary == nil)
        #expect(usage.identity == nil)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `invoice billing does not present zero prepaid credits as exhausted`(
        engine: ProviderPluginEngineKind) async throws
    {
        let usage = try await Self.fetch(
            engine, balance: #"{"available_balance_usd":"0","invoice_billing_enabled":true}"#)
        #expect(usage.primary?.usedPercent == 6)
        #expect(usage.providerCost?.used == 6)
        #expect(usage.providerCost?.balance == nil)
        #expect(usage.detailRow(label: "Invoice billing")?.value == "USD")
    }

    @Test(arguments: ["0", "0.001", "-0.50"], BundledPluginTestSupport.engines)
    func `prepaid balances preserve zero subcent and negative amounts`(
        amount: String, engine: ProviderPluginEngineKind) async throws
    {
        let usage = try await Self.fetch(
            engine, balance: "{\"available_balance_usd\":\"\(amount)\",\"invoice_billing_enabled\":false}")
        #expect(usage.providerCost?.balance == Double(amount))
        #expect(usage.primary?.usedPercent == 6)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `zero and exceeded budgets retain spend without inventing a denominator`(
        engine: ProviderPluginEngineKind) async throws
    {
        let zero = try await Self.fetch(
            engine, monthly: #"{"month":"2026-10","usage_usd":"0","monthly_budget_usd":"0"}"#)
        #expect(zero.primary == nil)
        #expect(zero.providerCost?.used == 0)
        #expect(zero.providerCost?.limit == 0)
        #expect(zero.detailRow(label: "Monthly budget")?.value == "$0.00")
        let exceeded = try await Self.fetch(
            engine, monthly: #"{"month":"2026-10","usage_usd":"100.25","monthly_budget_usd":"100"}"#)
        #expect(exceeded.primary?.usedPercent == 100)
        #expect(exceeded.providerCost?.used == 100.25)
    }

    @Test(arguments: ["2026-12", "2028-02"], BundledPluginTestSupport.engines)
    func `reset uses the reported UTC month including year and leap boundaries`(
        month: String, engine: ProviderPluginEngineKind) async throws
    {
        let usage = try await Self.fetch(
            engine, monthly: "{\"month\":\"\(month)\",\"usage_usd\":\"0\",\"monthly_budget_usd\":\"100\"}")
        let expected = month == "2026-12" ? "2027-01-01T00:00:00Z" : "2028-03-01T00:00:00Z"
        #expect(usage.primary?.resetsAt == ISO8601DateFormatter().date(from: expected))
    }

    @Test(arguments: [
        ("balance", "not-json"),
        ("balance", "[]"),
        ("balance", #"{"available_balance_usd":18.5,"invoice_billing_enabled":false}"#),
        ("balance", #"{"available_balance_usd":"","invoice_billing_enabled":false}"#),
        ("balance", #"{"available_balance_usd":"NaN","invoice_billing_enabled":false}"#),
        ("balance", #"{"available_balance_usd":"18.5","invoice_billing_enabled":"false"}"#),
        ("usage/monthly", "{}"),
        ("usage/monthly", #"{"month":"2026-10","usage_usd":"-1","monthly_budget_usd":"100"}"#),
        ("usage/monthly", #"{"month":"2026-10","usage_usd":"6","monthly_budget_usd":null}"#),
        ("usage/monthly", #"{"month":"2026-13","usage_usd":"6","monthly_budget_usd":"100"}"#),
    ], BundledPluginTestSupport.engines)
    func `malformed billing is rejected rather than reported as zero usage`(
        fixture: (String, String), engine: ProviderPluginEngineKind) async
    {
        await #expect {
            try await Self.fetch(
                engine,
                balance: fixture.0 == "balance" ? fixture.1 : Self.balance,
                monthly: fixture.0 == "usage/monthly" ? fixture.1 : Self.monthly)
        } throws: { error in
            (error as? ProviderFetchClassifiedError)?.kind == .parseFailure &&
                error.localizedDescription.contains("Refresh to try again") &&
                error.localizedDescription.contains("update CodexBar or report the issue")
        }
    }

    @Test(arguments: [401, 403, 429, 500, 400, 404], BundledPluginTestSupport.engines)
    func `HTTP failures are classified without exposing response bodies`(
        status: Int, engine: ProviderPluginEngineKind) async
    {
        let kind: ProviderFetchClassifiedError.Kind = switch status {
        case 401: .authenticationExpired
        case 403: .permissionDenied
        case 429: .rateLimited
        case 500: .providerUnavailable
        default: .apiFailure
        }
        let recovery = switch status {
        case 401, 403: ""
        case 429: "Wait a moment, then refresh"
        case 500: "Try again later or check https://status.soniox.com"
        default: "Refresh to try again. If this persists, update CodexBar or report the issue"
        }
        for path in ["balance", "usage/monthly"] {
            await #expect {
                try await Self.fetch(engine, failurePath: path, status: status)
            } throws: { error in
                (error as? ProviderFetchClassifiedError)?.kind == kind &&
                    (recovery.isEmpty || error.localizedDescription.contains(recovery)) &&
                    !error.localizedDescription.contains("private-response-marker")
            }
        }
    }

    @Test
    func `standard credentials project the organization key and advertise API sources`() throws {
        let descriptor = SonioxProviderDescriptor.descriptor
        let credentials = try #require(descriptor.credentials)
        let config = ProviderConfig(id: .soniox, apiKey: "snx_org_fixture")
        let environment = credentials.applyConfig(base: [:], config: config)
        #expect(environment["SONIOX_ORG_API_KEY"] == "snx_org_fixture")
        #expect(credentials.resolveToken(environment: environment)?.token == "snx_org_fixture")
        #expect(credentials.resolveToken(environment: ["SONIOX_API_KEY": "project-fixture"]) == nil)
        #expect(descriptor.fetchPlan.sourceModes == [.auto, .api])
    }

    private static func fetch(
        _ engine: ProviderPluginEngineKind,
        balance: String = Self.balance,
        monthly: String = Self.monthly,
        failurePath: String? = nil,
        status: Int = 200) async throws -> UsageSnapshot
    {
        let transport = ProviderHTTPTransportHandler { request in
            let url = try #require(request.url)
            #expect(url.scheme == "https")
            #expect(url.host == "api.soniox.com")
            #expect(["/v1/organization/balance", "/v1/organization/usage/monthly"].contains(url.path))
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer snx_org_fixture")
            #expect(request.timeoutInterval == 15)
            let path = String(url.path.dropFirst("/v1/organization/".count))
            let body: String = switch path {
            case "balance": balance
            case "usage/monthly": monthly
            default: throw URLError(.badURL)
            }
            let failed = path == failurePath
            let response = try #require(HTTPURLResponse(
                url: url, statusCode: failed ? status : 200, httpVersion: nil, headerFields: nil))
            return (Data((failed ? "private-response-marker" : body).utf8), response)
        }
        let runtime = try BundledPluginTestSupport.runtime("soniox", engine: engine, transport: transport)
        return try await runtime.fetchUsage(secrets: ["SONIOX_ORG_API_KEY": "snx_org_fixture"])
    }
}
