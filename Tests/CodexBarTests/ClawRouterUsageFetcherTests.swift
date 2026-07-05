import CodexBarCore
import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCLI

struct ClawRouterUsageFetcherTests {
    @Test
    func `parses monthly budget and provider agnostic usage`() throws {
        let parsed = try ClawRouterUsageFetcher._parseSnapshotForTesting(
            Data(Self.budgetedResponse.utf8),
            updatedAt: Date(timeIntervalSince1970: 1))

        #expect(parsed.budgetLimitUSD == 25)
        #expect(parsed.budgetSpentUSD == 0.006)
        #expect(parsed.budgetRemainingUSD == 24.994)
        #expect(parsed.requestCount == 6)
        #expect(parsed.totalTokens == 54191)
        #expect(parsed.providers.map(\.provider) == ["openai", "anthropic"])

        let snapshot = parsed.toUsageSnapshot()
        #expect(snapshot.identity?.providerID == .clawrouter)
        #expect(snapshot.primary?.usedPercent == 0.024)
        #expect(snapshot.secondary == nil)
        #expect(snapshot.providerCost?.used == 0.006)
        #expect(snapshot.providerCost?.limit == 25)
        #expect(snapshot.clawRouterUsage?.providers.map(\.provider) == ["openai", "anthropic"])
        #expect(snapshot.dataConfidence == .exact)

        let reset = try #require(snapshot.primary?.resetsAt)
        let expected = try #require(DateComponents(
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(secondsFromGMT: 0),
            year: 2026,
            month: 8,
            day: 1).date)
        #expect(reset == expected)
    }

    @Test
    func `supports unmetered policies and arbitrary providers`() throws {
        let parsed = try ClawRouterUsageFetcher._parseSnapshotForTesting(
            Data(Self.unmeteredResponse.utf8),
            updatedAt: Date(timeIntervalSince1970: 1))
        let snapshot = parsed.toUsageSnapshot()

        #expect(!parsed.budgetConfigured)
        #expect(parsed.providers.map(\.provider) == ["replicate", "tavily"])
        #expect(snapshot.primary == nil)
        #expect(snapshot.identity?.loginMethod == "Unmetered")
        #expect(snapshot.providerCost?.used == 1.25)
        #expect(snapshot.providerCost?.limit == 0)
    }

    @Test
    func `usage URL accepts root and versioned base URLs`() throws {
        #expect(
            try ClawRouterUsageFetcher._usageURLForTesting(
                baseURL: #require(URL(string: "https://router.example.com"))).absoluteString ==
                "https://router.example.com/v1/usage")
        #expect(
            try ClawRouterUsageFetcher._usageURLForTesting(
                baseURL: #require(URL(string: "https://router.example.com/v1"))).absoluteString ==
                "https://router.example.com/v1/usage")
    }

    @Test
    func `fetch sends bearer key and maps authorization failure`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            #expect(request.url?.absoluteString == "https://router.example.com/v1/usage")
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer smoke-key")
            let response = try #require(HTTPURLResponse(
                url: request.url!,
                statusCode: 401,
                httpVersion: nil,
                headerFields: nil))
            return (Data(), response)
        }

        await #expect(throws: ClawRouterUsageError.invalidCredentials) {
            _ = try await ClawRouterUsageFetcher.fetchUsage(
                apiKey: "smoke-key",
                baseURL: #require(URL(string: "https://router.example.com")),
                transport: transport)
        }
    }

    @Test
    func `config projects API key and optional base URL`() {
        let config = ProviderConfig(
            id: .clawrouter,
            apiKey: "router-token",
            enterpriseHost: "https://router.example.com")
        let environment = ProviderConfigEnvironment.applyProviderConfigOverrides(
            base: [:],
            provider: .clawrouter,
            config: config)

        #expect(environment[ClawRouterSettingsReader.apiKeyEnvironmentKey] == "router-token")
        #expect(environment[ClawRouterSettingsReader.baseURLEnvironmentKey] == "https://router.example.com")
        #expect(ProviderTokenResolver.clawRouterToken(environment: environment) == "router-token")
    }

    @Test
    func `endpoint override is HTTPS only`() throws {
        let key = ClawRouterSettingsReader.baseURLEnvironmentKey
        try ClawRouterSettingsReader.validateEndpointOverride(environment: [key: "router.example.com/v1"])
        #expect(ClawRouterSettingsReader.baseURL(environment: [key: "router.example.com/v1"]).absoluteString ==
            "https://router.example.com/v1")
        #expect(throws: ClawRouterSettingsError.invalidEndpointOverride(key)) {
            try ClawRouterSettingsReader.validateEndpointOverride(environment: [key: "http://router.example.com"])
        }
    }

    @Test
    @MainActor
    func `descriptor and settings are registered`() throws {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .clawrouter)
        #expect(descriptor.metadata.displayName == "ClawRouter")
        #expect(descriptor.cli.aliases.contains("claw-router"))

        let implementation = try #require(ProviderImplementationRegistry.implementation(for: .clawrouter))
        #expect(implementation.id == .clawrouter)
    }

    @Test
    func `usage snapshot preserves ClawRouter detail when cached`() throws {
        let parsed = try ClawRouterUsageFetcher._parseSnapshotForTesting(
            Data(Self.budgetedResponse.utf8),
            updatedAt: Date(timeIntervalSince1970: 1))
        let encoded = try JSONEncoder().encode(parsed.toUsageSnapshot())
        let decoded = try JSONDecoder().decode(UsageSnapshot.self, from: encoded)

        #expect(decoded.clawRouterUsage == parsed)
        #expect(decoded.identity?.providerID == .clawrouter)
    }

    @Test
    func `text CLI renders budgeted spend and routed usage`() throws {
        let parsed = try ClawRouterUsageFetcher._parseSnapshotForTesting(
            Data(Self.budgetedResponse.utf8),
            updatedAt: Date(timeIntervalSince1970: 1))

        let output = Self.renderText(parsed.toUsageSnapshot())

        #expect(output.contains("Spend: $0.01 / $25.00"))
        #expect(output.contains("Usage: 6 requests · 54K tokens"))
        #expect(output.contains("Results: 5 succeeded · 1 failed"))
        #expect(output.contains("Routed providers: openai: 4 · anthropic: 2"))
    }

    @Test
    func `text CLI renders unmetered and zero spend without a zero limit`() throws {
        let unmetered = try ClawRouterUsageFetcher._parseSnapshotForTesting(
            Data(Self.unmeteredResponse.utf8),
            updatedAt: Date(timeIntervalSince1970: 1))
        let zeroSpend = try ClawRouterUsageFetcher._parseSnapshotForTesting(
            Data(Self.unmeteredResponse.replacingOccurrences(of: "1250000", with: "0").utf8),
            updatedAt: Date(timeIntervalSince1970: 1))

        let unmeteredOutput = Self.renderText(unmetered.toUsageSnapshot())
        let zeroSpendOutput = Self.renderText(zeroSpend.toUsageSnapshot())

        #expect(unmeteredOutput.contains("Spend: $1.25"))
        #expect(unmeteredOutput.contains("Usage: 3 requests · 0 tokens"))
        #expect(!unmeteredOutput.contains(" / 0.0"))
        #expect(zeroSpendOutput.contains("Spend: $0.00"))
        #expect(zeroSpendOutput.contains("Usage: 3 requests · 0 tokens"))
        #expect(!zeroSpendOutput.contains(" / 0.0"))
    }

    private static func renderText(_ snapshot: UsageSnapshot) -> String {
        CLIRenderer.renderText(
            provider: .clawrouter,
            snapshot: snapshot,
            credits: nil,
            context: RenderContext(
                header: "ClawRouter (api)",
                status: nil,
                useColor: false,
                resetStyle: .countdown))
    }

    private static let budgetedResponse = """
    {
      "policyId": "openclaw-smoke",
      "budget": {
        "configured": true,
        "ledger": "durable_object",
        "windowKey": "openclaw/openclaw-smoke/2026-07",
        "limitMicros": 25000000,
        "spentMicros": 6000,
        "remainingMicros": 24994000
      },
      "usage": {
        "ledger": "ready",
        "summary": {
          "requestCount": 6,
          "successCount": 5,
          "errorCount": 1,
          "inputTokens": 50000,
          "outputTokens": 4191,
          "totalTokens": 54191,
          "actualCostMicros": 6000
        },
        "providers": [
          {
            "provider": "anthropic",
            "requestCount": 2,
            "successCount": 2,
            "errorCount": 0,
            "totalTokens": 12191,
            "actualCostMicros": 2000
          },
          {
            "provider": "openai",
            "requestCount": 4,
            "successCount": 3,
            "errorCount": 1,
            "totalTokens": 42000,
            "actualCostMicros": 4000
          }
        ],
        "events": []
      }
    }
    """

    private static let unmeteredResponse = """
    {
      "policyId": "any-provider-policy",
      "budget": {
        "configured": false,
        "ledger": "unmetered",
        "windowKey": null,
        "limitMicros": null,
        "spentMicros": null,
        "remainingMicros": null
      },
      "usage": {
        "ledger": "ready",
        "summary": {
          "requestCount": 3,
          "successCount": 3,
          "errorCount": 0,
          "inputTokens": 0,
          "outputTokens": 0,
          "totalTokens": 0,
          "actualCostMicros": 1250000
        },
        "providers": [
          {
            "provider": "tavily",
            "requestCount": 2,
            "successCount": 2,
            "errorCount": 0,
            "totalTokens": 0,
            "actualCostMicros": 250000
          },
          {
            "provider": "replicate",
            "requestCount": 1,
            "successCount": 1,
            "errorCount": 0,
            "totalTokens": 0,
            "actualCostMicros": 1000000
          }
        ],
        "events": []
      }
    }
    """
}
