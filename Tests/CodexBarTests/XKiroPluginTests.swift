import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct XKiroPluginTests {
    /// https://docs.xkiro.com/api/usage/ — PAYG example, with synthetic identity.
    static let fixture = #"""
    {"object":"usage","plan":null,"user":{"email":"dev@example.com"},"windows":[],
     "free_tokens":{"used_today":124035,"limit_per_day":5000000,"remaining":4875965},
     "wallet":{"balance_usd":"4.812300","held_usd":"0.150000"}}
    """#
    static let now = Date(timeIntervalSince1970: 1_790_251_200)

    @Test(arguments: BundledPluginTestSupport.engines)
    func `documented free token quota stays separate from paid balance`(engine: ProviderPluginEngineKind) async throws {
        let usage = try await Self.fetch(Self.fixture, engine: engine)
        #expect(abs((usage.primary?.usedPercent ?? -1) - 2.4807) < 0.00001)
        #expect(usage.primary?.windowMinutes == 1440)
        #expect(usage.primary?.resetsAt == Date(timeIntervalSince1970: 1_790_294_400))
        #expect(usage.secondary == nil)
        #expect(usage.providerCost == nil)
        #expect(usage.identity?.accountEmail == "dev@example.com")
        #expect(usage.identity?.loginMethod == "Pay as you go")
        #expect(usage.details.first?.rows.map(\.value) == ["124,035", "5,000,000", "4,875,965", "00:00 UTC"])
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `missing counters and uncapped accounts never invent headroom`(engine: ProviderPluginEngineKind) async throws {
        for (fields, expected) in [
            (#""used_today":0,"limit_per_day":null,"remaining":null"#, ["0", "No cap reported", "00:00 UTC"]),
            (#""remaining":12"#, ["12", "00:00 UTC"]),
            (#""limit_per_day":500000"#, ["500,000", "00:00 UTC"]),
        ] {
            let usage = try await Self.fetch(#"{"object":"usage","free_tokens":{\#(fields)}}"#, engine: engine)
            #expect(usage.primary == nil)
            #expect(usage.identity?.loginMethod == nil)
            #expect(usage.details.first?.rows.map(\.value) == expected)
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `exhaustion and zero allowance do not use wallet capacity`(engine: ProviderPluginEngineKind) async throws {
        for limit in [0, 500_000] {
            let usage = try await Self.fetch(
                #"{"object":"usage","free_tokens":{"used_today":\#(limit),"limit_per_day":\#(limit),"remaining":0}}"#,
                engine: engine)
            #expect(usage.primary?.usedPercent == 100)
            #expect(usage.details.first?.rows[2].value == "0")
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `invalid counters fail without echoing response data`(engine: ProviderPluginEngineKind) async {
        for value in ["-1", "0.5", "true", "\"private-response\"", "9007199254740992", "{}", "[]"] {
            await Self.expectFailure(
                #"{"object":"usage","free_tokens":{"used_today":\#(value)}}"#,
                engine: engine,
                kind: .parseFailure)
        }
        for body in ["private-response", "null", "[]", "{}", #"{"object":"usage","free_tokens":{}}"#] {
            await Self.expectFailure(body, engine: engine, kind: .parseFailure)
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `HTTP failures remain classified and retain bounded retry evidence`(engine: ProviderPluginEngineKind) async {
        for (code, kind) in [
            (401, ProviderFetchClassifiedError.Kind.authenticationExpired), (403, .permissionDenied),
            (429, .rateLimited), (503, .providerUnavailable), (400, .apiFailure),
        ] {
            await Self.expectFailure("private-response", engine: engine, code: code, kind: kind)
        }
    }

    @Test
    func `registration uses only the explicit provider key and defaults off`() throws {
        let provider = try #require(UsageProvider(rawValue: "xkiro"))
        let descriptor = ProviderDescriptorRegistry.descriptor(for: provider)
        #expect(!descriptor.metadata.defaultEnabled)
        #expect(!descriptor.metadata.widgetSelectable)
        let credentials = try #require(descriptor.credentials)
        #expect(credentials.resolveToken(environment: ["XKIRO_API_KEY": "fixture-key"])?.token == "fixture-key")
        #expect(credentials.resolveToken(environment: ["XKIRO_API_KEY": "  "]) == nil)
        #expect(credentials.resolveToken(environment: ["OTHER_API_KEY": "fixture-key"]) == nil)
        let environment = ProviderConfigEnvironment.applyAPIKeyOverride(
            base: ["XKIRO_API_KEY": "environment-key"],
            provider: provider,
            config: ProviderConfig(id: provider.instanceID, apiKey: "config-key"))
        #expect(environment["XKIRO_API_KEY"] == "config-key")
    }

    private static func expectFailure(
        _ body: String,
        engine: ProviderPluginEngineKind,
        code: Int = 200,
        kind: ProviderFetchClassifiedError.Kind) async
    {
        do {
            _ = try await self.fetch(body, engine: engine, code: code)
            Issue.record("Expected classified failure")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == kind)
            #expect(!error.message.contains("private-response"))
            if code == 429 { #expect(error.retryAfterSeconds == 10) }
        } catch {
            Issue.record("Unexpected failure: \(error)")
        }
    }

    private static func fetch(
        _ body: String, engine: ProviderPluginEngineKind, code: Int = 200) async throws -> UsageSnapshot
    {
        let runtime = try BundledPluginTestSupport.runtime(
            "xkiro",
            engine: engine,
            transport: ProviderHTTPTransportHandler { request in
                #expect(request.url?.absoluteString == "https://api.xkiro.com/v1/usage")
                #expect(request.httpMethod == "GET")
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
                let response = try #require(HTTPURLResponse(
                    url: request.url!,
                    statusCode: code,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json", "Retry-After": "30"]))
                return (Data(body.utf8), response)
            })
        return try await runtime.fetchUsage(secrets: ["XKIRO_API_KEY": "fixture-key"], now: Self.now)
    }
}
