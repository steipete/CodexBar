import Foundation
import Testing
@testable import CodexBarCore

struct AiAndBalancePluginTests {
    @Test(arguments: BundledPluginTestSupport.engines)
    func `settled wallet keeps exact decimal strings currency and negative balances`(
        engine: ProviderPluginEngineKind) async throws
    {
        for (balance, currency) in [
            ("42.75000000", "usd"),
            ("123.45678901", "jpy"),
            ("-0.00000001", "usd"),
            ("9007199254740993.12345678", "usd"),
            ("0", "jpy"),
            (String(repeating: "1", count: 116), "usd"),
        ] {
            let transport = AiAndBalanceFixtureTransport(balance: balance, currency: currency)
            let usage = try await Self.fetch(engine, transport: transport)
            #expect(usage.detailRow(label: "Settled wallet balance")?.value == "\(balance) \(currency.uppercased())")
            #expect(usage.details.first?.title == "Organization wallet")
            #expect(usage.providerCost?.used == 2.5)
            #expect(usage.providerCost?.currencyCode == "USD")
            #expect(usage.providerCost?.period == "Last 30 days")
            #expect(usage.dataConfidence == .exact)
            #expect(await transport.paths.sorted() == ["/billing/balance", "/logs"])
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `failed optional balance cannot erase log spend`(engine: ProviderPluginEngineKind) async throws {
        for status in [401, 403, 429, 503] {
            let usage = try await Self.fetch(engine, transport: AiAndBalanceFixtureTransport(status: status))
            #expect(usage.detailRow(label: "Settled wallet balance") == nil)
            #expect(usage.providerCost?.used == 2.5)
            #expect(usage.dataConfidence == .exact)
        }
        let usage = try await Self.fetch(engine, transport: AiAndBalanceFixtureTransport(transportFailure: true))
        #expect(usage.providerCost?.used == 2.5)
        #expect(usage.details.isEmpty)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `malformed optional wallet is unavailable rather than zero`(engine: ProviderPluginEngineKind) async throws {
        for raw in [
            "not-json",
            "{}",
            #"{"balance":1,"currency":"usd"}"#,
            #"{"balance":"NaN","currency":"usd"}"#,
            #"{"balance":"1","currency":"eur"}"#,
        ] {
            let usage = try await Self.fetch(engine, transport: AiAndBalanceFixtureTransport(raw: raw))
            #expect(usage.providerCost?.used == 2.5)
            #expect(usage.details.isEmpty)
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `overlong optional decimals cannot invalidate the native snapshot`(
        engine: ProviderPluginEngineKind) async throws
    {
        for count in [117, 300] {
            let usage = try await Self.fetch(engine, transport: AiAndBalanceFixtureTransport(
                balance: String(repeating: "1", count: count)))
            #expect(usage.details.isEmpty)
            #expect(usage.providerCost?.used == 2.5)
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `wallet is fetched once while logs retain both cursors and all pages`(
        engine: ProviderPluginEngineKind) async throws
    {
        let transport = AiAndBalanceFixtureTransport(paginated: true)
        let usage = try await Self.fetch(engine, transport: transport)
        #expect(usage.providerCost?.used == 5)
        #expect(usage.providerCost?.period == "Last 30 days")
        #expect(await transport.paths.filter { $0 == "/billing/balance" }.count == 1)
        #expect(await transport.paths.filter { $0 == "/logs" }.count == 2)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `settled wallet remains distinct when log window has no cost rows`(
        engine: ProviderPluginEngineKind) async throws
    {
        let usage = try await Self.fetch(engine, transport: AiAndBalanceFixtureTransport(emptyLogs: true))
        #expect(usage.providerCost == nil)
        #expect(usage.detailRow(label: "Settled wallet balance")?.value == "42.75000000 USD")
        #expect(usage.primary == nil)
    }

    private static func fetch(
        _ engine: ProviderPluginEngineKind,
        transport: any ProviderHTTPTransport) async throws -> UsageSnapshot
    {
        let runtime = try BundledPluginTestSupport.runtime("aiand", engine: engine, transport: transport)
        return try await runtime.fetchUsage(secrets: ["AIAND_API_KEY": "fixture-key"])
    }
}

private actor AiAndBalanceFixtureTransport: ProviderHTTPTransport {
    var balance = "42.75000000"
    var currency = "usd"
    var status = 200
    var transportFailure = false
    var raw: String?
    var paginated = false
    var emptyLogs = false
    private(set) var paths: [String] = []

    init(
        balance: String = "42.75000000",
        currency: String = "usd",
        status: Int = 200,
        transportFailure: Bool = false,
        raw: String? = nil,
        paginated: Bool = false,
        emptyLogs: Bool = false)
    {
        self.balance = balance
        self.currency = currency
        self.status = status
        self.transportFailure = transportFailure
        self.raw = raw
        self.paginated = paginated
        self.emptyLogs = emptyLogs
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = try #require(request.url)
        #expect(url.host == "api.aiand.com")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
        self.paths.append(url.path)
        let body: String
        let code: Int
        if url.path == "/billing/balance" {
            if self.transportFailure { throw URLError(.timedOut) }
            code = self.status
            body = self.raw ?? "{\"balance\":\"\(self.balance)\",\"currency\":\"\(self.currency)\"}"
        } else {
            #expect(url.path == "/logs")
            let next = url.query?.contains("after=") == true
            #expect(url.query?.contains("range=30days") == true)
            if next { #expect(url.query?.contains("after_id=fixture-id") == true) }
            code = 200
            if self.emptyLogs {
                body = #"{"data":[],"has_more":false}"#
            } else if self.paginated, !next {
                body = #"""
                {"data":[{"cost":"2.50000000","currency":"usd"}],"has_more":true,
                 "next_after":"fixture-time","next_after_id":"fixture-id"}
                """#
            } else {
                body = #"{"data":[{"cost":"2.50000000","currency":"usd"}],"has_more":false}"#
            }
        }
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!)
    }
}
