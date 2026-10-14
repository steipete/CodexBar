import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct FloraPluginTests {
    static let workspace = "ws_fixture123"
    /// 2026-03-17T12:00:00Z: the request covers the UTC month to date.
    static let now = Date(timeIntervalSince1970: 1_773_748_800)

    /// Documented `GET /workspaces/{id}/usage` schema with synthetic values.
    static let workspaceScope = #"""
    {"workspace_id":"ws_fixture123","currency":"USD","balance_scope":"workspace","available_cost":128.4,
     "spend":{"status":"available","scope":"workspace","period":{"start_date":"2026-03-01","end_date":"2026-03-17"},
     "total_cost":12.5,"classified_runs":1234,
     "runs_by_category":{"text":1,"image":1000,"video":200,"audio":3,"technique":30}}}
    """#

    @Test(arguments: BundledPluginTestSupport.engines)
    func `workspace scope shows the pool balance and month to date spend`(
        engine: ProviderPluginEngineKind) async throws
    {
        let snapshot = try await Self.fetch(Self.workspaceScope, engine: engine)
        let rows = try #require(snapshot.details.first?.rows)
        #expect(snapshot.details.first?.title == "Workspace balance")
        #expect(rows.map(\.label) == ["Available", "Spent this month", "Runs this month"])
        #expect(rows.map(\.value) == ["$128.40", "$12.50", "1,234"])
        #expect(rows[0].secondaryValue == "Workspace pool")
        #expect(snapshot.primary == nil)
        #expect(snapshot.secondary == nil)
        #expect(snapshot.providerCost == nil)
        #expect(snapshot.subscriptionRenewsAt == nil)
        #expect(snapshot.identity?.loginMethod == "API key")
        #expect(snapshot.dataConfidence == .exact)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `caller scope shows the allowance member limit and unavailable spend reason`(
        engine: ProviderPluginEngineKind) async throws
    {
        for (period, periodLabel) in [("month", "Monthly"), ("all_time", "All time"), ("weekly", nil)] {
            let body = #"""
            {"workspace_id":"ws_fixture123","currency":"USD","balance_scope":"caller","available_cost":7.25,
             "member_limit":{"limit_cost":50,"period":"\#(period)"},
             "spend":{"status":"unavailable","reason":"permission_missing"}}
            """#
            let rows = try #require(try await Self.fetch(body, engine: engine).details.first?.rows)
            #expect(rows.map(\.label) == ["Available", "Member limit", "Spent this month"])
            #expect(rows.map(\.value) == ["$7.25", "$50.00", "Unavailable"])
            #expect(rows.map(\.secondaryValue) == ["Your allowance", periodLabel, "Needs billing permission"])
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `unavailable spend reasons are mapped and never become zero`(engine: ProviderPluginEngineKind) async throws {
        for (reason, label) in [
            ("entitlement_missing", "Plan has no usage reporting"),
            ("permission_missing", "Needs billing permission"),
            ("summary_unavailable", "Totals not computed; try again"),
            ("private-response", "Not reported"),
        ] {
            let body = #"""
            {"currency":"USD","balance_scope":"caller","available_cost":0,
             "spend":{"status":"unavailable","reason":"\#(reason)"}}
            """#
            let rows = try #require(try await Self.fetch(body, engine: engine).details.first?.rows)
            #expect(rows.map(\.value) == ["$0.00", "Unavailable"])
            #expect(rows.last?.secondaryValue == label)
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `member limit is ignored outside caller scope and optional fields stay optional`(
        engine: ProviderPluginEngineKind) async throws
    {
        let body = #"""
        {"currency":"USD","balance_scope":"workspace","available_cost":-2,
         "member_limit":{"limit_cost":5,"period":"month"},"spend":{"status":"available","total_cost":0}}
        """#
        let rows = try #require(try await Self.fetch(body, engine: engine).details.first?.rows)
        #expect(rows.map(\.label) == ["Available", "Spent this month"])
        #expect(rows.map(\.value) == ["-$2.00", "$0.00"])
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `workspace ID is required and validated before any request`(engine: ProviderPluginEngineKind) async {
        for workspace in [nil, "", "  ", "fixture", "ws_", "ws_bad/../id", "ws_fixture 123"] {
            await Self.expectFailure(
                Self.workspaceScope, engine: engine, workspace: workspace, kind: .missingCredential, requests: 0)
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `malformed balances and spend fail closed`(engine: ProviderPluginEngineKind) async {
        let bodies = [
            "private-response",
            "null",
            "[]",
            "{}",
            #"{"available_cost":"12"}"#,
            #"{"available_cost":1e400}"#,
            #"{"available_cost":1,"spend":{"status":"available"}}"#,
            #"{"available_cost":1,"spend":{"status":"available","total_cost":"3"}}"#,
        ]
        for body in bodies {
            await Self.expectFailure(body, engine: engine, kind: .parseFailure)
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `HTTP errors retain classification without echoing private bodies`(engine: ProviderPluginEngineKind) async {
        for (code, kind) in [
            (401, ProviderFetchClassifiedError.Kind.authenticationExpired), (403, .permissionDenied),
            (404, .apiFailure), (429, .rateLimited), (503, .providerUnavailable), (400, .apiFailure),
        ] {
            await Self.expectFailure("private-response", engine: engine, code: code, kind: kind)
        }
    }

    @Test
    func `credentials and workspace stay explicit and provider defaults off`() throws {
        let descriptor = FloraProviderDescriptor.descriptor
        let credentials = try #require(descriptor.credentials)
        #expect(!descriptor.metadata.defaultEnabled)
        #expect(descriptor.metadata.balanceOnly)
        #expect(descriptor.fetchPlan.sourceModes == [.auto, .api])
        #expect(credentials.resolveToken(environment: ["FLORA_API_KEY": "fixture-key"])?.token == "fixture-key")
        #expect(credentials.resolveToken(environment: ["FLORA_API_KEY": "  "]) == nil)
        #expect(credentials.resolveToken(environment: ["OTHER_API_KEY": "fixture-key"]) == nil)
        let config = ProviderConfig(
            id: UsageProvider.flora.instanceID,
            apiKey: "fixture-key",
            workspaceID: Self.workspace)
        let environment = credentials.applyConfig(base: [:], config: config)
        #expect(environment["FLORA_API_KEY"] == "fixture-key")
        #expect(environment["FLORA_WORKSPACE_ID"] == Self.workspace)
    }

    private static func expectFailure(
        _ body: String,
        engine: ProviderPluginEngineKind,
        workspace: String? = Self.workspace,
        code: Int = 200,
        kind: ProviderFetchClassifiedError.Kind,
        requests expectedRequests: Int = 1) async
    {
        let counter = RequestCounter()
        do {
            _ = try await self.fetch(body, engine: engine, workspace: workspace, code: code, counter: counter)
            Issue.record("Expected classified failure for \(body)")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == kind)
            #expect(!error.message.contains("private-response"))
            #expect(!error.message.contains("fixture-key"))
        } catch {
            Issue.record("Unexpected failure: \(error)")
        }
        if expectedRequests == 0 { #expect(counter.value == 0) }
    }

    final class RequestCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int {
            self.lock.withLock { self.count }
        }

        func increment() { self.lock.withLock { self.count += 1 } }
    }

    static func fetch(
        _ body: String = Self.workspaceScope,
        engine: ProviderPluginEngineKind,
        workspace: String? = Self.workspace,
        code: Int = 200,
        counter: RequestCounter? = nil) async throws -> UsageSnapshot
    {
        let runtime = try BundledPluginTestSupport.runtime(
            "flora", engine: engine, transport: ProviderHTTPTransportHandler { request in
                counter?.increment()
                #expect(request.url?.absoluteString ==
                    "https://app.flora.ai/api/v1/workspaces/ws_fixture123/usage?start_date=2026-03-01&end_date=2026-03-17")
                #expect(request.httpMethod == "GET")
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
                #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
                let response = try #require(HTTPURLResponse(
                    url: request.url!,
                    statusCode: code,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json", "Retry-After": "0"]))
                return (Data(body.utf8), response)
            })
        return try await runtime.fetchUsage(
            settings: workspace.map { ["FLORA_WORKSPACE_ID": $0] } ?? [:],
            secrets: ["FLORA_API_KEY": "fixture-key"],
            now: Self.now,
            timeZone: TimeZone(identifier: "Pacific/Kiritimati")!)
    }
}
