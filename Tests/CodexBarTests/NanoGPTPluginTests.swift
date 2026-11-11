import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct NanoGPTPluginTests {
    /// 2026-03-17T12:00:00Z: the usage window covers the UTC month to date.
    static let now = Date(timeIntervalSince1970: 1_773_748_800)

    /// Documented `GET /api/subscription/v1/usage` shape with synthetic counters.
    /// https://docs.nano-gpt.com/api-reference/endpoint/subscription-usage
    static let subscription = #"""
    {"active":true,"state":"active",
     "limits":{"dailyInputTokens":1000000,"weeklyInputTokens":4000000,"dailyImages":200},
     "dailyInputTokens":{"used":150000,"remaining":850000,"percentUsed":0.15,"resetAt":1773800000000},
     "weeklyInputTokens":{"used":900000,"remaining":3100000,"percentUsed":0.225,"resetAt":1774300000000},
     "dailyImages":{"used":50,"remaining":150,"percentUsed":0.25,"resetAt":1773800000000},
     "period":{"currentPeriodEnd":"2026-04-01T00:00:00Z"},
     "routing":{"recommendedMode":"subscription","reason":"Quota remains.","subscriptionQuotaAvailable":true,
      "paidSpendPolicyAllowsBalance":true}}
    """#

    /// Documented `POST /api/check-balance` shape. https://docs.nano-gpt.com/api-reference/endpoint/check-balance
    static let balance = #"{"usd_balance":"12.5","nano_balance":"1.25"}"#

    /// Documented `GET /api/v1/usage` shape. https://docs.nano-gpt.com/api-reference/endpoint/usage
    static let usage = #"""
    {"object":"usage","from":"2026-03-01","to":"2026-03-17","timezone":"UTC",
     "totals":{"requests":12,"costUsd":1.5,"refundedUsd":0,"netCostUsd":1.5,"inputTokens":9000,
      "outputTokens":4000,"totalTokens":13000},
     "byDay":[{"date":"2026-03-16","requests":7,"netCostUsd":1.0,"totalTokens":10000},
      {"date":"2026-03-17","requests":5,"netCostUsd":0.5,"totalTokens":3000}]}
    """#

    @Test(arguments: BundledPluginTestSupport.engines)
    func `subscription lanes drive windows balance and month to date spend`(
        engine: ProviderPluginEngineKind) async throws
    {
        let snapshot = try await Self.fetch(engine: engine)
        #expect(snapshot.primary?.usedPercent == 15)
        #expect(snapshot.primary?.windowMinutes == 1440)
        #expect(snapshot.primary?.title == "Daily input tokens")
        #expect(snapshot.primary?.resetsAt == Date(timeIntervalSince1970: 1_773_800_000))
        #expect(snapshot.secondary?.usedPercent == 22.5)
        #expect(snapshot.secondary?.windowMinutes == 10080)
        #expect(snapshot.secondary?.title == "Weekly input tokens")
        // Image counts are not tokens; they stay a named extra window.
        #expect(snapshot.extraRateWindows?.map(\.id) == ["daily-images"])
        #expect(snapshot.extraRateWindows?.first?.window.usedPercent == 25)
        // The prepaid balance is never inferred into a quota, but it is the cost balance.
        #expect(snapshot.providerCost?.balance == 12.5)
        #expect(snapshot.providerCost?.used == 1.5)
        #expect(snapshot.providerCost?.currencyCode == "USD")
        for row in snapshot.details.flatMap(\.rows) where row.usageValue == nil {
            #expect(row.value.contains("$12.50") == false)
        }
        #expect(snapshot.identity?.loginMethod == "API key")
        #expect(snapshot.dataConfidence == .exact)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `percent over one stays over budget and degraded lanes lose their meter`(
        engine: ProviderPluginEngineKind) async throws
    {
        let overBudget = Self.subscription.replacingOccurrences(
            of: #""used":150000,"remaining":850000,"percentUsed":0.15"#,
            with: #""used":1200000,"remaining":0,"percentUsed":1.2"#)
        let snapshot = try await Self.fetch(engine: engine, subscription: overBudget)
        #expect(snapshot.primary?.usedPercent == 120)

        let degraded = Self.subscription.replacingOccurrences(
            of: #""used":900000,"remaining":3100000,"percentUsed":0.225,"resetAt":1774300000000"#,
            with: #""used":null,"remaining":null,"percentUsed":null,"resetAt":null,"degraded":true"#)
        let flagged = try await Self.fetch(engine: engine, subscription: degraded)
        #expect(flagged.secondary == nil)
        #expect(flagged.primary != nil)
        let weekly = try #require(flagged.details.first?.rows.first { $0.label == "Weekly input tokens" })
        #expect(weekly.value == "Unavailable")
        #expect(weekly.severity == .warning)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `missing lanes leave the meters absent without inventing quota`(
        engine: ProviderPluginEngineKind) async throws
    {
        let snapshot = try await Self.fetch(
            engine: engine,
            subscription: #"{"active":true,"state":"inactive","dailyInputTokens":null}"#)
        #expect(snapshot.primary == nil)
        #expect(snapshot.secondary == nil)
        #expect(snapshot.extraRateWindows?.isEmpty != false)
        // The balance is still a valid snapshot on its own.
        #expect(snapshot.providerCost?.balance == 12.5)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `used and remaining fill a missing percent`(engine: ProviderPluginEngineKind) async throws {
        let withoutPercent = Self.subscription.replacingOccurrences(
            of: #""used":150000,"remaining":850000,"percentUsed":0.15"#,
            with: #""used":250000,"remaining":750000,"percentUsed":null"#)
        let snapshot = try await Self.fetch(engine: engine, subscription: withoutPercent)
        #expect(snapshot.primary?.usedPercent == 25)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `month to date spend survives a failed balance`(engine: ProviderPluginEngineKind) async throws {
        let snapshot = try await Self.fetch(engine: engine, balancePath: .unavailable)
        #expect(snapshot.providerCost?.used == 1.5)
        #expect(snapshot.providerCost?.balance == nil)
        #expect(snapshot.providerCost?.currencyCode == "USD")
        #expect(snapshot.providerCost?.period == "Month to date")
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `design balance falls back to the website origin`(engine: ProviderPluginEngineKind) async throws {
        let snapshot = try await Self.fetch(engine: engine, balancePath: .websiteOnly)
        #expect(snapshot.providerCost?.balance == 12.5)
        let direct = try await Self.fetch(engine: engine, balancePath: .directOnly)
        #expect(direct.providerCost?.balance == 12.5)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `malformed counters and amounts fail parsing without echoing the body`(
        engine: ProviderPluginEngineKind) async
    {
        for value in [#""private-response""#, "-1", "true", "{}", "[]"] {
            await Self.expectFailure(
                engine: engine,
                subscription: Self.subscription.replacingOccurrences(
                    of: #""used":150000,"remaining":850000,"percentUsed":0.15"#,
                    with: #""used":\#(value),"remaining":850000,"percentUsed":0.15"#),
                kind: .parseFailure)
        }
        for body in ["private-response", "[]", "{}", #"{"usd_balance":"private-response"}"#] {
            await Self.expectFailure(engine: engine, balance: body, kind: .parseFailure)
        }
        await Self.expectFailure(
            engine: engine,
            subscription: Self.subscription.replacingOccurrences(
                of: #""resetAt":1773800000000"#, with: #""resetAt":"private-response""#),
            kind: .parseFailure)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `subscription HTTP failures are classified`(engine: ProviderPluginEngineKind) async {
        for (code, kind) in [
            (401, ProviderFetchClassifiedError.Kind.authenticationExpired), (403, .authenticationExpired),
            (429, .rateLimited), (500, .providerUnavailable), (400, .apiFailure),
        ] {
            await Self.expectFailure(
                engine: engine, subscription: "private-response", subscriptionCode: code, kind: kind)
        }
    }

    @Test
    func `registration keeps the key and source scope explicit`() throws {
        let descriptor = NanoGPTProviderDescriptor.descriptor
        #expect(!descriptor.metadata.defaultEnabled)
        #expect(!descriptor.metadata.widgetSelectable)
        #expect(descriptor.metadata.cliName == "nanogpt")
        #expect(descriptor.fetchPlan.sourceModes == [.auto, .api])
        let credentials = try #require(descriptor.credentials)
        #expect(credentials.resolveToken(environment: ["NANOGPT_API_KEY": "fixture-key"])?.token == "fixture-key")
        #expect(credentials.resolveToken(environment: ["OTHER_KEY": "fixture-key"]) == nil)
    }

    private enum BalancePath { case directOnly, websiteOnly, both, unavailable }

    private static func expectFailure(
        engine: ProviderPluginEngineKind,
        subscription: String? = nil,
        balance: String? = nil,
        subscriptionCode: Int = 200,
        kind: ProviderFetchClassifiedError.Kind) async
    {
        do {
            _ = try await self.fetch(
                engine: engine,
                subscription: subscription,
                balance: balance,
                subscriptionCode: subscriptionCode)
            Issue.record("Expected classified failure")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == kind)
            #expect(!error.message.contains("private-response"))
        } catch {
            Issue.record("Unexpected failure: \(error)")
        }
    }

    private static func fetch(
        engine: ProviderPluginEngineKind,
        subscription: String? = nil,
        balance: String? = nil,
        subscriptionCode: Int = 200,
        balancePath: BalancePath = .both) async throws -> UsageSnapshot
    {
        let runtime = try BundledPluginTestSupport.runtime(
            "nanogpt", engine: engine, transport: ProviderHTTPTransportHandler { request in
                let url = try #require(request.url?.absoluteString)
                var body = #"{}"#
                var code = 200
                switch true {
                case url.hasPrefix("https://api.nano-gpt.com/api/subscription/v1/usage"):
                    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
                    body = subscription ?? Self.subscription
                    code = subscriptionCode
                case url.hasSuffix("/api/check-balance"):
                    #expect(request.httpMethod == "POST")
                    #expect(request.value(forHTTPHeaderField: "X-API-Key") == "fixture-key")
                    if balancePath == .unavailable, url.hasPrefix("https://nano-gpt.com") {
                        throw URLError(.cannotConnectToHost)
                    }
                    if balancePath == .websiteOnly || balancePath == .unavailable,
                       url.hasPrefix("https://api.nano-gpt.com")
                    {
                        code = 404
                    } else {
                        body = balance ?? Self.balance
                    }
                case url.hasPrefix("https://api.nano-gpt.com/api/v1/usage?from=2026-03-01&to=2026-03-17"):
                    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
                    body = Self.usage
                default:
                    Issue.record("Unexpected request \(url)")
                }
                if balancePath == .directOnly, url.hasSuffix("/api/check-balance"),
                   url.hasPrefix("https://nano-gpt.com")
                {
                    // The direct host answered, so the website origin is never needed.
                    Issue.record("Website balance origin should be skipped")
                }
                let response = try #require(HTTPURLResponse(
                    url: request.url!,
                    statusCode: code,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]))
                return (Data(body.utf8), response)
            })
        return try await runtime.fetchUsage(
            secrets: ["NANOGPT_API_KEY": "fixture-key"],
            now: Self.now,
            timeZone: TimeZone(identifier: "UTC")!)
    }
}
