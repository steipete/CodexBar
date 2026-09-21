import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct MusePluginTests {
    static let account = #"""
    {
      "api_key":"LLM|fixture-inference-key", "payment_method":"Visa-0000",
      "require_payment":false, "is_subs_active":true, "user_email":"ada@example.com",
      "subs_tier_name":"Muse Code Power Usage",
      "subs_usage":{
        "window":{"used_percent":96,"window_duration_mins":300,"resets_at":1788599502},
        "weekly":{"used_percent":40,"resets_at":1788739200}
      }
    }
    """#

    static let activeWithoutWindows = #"""
    {"is_subs_active":true,"user_email":"ada@example.com","subs_tier_name":"Muse Code Power Usage"}
    """#

    static let activeWithNullWindows = #"""
    {
      "is_subs_active":true, "user_email":"ada@example.com",
      "subs_tier_name":"Muse Code Power Usage", "subs_usage":null
    }
    """#

    @Test(arguments: BundledPluginTestSupport.engines)
    func `reported subscription windows retain their identity and resets`(
        engine: ProviderPluginEngineKind) async throws
    {
        let snapshot = try await Self.fetch(Self.account, engine: engine)
        #expect(snapshot.primary?.usedPercent == 96)
        #expect(snapshot.primary?.windowMinutes == 300)
        #expect(snapshot.primary?.resetsAt == Date(timeIntervalSince1970: 1_788_599_502))
        #expect(snapshot.secondary?.usedPercent == 40)
        #expect(snapshot.secondary?.windowMinutes == 10080)
        #expect(snapshot.secondary?.resetsAt == Date(timeIntervalSince1970: 1_788_739_200))
        #expect(snapshot.identity?.providerID == .muse)
        #expect(snapshot.identity?.accountEmail == "ada@example.com")
        #expect(snapshot.identity?.loginMethod == "Muse Code Power Usage")
        #expect(snapshot.dataConfidence == .exact)
        #expect(snapshot.providerCost == nil)
        #expect(!snapshot.details.flatMap(\.rows).contains { $0.value.contains("Visa") || $0.value.contains("LLM|") })
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `JSON request sends only the device credential and fixed API version`(
        engine: ProviderPluginEngineKind) async throws
    {
        let runtime = try BundledPluginTestSupport.runtime(
            "muse",
            engine: engine,
            transport: ProviderHTTPTransportHandler { request in
                #expect(request.url?.absoluteString == "https://api.meta.ai/muse-code/key")
                #expect(request.httpMethod == "POST")
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer dca:fixture-token")
                #expect(request.value(forHTTPHeaderField: "x-api-version") == "1.0.0")
                #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
                #expect(request.timeoutInterval == 15)
                #expect(request.httpBody == Data("{}".utf8))
                return try Self.response(request, body: Self.account)
            })
        _ = try await runtime.fetchUsage(secrets: ["MUSE_DEVICE_TOKEN": "dca:fixture-token"])
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `inference keys never reach the mint endpoint`(engine: ProviderPluginEngineKind) async throws {
        let runtime = try BundledPluginTestSupport.runtime(
            "muse",
            engine: engine,
            transport: ProviderHTTPTransportHandler { request in
                Issue.record("Inference credential reached the transport")
                return try Self.response(request, body: Self.account)
            })
        await Self.expectFailure(.authenticationExpired) {
            try await runtime.fetchUsage(secrets: ["MUSE_DEVICE_TOKEN": "LLM|fixture-token"])
        }
    }

    @Test(arguments: ["{}", "<html>Sign in</html>", ""], BundledPluginTestSupport.engines)
    func `unauthorized text responses retain login recovery`(body: String, engine: ProviderPluginEngineKind) async {
        await Self.expectFailure(.authenticationExpired) {
            try await Self.fetch(body, engine: engine, status: 401)
        }
    }

    @Test(arguments: [
        #"{"require_payment":true,"is_subs_active":false}"#,
        #"{"is_subs_active":false,"subs_usage":null}"#,
    ], BundledPluginTestSupport.engines)
    func `inactive subscriptions and missing billing never invent quotas`(
        body: String,
        engine: ProviderPluginEngineKind) async
    {
        await Self.expectFailure(.permissionDenied) { try await Self.fetch(body, engine: engine) }
    }

    @Test(arguments: [Self.activeWithoutWindows, Self.activeWithNullWindows], BundledPluginTestSupport.engines)
    func `active login without quota windows keeps plan identity`(
        body: String,
        engine: ProviderPluginEngineKind) async throws
    {
        let snapshot = try await Self.fetch(body, engine: engine)
        #expect(snapshot.primary == nil)
        #expect(snapshot.secondary == nil)
        #expect(snapshot.dataConfidence == .unknown)
        #expect(snapshot.identity?.accountEmail == "ada@example.com")
        #expect(snapshot.identity?.loginMethod == "Muse Code Power Usage")
        let rows = snapshot.details.flatMap(\.rows)
        #expect(rows.contains { $0.label == "Plan" && $0.value == "Muse Code Power Usage" })
        #expect(rows.contains { $0.label == "Quota" && $0.value.contains("login response") })
        #expect(!rows.contains { $0.label == "5 hours" || $0.label == "Weekly" })
    }

    @Test(arguments: [#"{"is_subs_active":true,"subs_usage":"window"}"#], BundledPluginTestSupport.engines)
    func `non-object quota payload remains a parse failure`(
        body: String,
        engine: ProviderPluginEngineKind) async
    {
        await Self.expectFailure(.parseFailure) { try await Self.fetch(body, engine: engine) }
    }

    @Test(arguments: ["1e30", "0", "-1", "true", "\"300\""], BundledPluginTestSupport.engines)
    func `invalid durations fail without trapping`(value: String, engine: ProviderPluginEngineKind) async {
        let body = Self.account.replacingOccurrences(
            of: "\"window_duration_mins\":300",
            with: "\"window_duration_mins\":\(value)")
        await Self.expectFailure(.parseFailure) { try await Self.fetch(body, engine: engine) }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `unrepresentable resets preserve reported usage`(engine: ProviderPluginEngineKind) async throws {
        let body = Self.account.replacingOccurrences(of: "1788599502", with: "1e30")
        let snapshot = try await Self.fetch(body, engine: engine)
        #expect(snapshot.primary?.usedPercent == 96)
        #expect(snapshot.primary?.resetsAt == nil)
        #expect(snapshot.secondary?.resetsAt != nil)
    }

    static func fetch(
        _ body: String,
        engine: ProviderPluginEngineKind,
        status: Int = 200) async throws -> UsageSnapshot
    {
        let runtime = try BundledPluginTestSupport.runtime(
            "muse",
            engine: engine,
            transport: ProviderHTTPTransportHandler { request in
                try Self.response(request, body: body, status: status)
            })
        return try await runtime.fetchUsage(
            secrets: ["MUSE_DEVICE_TOKEN": "dca:fixture-token"],
            now: Date(timeIntervalSince1970: 1_788_580_000))
    }

    private static func response(
        _ request: URLRequest,
        body: String,
        status: Int = 200) throws -> (Data, URLResponse)
    {
        let response = try #require(HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]))
        return (Data(body.utf8), response)
    }

    private static func expectFailure(
        _ kind: ProviderFetchClassifiedError.Kind,
        operation: () async throws -> UsageSnapshot) async
    {
        do {
            _ = try await operation()
            Issue.record("Expected \(kind.rawValue)")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == kind)
        } catch {
            Issue.record("Unexpected failure: \(error)")
        }
    }
}
