import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct CosmicPluginTests {
    /// Public cosmicjs/cli ProjectUsageResponse schema, with synthetic counters and unrelated paid data.
    static let fixture = #"""
    {"usage":{"ai":{"input_tokens":75000,"output_tokens":150000}},
     "plan_info":{"ai_tokens":{"max_input":"300k","max_output":"1.5M"}},
     "token_pack":{"remaining":10000000},"resets_at":"2026-11-01T00:00:00Z"}
    """#

    @Test(arguments: BundledPluginTestSupport.engines)
    func `project input and output allowances stay separate`(engine: ProviderPluginEngineKind) async throws {
        let usage = try await Self.fetch(Self.fixture, engine: engine)
        #expect(usage.primary?.usedPercent == 25)
        #expect(usage.secondary?.usedPercent == 10)
        #expect(usage.primary?.resetsAt == nil)
        #expect(usage.secondary?.resetsAt == nil)
        #expect(usage.primary?.windowMinutes == nil)
        #expect(usage.providerCost == nil)
        #expect(usage.details.map(\.title) == ["Input tokens", "Output tokens"])
        #expect(usage.details[0].rows.map(\.value) == ["75,000", "300,000", "225,000"])
        #expect(usage.details[1].rows.map(\.value) == ["150,000", "1,500,000", "1,350,000"])
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `missing counters and zero allowances are never defaulted`(engine: ProviderPluginEngineKind) async throws {
        for (body, values) in [
            (#"{"usage":{"ai":{"input_tokens":0}}}"#, ["0"]),
            (#"{"plan_info":{"ai_tokens":{"max_input":"300k"}}}"#, ["300,000"]),
            (
                #"{"usage":{"ai":{"input_tokens":0}},"plan_info":{"ai_tokens":{"max_input":"0"}}}"#,
                ["0", "0", "0"]),
        ] {
            let usage = try await Self.fetch(body, engine: engine)
            #expect(usage.primary == nil)
            #expect(usage.secondary == nil)
            #expect(usage.details.first?.rows.map(\.value) == values)
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `nonnumeric allowances never become numeric quotas`(engine: ProviderPluginEngineKind) async throws {
        for (allowance, label) in [("Unlimited", "Unlimited"), ("300k-junk", "Not reported")] {
            let usage = try await Self.fetch(
                #"{"usage":{"ai":{"input_tokens":10}},"plan_info":{"ai_tokens":{"max_input":"\#(allowance)"}}}"#,
                engine: engine)
            #expect(usage.primary == nil)
            #expect(usage.details.first?.rows.map(\.value) == ["10", label])
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `observed over allowance counters are preserved`(engine: ProviderPluginEngineKind) async throws {
        let usage = try await Self.fetch(
            #"{"usage":{"ai":{"output_tokens":400000}},"plan_info":{"ai_tokens":{"max_output":"300K"}}}"#,
            engine: engine)
        #expect(usage.primary == nil)
        #expect(usage.secondary?.usedPercent == 100)
        #expect(usage.details.first?.rows.map(\.value) == ["400,000", "300,000", "0", "100,000"])
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `project identifier is encoded as one query value`(engine: ProviderPluginEngineKind) async throws {
        _ = try await Self.fetch(Self.fixture, engine: engine, projectID: "project &other=value")
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `missing project fails before a request`(engine: ProviderPluginEngineKind) async {
        await Self.expectFailure(Self.fixture, engine: engine, projectID: " ", kind: .missingCredential)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `malformed quota data fails without response disclosure`(engine: ProviderPluginEngineKind) async {
        for value in ["-1", "0.5", "true", "\"private-response\"", "9007199254740992", "{}", "[]"] {
            await Self.expectFailure(
                #"{"usage":{"ai":{"input_tokens":\#(value)}}}"#, engine: engine, kind: .parseFailure)
        }
        for value in ["-1", "true", "\"0.0001k\"", "{}", "[]"] {
            await Self.expectFailure(
                #"{"plan_info":{"ai_tokens":{"max_input":\#(value)}}}"#, engine: engine, kind: .parseFailure)
        }
        for body in ["private-response", "null", "[]", "{}", #"{"usage":{"ai":{}}}"#] {
            await Self.expectFailure(body, engine: engine, kind: .parseFailure)
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `project HTTP failures are classified`(engine: ProviderPluginEngineKind) async {
        for (code, kind) in [
            (401, ProviderFetchClassifiedError.Kind.authenticationExpired), (403, .permissionDenied),
            (429, .rateLimited), (503, .providerUnavailable), (400, .apiFailure),
        ] {
            await Self.expectFailure("private-response", engine: engine, code: code, kind: kind)
        }
    }

    @Test
    func `registration projects only the configured project and token`() throws {
        let descriptor = CosmicProviderDescriptor.descriptor
        #expect(!descriptor.metadata.defaultEnabled)
        let environment = ProviderConfigEnvironment.applyAPIKeyOverride(
            base: [:],
            provider: .cosmic,
            config: ProviderConfig(id: .cosmic, apiKey: "fixture-token", workspaceID: "project-fixture"))
        #expect(environment["COSMIC_TOKEN"] == "fixture-token")
        #expect(environment["COSMIC_PROJECT_ID"] == "project-fixture")
        let credentials = try #require(descriptor.credentials)
        #expect(credentials.resolveToken(environment: ["COSMIC_TOKEN": "fixture-token"])?.token == "fixture-token")
        #expect(credentials.resolveToken(environment: ["OTHER_TOKEN": "fixture-token"]) == nil)
    }

    private static func expectFailure(
        _ body: String,
        engine: ProviderPluginEngineKind,
        code: Int = 200,
        projectID: String = "project-fixture",
        kind: ProviderFetchClassifiedError.Kind) async
    {
        do {
            _ = try await self.fetch(body, engine: engine, code: code, projectID: projectID)
            Issue.record("Expected classified failure")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == kind)
            #expect(!error.message.contains("private-response"))
        } catch {
            Issue.record("Unexpected failure: \(error)")
        }
    }

    static func fetch(
        _ body: String,
        engine: ProviderPluginEngineKind,
        code: Int = 200,
        projectID: String = "project-fixture") async throws -> UsageSnapshot
    {
        let runtime = try BundledPluginTestSupport.runtime(
            "cosmic",
            engine: engine,
            transport: ProviderHTTPTransportHandler { request in
                #expect(!projectID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                let components = try #require(URLComponents(url: request.url!, resolvingAgainstBaseURL: false))
                #expect(components.scheme == "https")
                #expect(components.host == "dapi.cosmicjs.com")
                #expect(components.path == "/v3/projects/usage")
                #expect(components.queryItems == [URLQueryItem(name: "project_id", value: projectID)])
                #expect(request.httpMethod == "GET")
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token")
                #expect(request.value(forHTTPHeaderField: "Origin") == "https://app.cosmicjs.com")
                let response = try #require(HTTPURLResponse(
                    url: request.url!,
                    statusCode: code,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]))
                return (Data(body.utf8), response)
            })
        return try await runtime.fetchUsage(
            settings: ["COSMIC_PROJECT_ID": projectID], secrets: ["COSMIC_TOKEN": "fixture-token"])
    }
}
