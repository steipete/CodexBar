#if canImport(JavaScriptCore)
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCLI

struct ClawRouterPluginGoldenTests {
    @Test
    func `monthly budget fixture matches the production golden`() async throws {
        let snapshot = try await Self.fetch(body: Self.budgetedResponse, now: Date(timeIntervalSince1970: 1))

        #expect(snapshot.identity?.providerID == .clawrouter)
        #expect(snapshot.primary?.usedPercent == 0.024)
        #expect(snapshot.secondary == nil)
        #expect(snapshot.providerCost?.used == 0.006)
        #expect(snapshot.providerCost?.limit == 25)
        #expect(snapshot.details.last?.rows.map(\.label) == ["openai", "anthropic"])
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
    func `unmetered fixture keeps arbitrary providers and spend`() async throws {
        let snapshot = try await Self.fetch(body: Self.unmeteredResponse)

        #expect(snapshot.primary == nil)
        #expect(snapshot.identity?.loginMethod == "Unmetered")
        #expect(snapshot.providerCost?.used == 1.25)
        #expect(snapshot.providerCost?.limit == 0)
        #expect(snapshot.details.last?.rows.map(\.label) == ["replicate", "tavily"])
    }

    @Test(arguments: [false, true])
    func `root and versioned base URLs reach the same usage path`(versioned: Bool) async throws {
        let recorder = ClawRouterRequestRecorder()
        let runtime = try ProviderPluginRuntime(
            bundledPlugin: "clawrouter",
            transport: Self.transport(body: Self.budgetedResponse, recorder: recorder))
        let base = versioned ? "https://router.example.com/v1" : "https://router.example.com"

        _ = try await runtime.fetchUsage(
            settings: [ClawRouterSettingsReader.baseURLEnvironmentKey: base],
            secrets: [ClawRouterSettingsReader.apiKeyEnvironmentKey: "smoke-key"])

        let request = try #require(await recorder.requests.first)
        #expect(request.url?.absoluteString == "https://router.example.com/v1/usage")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer smoke-key")
    }

    @Test(arguments: [
        (401, ProviderFetchClassifiedError.Kind.authenticationExpired),
        (403, .authenticationExpired),
        (429, .rateLimited),
        (500, .providerUnavailable),
        (400, .apiFailure),
    ])
    func `HTTP failures preserve classified surface`(
        status: Int,
        kind: ProviderFetchClassifiedError.Kind) async throws
    {
        do {
            _ = try await Self.fetch(body: "not-json", status: status)
            Issue.record("Expected classified failure")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == kind)
            if status == 401 || status == 403 {
                #expect(error.message == "ClawRouter rejected the API key. Check the key and its policy status.")
            } else {
                #expect(error.message == "ClawRouter API returned HTTP \(status).")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test(arguments: ["not-json", #"{"budget":{}}"#])
    func `malformed responses are classified parse failures`(body: String) async throws {
        do {
            _ = try await Self.fetch(body: body)
            Issue.record("Expected parse failure")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == .parseFailure)
        } catch {
            Issue.record("Unexpected error: \(error)")
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
    func `usage snapshot preserves ClawRouter detail when cached`() async throws {
        let snapshot = try await Self.fetch(body: Self.budgetedResponse, now: Date(timeIntervalSince1970: 1))
        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(UsageSnapshot.self, from: encoded)

        #expect(decoded.details == snapshot.details)
        #expect(decoded.identity?.providerID == .clawrouter)
    }

    @Test
    func `text CLI renders budgeted spend and routed usage`() async throws {
        let snapshot = try await Self.fetch(body: Self.budgetedResponse, now: Date(timeIntervalSince1970: 1))
        let output = Self.renderText(snapshot)

        #expect(output.contains("Requests: 6 · 5 succeeded · 1 failed"))
        #expect(output.contains("Tokens: 54191 · 50000 input · 4191 output"))
        #expect(output.contains("Monthly budget: $0.006000 / $25.00 · $24.994000 remaining"))
        #expect(output.contains("openai: 4 requests · $0.004000 · 42000 tokens"))
        #expect(output.contains("anthropic: 2 requests · $0.002000 · 12191 tokens"))
    }

    @Test
    func `text CLI renders unmetered and zero spend without a zero limit`() async throws {
        let unmetered = try await Self.fetch(body: Self.unmeteredResponse)
        let zeroSpend = try await Self.fetch(
            body: Self.unmeteredResponse.replacingOccurrences(of: "1250000", with: "0"))

        let unmeteredOutput = Self.renderText(unmetered)
        let zeroSpendOutput = Self.renderText(zeroSpend)

        #expect(unmeteredOutput.contains("Actual cost: $1.250000"))
        #expect(unmeteredOutput.contains("Requests: 3 · 3 succeeded · 0 failed"))
        #expect(!unmeteredOutput.contains(" / 0.0"))
        #expect(zeroSpendOutput.contains("Actual cost: $0.000000"))
        #expect(zeroSpendOutput.contains("Requests: 3 · 3 succeeded · 0 failed"))
        #expect(!zeroSpendOutput.contains(" / 0.0"))
    }

    private static func fetch(
        body: String,
        status: Int = 200,
        now: Date = Date(timeIntervalSince1970: 1)) async throws -> UsageSnapshot
    {
        let runtime = try ProviderPluginRuntime(
            bundledPlugin: "clawrouter",
            transport: Self.transport(body: body, status: status))
        return try await runtime.fetchUsage(
            settings: [ClawRouterSettingsReader.baseURLEnvironmentKey: "https://clawrouter.openclaw.ai"],
            secrets: [ClawRouterSettingsReader.apiKeyEnvironmentKey: "fixture-key"],
            now: now)
    }

    private static func transport(
        body: String,
        status: Int = 200,
        recorder: ClawRouterRequestRecorder? = nil) -> ProviderHTTPTransportHandler
    {
        ProviderHTTPTransportHandler { request in
            if let recorder {
                await recorder.append(request)
            }
            let response = try #require(HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]))
            return (Data(body.utf8), response)
        }
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

private actor ClawRouterRequestRecorder {
    private(set) var requests: [URLRequest] = []

    func append(_ request: URLRequest) {
        self.requests.append(request)
    }
}
#endif
