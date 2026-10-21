import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct AerostackPluginTests {
    /// https://docs.aerostack.dev/billing/ — documented account usage shape, synthetic counters.
    static let fixture = #"""
    {"tier":"starter","period":"2026-03","usage":{
      "ai_tokens":{"used":150000,"limit":1000000},"api_requests":{"used":42000,"limit":500000},
      "gateway_requests":{"used":3000,"limit":50000},"mcp_proxy_calls":{"used":1200,"limit":50000}},
      "wallet":{"balance_cents":500},"current_period_end":"2026-04-01T00:00:00Z"}
    """#

    @Test(arguments: BundledPluginTestSupport.engines)
    func `documented monthly quota excludes wallet and invented resets`(engine: ProviderPluginEngineKind) async throws {
        let usage = try await Self.fetch(Self.fixture, engine: engine)
        #expect(usage.primary?.usedPercent == 15)
        #expect(usage.primary?.resetsAt == nil)
        #expect(usage.primary?.windowMinutes == nil)
        #expect(usage.secondary == nil)
        #expect(usage.providerCost == nil)
        #expect(usage.identity?.loginMethod == "starter")
        #expect(usage.details.first?.rows.map(\.value) == ["150,000", "1,000,000", "850,000", "2026-03"])
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `observed entitlement and usage above allowance remain explicit`(
        engine: ProviderPluginEngineKind) async throws
    {
        let usage = try await Self.fetch(
            #"{"tier":"free","usage":{"ai_tokens":{"used":600000,"limit":450000}}}"#,
            engine: engine)
        #expect(usage.primary?.usedPercent == 100)
        #expect(usage.details.first?.rows.map(\.value) == ["600,000", "450,000", "0", "150,000"])
        #expect(usage.details.first?.rows.last?.label == "Above allowance")
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `missing and zero limits do not manufacture quota`(engine: ProviderPluginEngineKind) async throws {
        for (fields, values) in [
            (#""used":0"#, ["0"]),
            (#""used":50,"limit":null"#, ["50"]),
            (#""limit":1000"#, ["1,000"]),
            (#""used":0,"limit":0"#, ["0", "0", "0"]),
        ] {
            let usage = try await Self.fetch(#"{"usage":{"ai_tokens":{\#(fields)}}}"#, engine: engine)
            #expect(usage.primary == nil)
            #expect(usage.details.first?.rows.map(\.value) == values)
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `malformed monthly data fails without response disclosure`(engine: ProviderPluginEngineKind) async {
        for value in ["-1", "0.5", "true", "\"private-response\"", "9007199254740992", "{}", "[]"] {
            await Self.expectFailure(
                #"{"usage":{"ai_tokens":{"used":\#(value),"limit":1000}}}"#,
                engine: engine,
                kind: .parseFailure)
            await Self.expectFailure(
                #"{"usage":{"ai_tokens":{"used":50,"limit":\#(value)}}}"#,
                engine: engine,
                kind: .parseFailure)
        }
        for body in [
            "private-response", "null", "[]", "{}", #"{"usage":{"ai_tokens":{}}}"#,
            #"{"usage":{"ai_tokens":{"used":10}},"period":"private-response"}"#,
            #"{"usage":{"ai_tokens":{"used":10}},"tier":false}"#,
        ] {
            await Self.expectFailure(body, engine: engine, kind: .parseFailure)
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `billing HTTP failures are classified`(engine: ProviderPluginEngineKind) async {
        for (code, kind) in [
            (401, ProviderFetchClassifiedError.Kind.authenticationExpired), (403, .permissionDenied),
            (429, .rateLimited), (503, .providerUnavailable), (400, .apiFailure),
        ] {
            await Self.expectFailure("private-response", engine: engine, code: code, kind: kind)
        }
    }

    @Test
    func `registration keeps account token scope explicit`() throws {
        let descriptor = AerostackProviderDescriptor.descriptor
        #expect(!descriptor.metadata.defaultEnabled)
        let credentials = try #require(descriptor.credentials)
        #expect(credentials.resolveToken(environment: ["AEROSTACK_TOKEN": "fixture-token"])?.token == "fixture-token")
        #expect(credentials.resolveToken(environment: ["OTHER_TOKEN": "fixture-token"]) == nil)
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
        } catch {
            Issue.record("Unexpected failure: \(error)")
        }
    }

    static func fetch(
        _ body: String, engine: ProviderPluginEngineKind, code: Int = 200) async throws -> UsageSnapshot
    {
        let runtime = try BundledPluginTestSupport.runtime(
            "aerostack",
            engine: engine,
            transport: ProviderHTTPTransportHandler { request in
                #expect(request.url?.absoluteString == "https://api.aerostack.dev/api/billing/usage")
                #expect(request.httpMethod == "GET")
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token")
                let response = try #require(HTTPURLResponse(
                    url: request.url!,
                    statusCode: code,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]))
                return (Data(body.utf8), response)
            })
        return try await runtime.fetchUsage(secrets: ["AEROSTACK_TOKEN": "fixture-token"])
    }
}
