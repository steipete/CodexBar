import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct ExaPluginTests {
    private static let now = Date(timeIntervalSince1970: 1_791_462_696)
    private static let period = #""period":{"start":"2026-10-01T00:00:00Z","end":"2026-10-08T12:31:36Z"}"#
    private static let body = #"{"total_cost_usd":45.67,\#(period),"cost_breakdown":[]}"#

    @Test(arguments: BundledPluginTestSupport.engines)
    func `selected key monthly spend has no inferred balance quota or reset`(
        engine: ProviderPluginEngineKind) async throws
    {
        let snapshot = try await Self.fetch(Self.body, engine: engine)
        #expect(snapshot.details.first?.title == "API key this month (UTC)")
        #expect(snapshot.details.first?.rows.first?.label == "Spend")
        #expect(snapshot.details.first?.rows.first?.value == "$45.67")
        #expect(snapshot.providerCost == nil)
        #expect(snapshot.primary == nil)
        #expect(snapshot.secondary == nil)
        #expect(snapshot.tertiary == nil)
        #expect(snapshot.subscriptionRenewsAt == nil)
        #expect(snapshot.identity?.accountEmail == nil)
        #expect(snapshot.identity?.accountOrganization == nil)
        #expect(snapshot.dataConfidence == .exact)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `zero spend stays visible`(engine: ProviderPluginEngineKind) async throws {
        let snapshot = try await Self.fetch(#"{"total_cost_usd":0,\#(Self.period)}"#, engine: engine)
        #expect(snapshot.details.first?.rows.first?.value == "$0.00")
        #expect(snapshot.providerCost == nil)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `request end uses whole seconds when refresh has fractional milliseconds`(
        engine: ProviderPluginEngineKind) async throws
    {
        let snapshot = try await Self.fetch(Self.body, engine: engine, now: Self.now.addingTimeInterval(0.789))
        #expect(snapshot.details.first?.rows.first?.value == "$45.67")
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `key IDs remain one encoded path segment without invented syntax restrictions`(
        engine: ProviderPluginEngineKind) async throws
    {
        let snapshot = try await Self.fetch(
            Self.body,
            engine: engine,
            id: "key:fixture/part?x=1#fragment",
            encodedID: "key%3Afixture%2Fpart%3Fx%3D1%23fragment")
        #expect(snapshot.details.first?.rows.first?.value == "$45.67")
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `invalid spend and periods fail closed`(engine: ProviderPluginEngineKind) async {
        let bodies = ["private-response", "null", "[]", "{}", #"{"total_cost_usd":1}"#]
            + ["null", "true", "\"12\"", "{}", "[]", "1e400", "-0.01"].map {
                #"{"total_cost_usd":\#($0),\#(Self.period)}"#
            }
            + [
                Self.body.replacingOccurrences(of: "2026-10-01", with: "2026-09-01"),
                Self.body.replacingOccurrences(of: "2026-10-08", with: "2026-10-07"),
                Self.body.replacingOccurrences(of: "2026-10-01T00:00:00Z", with: "private-response"),
            ]
        for body in bodies {
            await Self.expectFailure(body, engine: engine, kind: .parseFailure)
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `HTTP errors retain classification without private response text`(engine: ProviderPluginEngineKind) async {
        for (code, kind) in [
            (401, ProviderFetchClassifiedError.Kind.authenticationExpired), (403, .permissionDenied),
            (429, .rateLimited), (503, .providerUnavailable), (404, .apiFailure), (400, .apiFailure),
        ] {
            await Self.expectFailure("private-response", engine: engine, code: code, kind: kind)
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `missing service key stops before transport`(engine: ProviderPluginEngineKind) async throws {
        let runtime = try Self.noNetworkRuntime(engine: engine)
        do {
            _ = try await runtime.fetchUsage(settings: ["EXA_API_KEY_ID": "key_fixture"], now: Self.now)
            Issue.record("Expected missing service key failure")
        } catch let ProviderPluginError.secretAccess(message) {
            #expect(message.contains("EXA_SERVICE_KEY"))
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `missing and path normalization key IDs stop before transport`(engine: ProviderPluginEngineKind) async throws {
        let runtime = try Self.noNetworkRuntime(engine: engine)
        for id in ["", "  ", ".", ".."] {
            do {
                _ = try await runtime.fetchUsage(
                    settings: ["EXA_API_KEY_ID": id], secrets: ["EXA_SERVICE_KEY": "fixture-key"], now: Self.now)
                Issue.record("Expected missing key ID failure")
            } catch let error as ProviderFetchClassifiedError {
                #expect(error.kind == .missingCredential)
            }
        }
    }

    @Test
    func `service credentials stay explicit and history is unavailable`() throws {
        let descriptor = ExaProviderDescriptor.descriptor
        let credentials = try #require(descriptor.credentials)
        #expect(!descriptor.metadata.defaultEnabled)
        #expect(!descriptor.metadata.burnDownWidgetSelectable)
        #expect(descriptor.menuBarMetrics == .automaticOnly)
        #expect(descriptor.history == .unavailable)
        #expect(credentials.resolveToken(environment: ["EXA_SERVICE_KEY": "fixture-key"])?.token == "fixture-key")
        #expect(credentials.resolveToken(environment: ["EXA_API_KEY": "ordinary-search-key"]) == nil)
        #expect(credentials.resolveToken(environment: ["EXA_SERVICE_KEY": "  "]) == nil)
        #expect(ExaProviderDescriptor.spec.workspaceField?.environmentKey == "EXA_API_KEY_ID")
    }

    private static func noNetworkRuntime(engine: ProviderPluginEngineKind) throws -> ProviderPluginRuntime {
        try BundledPluginTestSupport.runtime("exa", engine: engine, transport: ProviderHTTPTransportHandler { _ in
            Issue.record("Transport must not run with missing credentials or an invalid key ID")
            throw URLError(.cancelled)
        })
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

    private static func fetch(
        _ body: String,
        engine: ProviderPluginEngineKind,
        code: Int = 200,
        now: Date = Self.now,
        id: String = "key_fixture",
        encodedID: String = "key_fixture") async throws -> UsageSnapshot
    {
        let runtime = try BundledPluginTestSupport.runtime(
            "exa", engine: engine, transport: ProviderHTTPTransportHandler { request in
                let url = try #require(request.url)
                #expect(url.host == "admin-api.exa.ai")
                let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
                #expect(components.percentEncodedPath == "/team-management/api-keys/\(encodedID)/usage")
                let query = try #require(components.queryItems)
                #expect(query == [
                    URLQueryItem(name: "start_date", value: "2026-10-01T00:00:00.000Z"),
                    URLQueryItem(name: "end_date", value: "2026-10-08T12:31:36.000Z"),
                ])
                #expect(request.httpMethod == "GET")
                #expect(request.value(forHTTPHeaderField: "x-api-key") == "fixture-key")
                #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
                #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
                let response = try #require(HTTPURLResponse(
                    url: url,
                    statusCode: code,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]))
                return (Data(body.utf8), response)
            })
        return try await runtime.fetchUsage(
            settings: ["EXA_API_KEY_ID": id], secrets: ["EXA_SERVICE_KEY": "fixture-key"], now: now)
    }
}
