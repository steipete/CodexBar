import CodexBarCore
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing

/// BigModel CN pay-as-you-go account balance, surfaced by the bundled zai plugin
/// as a best-effort detail row (endpoint verified against the live console API:
/// `GET www.bigmodel.cn/api/biz/account/query-customer-account-report`, which
/// accepts both `Bearer <key>` and raw-key Authorization).
struct ZaiPluginBalanceTests {
    @Test
    func `bigmodel CN snapshot renders account balance row`() async throws {
        let recorder = BalanceRequestRecorder()
        let snapshot = try await Self.fetch(
            region: "bigmodel-cn",
            balanceBody: """
            {
              "code": 200,
              "msg": "操作成功",
              "success": true,
              "data": {
                "balance": 42.5,
                "availableBalance": 40.0,
                "rechargeAmount": 100.0,
                "giveAmount": 20.0,
                "totalSpendAmount": 77.5,
                "frozenBalance": 2.5
              }
            }
            """,
            recorder: recorder)

        // availableBalance wins over balance; the secondary line summarizes spend provenance
        #expect(snapshot.detailRow(label: "Account balance")?.value == "¥40.00")
        #expect(
            snapshot.detailRow(label: "Account balance")?.secondaryValue
                == "recharged ¥100.00 · granted ¥20.00 · spent ¥77.50")
        let balanceRequest = try #require(await recorder.requests.first { $0.url?.host == "www.bigmodel.cn" })
        #expect(balanceRequest.url?.path == "/api/biz/account/query-customer-account-report")
    }

    @Test
    func `balance endpoint failure keeps quota snapshot intact`() async throws {
        let snapshot = try await Self.fetch(region: "bigmodel-cn", balanceBody: "{}", balanceStatus: 500)

        #expect(snapshot.primary?.usedPercent == 42)
        #expect(snapshot.detailRow(label: "Account balance") == nil)
    }

    @Test
    func `global region skips the balance request entirely`() async throws {
        let recorder = BalanceRequestRecorder()
        let snapshot = try await Self.fetch(region: "global", balanceBody: "{}", recorder: recorder)

        #expect(snapshot.primary?.usedPercent == 42)
        let balanceHostRequests = await recorder.requests.filter { $0.url?.host == "www.bigmodel.cn" }
        #expect(balanceHostRequests.isEmpty)
    }

    @Test
    func `router resolves CN balance default, explicit override, and nil for global`() {
        #expect(
            ZaiEndpointRouter.resolveBalanceURL(region: .bigmodelCN, environment: [:])
                == ZaiAPIRegion.bigmodelCN.balanceURL)
        #expect(ZaiEndpointRouter.resolveBalanceURL(region: .global, environment: [:]) == nil)
        let overridden = ZaiEndpointRouter.resolveBalanceURL(
            region: .bigmodelCN,
            environment: [ZaiSettingsReader.balanceURLKey: "https://balance-proxy.test/report"])
        #expect(overridden?.absoluteString == "https://balance-proxy.test/report")
    }

    // MARK: - Fixtures

    private static func fetch(
        region: String,
        balanceBody: String,
        balanceStatus: Int = 200,
        recorder: BalanceRequestRecorder? = nil) async throws -> UsageSnapshot
    {
        let runtime = try ProviderPluginRuntime(
            bundledPlugin: "zai",
            transport: ProviderHTTPTransportHandler { request in
                if let recorder {
                    await recorder.append(request)
                }
                let body = request.url?.host == "www.bigmodel.cn" ? balanceBody : Self.quotaFixture
                let status = request.url?.host == "www.bigmodel.cn" ? balanceStatus : 200
                return try Self.response(request: request, body: body, status: status)
            })
        return try await runtime.fetchUsage(
            settings: [
                "Z_AI_REGION": region,
                "Z_AI_USAGE_SCOPE": "personal",
                "Z_AI_QUOTA_ENDPOINT": "https://open.bigmodel.cn/api/monitor/usage/quota/limit",
                "Z_AI_MODEL_USAGE_ENDPOINT": "https://open.bigmodel.cn/api/monitor/usage/model-usage",
            ],
            secrets: [ZaiSettingsReader.apiTokenKey: "fixture-key"])
    }

    private static let quotaFixture = """
    {
      "code": 200,
      "success": true,
      "data": {
        "limits": [
          { "type": "TOKENS_LIMIT", "unit": 5, "number": 300, "percentage": 42,
            "usage": 1000, "remaining": 580, "nextResetTime": 1756000000 }
        ]
      }
    }
    """

    private static func response(request: URLRequest, body: String, status: Int) throws -> (Data, HTTPURLResponse) {
        let response = try #require(HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]))
        return (Data(body.utf8), response)
    }
}

private actor BalanceRequestRecorder {
    private(set) var requests: [URLRequest] = []

    func append(_ request: URLRequest) {
        self.requests.append(request)
    }
}
