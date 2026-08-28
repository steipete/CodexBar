#if canImport(JavaScriptCore)
import Foundation
import Testing
@testable import CodexBarCore

struct VenicePluginGoldenTests {
    @Test
    func `DIEM balance fixture matches the production golden`() async throws {
        let snapshot = try await Self.fetch("""
        {
          "canConsume": true,
          "consumptionCurrency": "DIEM",
          "balances": { "diem": 90.50, "usd": null },
          "diemEpochAllocation": 100.0
        }
        """)
        #expect(snapshot.primary?.usedPercent == 9.5)
        #expect(snapshot.primary?.resetDescription == "DIEM 90.50 / 100.00 epoch allocation")
    }

    @Test
    func `USD balance fixture matches the production golden`() async throws {
        let snapshot = try await Self.fetch("""
        {
          "canConsume": true,
          "consumptionCurrency": "USD",
          "balances": { "diem": null, "usd": 25.75 },
          "diemEpochAllocation": null
        }
        """)
        #expect(snapshot.primary?.usedPercent == 0)
        #expect(snapshot.primary?.resetDescription == "$25.75 USD remaining")
    }

    @Test
    func `string-encoded balances and allocation match the production golden`() async throws {
        let snapshot = try await Self.fetch("""
        {
          "canConsume": true,
          "consumptionCurrency": "DIEM",
          "balances": { "diem": "90.50", "usd": "25.75" },
          "diemEpochAllocation": "100.0"
        }
        """)
        #expect(snapshot.primary?.usedPercent == 9.5)
        #expect(snapshot.primary?.resetDescription == "DIEM 90.50 / 100.00 epoch allocation")
    }

    @Test
    func `bundled credits prefer DIEM allocation when both balances are present`() async throws {
        let snapshot = try await Self.fetch("""
        {
          "canConsume": true,
          "consumptionCurrency": "BUNDLED_CREDITS",
          "balances": { "diem": 50.0, "usd": 10.0 },
          "diemEpochAllocation": 100.0
        }
        """)
        #expect(snapshot.primary?.usedPercent == 50)
        #expect(snapshot.primary?.resetDescription == "DIEM 50.00 / 100.00 epoch allocation")
    }

    @Test
    func `USD currency wins when both balances are present`() async throws {
        let snapshot = try await Self.fetch("""
        {
          "canConsume": true,
          "consumptionCurrency": "USD",
          "balances": { "diem": 50.0, "usd": 12.34 },
          "diemEpochAllocation": 100.0
        }
        """)
        #expect(snapshot.primary?.usedPercent == 0)
        #expect(snapshot.primary?.resetDescription == "$12.34 USD remaining")
    }

    @Test
    func `non-consumable fixture is exhausted`() async throws {
        let snapshot = try await Self.fetch("""
        {
          "canConsume": false,
          "consumptionCurrency": "USD",
          "balances": { "diem": null, "usd": 100.0 },
          "diemEpochAllocation": null
        }
        """)
        #expect(snapshot.primary?.usedPercent == 100)
        #expect(snapshot.primary?.resetDescription == "Balance unavailable for API calls")
    }

    @Test
    func `DIEM allocation progress matches the production golden`() async throws {
        let snapshot = try await Self.fetch("""
        {
          "canConsume": true,
          "consumptionCurrency": "DIEM",
          "balances": { "diem": 75.0, "usd": null },
          "diemEpochAllocation": 100.0
        }
        """)
        #expect(snapshot.primary?.usedPercent == 25)
        #expect(snapshot.primary?.resetDescription == "DIEM 75.00 / 100.00 epoch allocation")
    }

    @Test
    func `DIEM without allocation matches the production golden`() async throws {
        let snapshot = try await Self.fetch("""
        {
          "canConsume": true,
          "consumptionCurrency": "DIEM",
          "balances": { "diem": 50.0, "usd": null },
          "diemEpochAllocation": null
        }
        """)
        #expect(snapshot.primary?.usedPercent == 0)
        #expect(snapshot.primary?.resetDescription == "DIEM 50.00 remaining")
    }

    @Test
    func `USD-only balance matches the production golden`() async throws {
        let snapshot = try await Self.fetch("""
        {
          "canConsume": true,
          "consumptionCurrency": "USD",
          "balances": { "diem": null, "usd": 15.50 },
          "diemEpochAllocation": null
        }
        """)
        #expect(snapshot.primary?.usedPercent == 0)
        #expect(snapshot.primary?.resetDescription == "$15.50 USD remaining")
    }

    @Test
    func `zero balances match the exhausted golden`() async throws {
        let snapshot = try await Self.fetch("""
        {
          "canConsume": true,
          "consumptionCurrency": "USD",
          "balances": { "diem": 0.0, "usd": 0.0 },
          "diemEpochAllocation": null
        }
        """)
        #expect(snapshot.primary?.usedPercent == 100)
        #expect(snapshot.primary?.resetDescription == "No Venice API balance available")
    }

    @Test
    func `null balances match the exhausted golden`() async throws {
        let snapshot = try await Self.fetch("""
        {
          "canConsume": true,
          "consumptionCurrency": null,
          "balances": { "diem": null, "usd": null },
          "diemEpochAllocation": null
        }
        """)
        #expect(snapshot.primary?.usedPercent == 100)
        #expect(snapshot.primary?.resetDescription == "No Venice API balance available")
    }

    @Test
    func `identity stays scoped to Venice`() async throws {
        let snapshot = try await Self.fetch("""
        {
          "canConsume": true,
          "consumptionCurrency": "DIEM",
          "balances": { "diem": 90.0, "usd": null },
          "diemEpochAllocation": 100.0
        }
        """)
        #expect(snapshot.identity?.providerID == .venice)
        #expect(snapshot.identity?.accountEmail == nil)
        #expect(snapshot.identity?.accountOrganization == nil)
        #expect(snapshot.identity?.loginMethod == nil)
    }

    @Test(arguments: [#"[{ "canConsume": true }]"#, "{ invalid json }"])
    func `malformed fixtures fail the JS contract`(_ body: String) async throws {
        let runtime = try ProviderPluginRuntime(
            bundledPlugin: "venice",
            transport: Self.transport(body: body))
        await #expect(throws: ProviderPluginError.self) {
            _ = try await runtime.fetchUsage(secrets: ["VENICE_API_KEY": "fixture-key"])
        }
    }

    @Test
    func `used percentage clamps to zero`() async throws {
        let snapshot = try await Self.fetch("""
        {
          "canConsume": true,
          "consumptionCurrency": "DIEM",
          "balances": { "diem": 150.0, "usd": null },
          "diemEpochAllocation": 100.0
        }
        """)
        #expect(snapshot.primary?.usedPercent == 0)
        #expect(snapshot.primary?.resetDescription == "DIEM 150.00 / 100.00 epoch allocation")
    }

    @Test
    func `plugin request uses the billing endpoint and bearer token`() async throws {
        let transport = ProviderHTTPTransportHandler { request in
            #expect(request.url?.absoluteString == "https://api.venice.ai/api/v1/billing/balance")
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer venice-test")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            return try Self.response(request: request, body: """
            {"canConsume":true,"consumptionCurrency":"USD","balances":{"diem":null,"usd":1},"diemEpochAllocation":null}
            """)
        }
        let runtime = try ProviderPluginRuntime(bundledPlugin: "venice", transport: transport)
        let snapshot = try await runtime.fetchUsage(secrets: ["VENICE_API_KEY": "venice-test"])
        #expect(snapshot.primary?.resetDescription == "$1.00 USD remaining")
    }

    private static func fetch(_ body: String) async throws -> UsageSnapshot {
        let runtime = try ProviderPluginRuntime(
            bundledPlugin: "venice",
            transport: Self.transport(body: body))
        return try await runtime.fetchUsage(secrets: ["VENICE_API_KEY": "fixture-key"])
    }

    private static func transport(body: String) -> ProviderHTTPTransportHandler {
        ProviderHTTPTransportHandler { request in
            try Self.response(request: request, body: body)
        }
    }

    private static func response(request: URLRequest, body: String) throws -> (Data, URLResponse) {
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]))
        return (Data(body.utf8), response)
    }
}
#endif
