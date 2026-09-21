import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct HuggingFacePluginTests {
    static let now = Date(timeIntervalSince1970: 1_755_000_000)
    static let billing = #"""
    {"usage":{"inferenceProviders":{"usedNanoUsd":2450000000,"includedNanoUsd":2000000000,
    "limitNanoUsd":0,"numRequests":128,"periodEnd":"2025-09-01T00:00:00Z"}}}
    """#
    static let gpu = #"{"base":1500,"current":900,"resetsAt":"2025-08-31T18:00:00Z"}"#

    @Test(arguments: BundledPluginTestSupport.engines)
    func `billing and optional quota project through both engines`(engine: ProviderPluginEngineKind) async throws {
        let snapshot = try await Self.fetch(engine: engine)
        #expect(snapshot.primary == nil)
        #expect(snapshot.providerCost?.resetsAt == nil)
        #expect(snapshot.secondary?.usedPercent == 40)
        #expect(abs((snapshot.providerCost?.used ?? -1) - 0.45) < 0.000001)
        #expect(snapshot.providerCost?.limit == 0)
        #expect(snapshot.identity?.providerID == .huggingface)
        #expect(snapshot.identity?.accountID == "fixture-a")
        #expect(snapshot.identity?.loginMethod == "PRO")
        #expect(snapshot.identity?.accountOrganization == nil)
        #expect(snapshot.details[0].rows.map(\.label) == [
            "Billable usage",
            "Gross inference usage",
            "Included inference amount",
            "Requests",
        ])
        #expect(snapshot.details[1].rows.map(\.value) == ["10 min", "15 min"])
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `spend without a denominator has no invented quota`(engine: ProviderPluginEngineKind) async throws {
        let snapshot = try await Self.fetch(
            billing: #"""
            {"usage":{"inferenceProviders":{"usedNanoUsd":300000000,"includedNanoUsd":0,"limitNanoUsd":0}}}
            """#,
            engine: engine,
            optionalStatus: 503)
        #expect(snapshot.primary == nil)
        #expect(snapshot.secondary == nil)
        #expect(snapshot.providerCost?.used == 0.3)
        #expect(snapshot.providerCost?.limit == 0)
        #expect(snapshot.identity == nil)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `reported spending limit remains a detail instead of a credit allowance`(
        engine: ProviderPluginEngineKind) async throws
    {
        let snapshot = try await Self.fetch(
            billing: #"""
            {"usage":{"inferenceProviders":{"usedNanoUsd":1000000000,
            "includedNanoUsd":0,"limitNanoUsd":4000000000}}}
            """#,
            engine: engine)
        #expect(snapshot.primary == nil)
        #expect(snapshot.providerCost?.limit == 4)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `included amount above gross usage never creates a negative charge`(
        engine: ProviderPluginEngineKind) async throws
    {
        let snapshot = try await Self.fetch(
            billing: #"{"usage":{"inferenceProviders":{"usedNanoUsd":100000000,"includedNanoUsd":2000000000}}}"#,
            engine: engine)
        #expect(snapshot.providerCost?.used == 0)
        #expect(snapshot.primary == nil)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `missing deduction cannot silently overstate billable usage`(engine: ProviderPluginEngineKind) async {
        await Self.expectFailure(.parseFailure) {
            try await Self.fetch(
                billing: #"{"usage":{"inferenceProviders":{"usedNanoUsd":100000000}}}"#,
                engine: engine)
        }
    }

    @Test(arguments: ["true", "-1", "\"450000000\"", "1e400", "null"], BundledPluginTestSupport.engines)
    func `malformed required money fails rather than becoming zero`(
        value: String,
        engine: ProviderPluginEngineKind) async
    {
        await Self.expectFailure(.parseFailure) {
            try await Self.fetch(
                billing: "{\"usage\":{\"inferenceProviders\":{\"usedNanoUsd\":\(value)}}}",
                engine: engine)
        }
    }

    @Test(arguments: [
        (401, ProviderFetchClassifiedError.Kind.authenticationExpired),
        (403, .permissionDenied),
        (429, .rateLimited),
        (503, .providerUnavailable)
    ], BundledPluginTestSupport.engines)
    func `billing failures retain actionable classification`(
        failure: (Int, ProviderFetchClassifiedError.Kind),
        engine: ProviderPluginEngineKind) async
    {
        await Self.expectFailure(failure.1) {
            try await Self.fetch(billing: "<html>error</html>", engine: engine, billingStatus: failure.0)
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `identity cache is isolated per token and expires with the fetch clock`(
        engine: ProviderPluginEngineKind) async throws
    {
        let calls = HuggingFaceRequestLog()
        let runtime = try Self.runtime(
            engine: engine,
            billing: Self.billing.replacingOccurrences(of: ",\"periodEnd\":\"2025-09-01T00:00:00Z\"", with: ""),
            calls: calls)
        let first = try await runtime.fetchUsage(secrets: ["HF_TOKEN": "fixture-a"], now: Self.now)
        let other = try await runtime.fetchUsage(secrets: ["HF_TOKEN": "fixture-b"], now: Self.now)
        let again = try await runtime.fetchUsage(
            secrets: ["HF_TOKEN": "fixture-a"],
            now: Self.now.addingTimeInterval(60))
        #expect(first.identity?.accountID == "fixture-a")
        #expect(other.identity?.accountID == "fixture-b")
        #expect(again.identity?.accountID == "fixture-a")
        #expect(await calls.whoamiCount == 2)
        _ = try await runtime.fetchUsage(
            secrets: ["HF_TOKEN": "fixture-a"], now: Self.now.addingTimeInterval(13 * 60 * 60))
        #expect(await calls.whoamiCount == 3)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `report cutoffs and profile dates cannot become quota resets`(
        engine: ProviderPluginEngineKind) async throws
    {
        let calls = HuggingFaceRequestLog()
        let runtime = try BundledPluginTestSupport.runtime(
            "huggingface",
            engine: engine,
            transport: ProviderHTTPTransportHandler { request in
                await calls.append(request)
                let body: String = switch request.url?.path {
                case "/api/settings/billing/usage-v2":
                    await calls.billingCount == 1
                        ? Self.billing
                        : Self.billing.replacingOccurrences(of: "2025-09-01", with: "2025-10-01")
                case "/api/whoami-v2":
                    #"{"name":"fixture-a","periodEnd":1756684800}"#
                default:
                    Self.gpu
                }
                return try Self.response(request, body: body)
            })
        let before = try await runtime.fetchUsage(
            secrets: ["HF_TOKEN": "fixture-a"], now: Date(timeIntervalSince1970: 1_756_684_790))
        let after = try await runtime.fetchUsage(
            secrets: ["HF_TOKEN": "fixture-a"], now: Date(timeIntervalSince1970: 1_756_684_810))
        #expect(before.primary == nil)
        #expect(after.primary == nil)
        #expect(before.providerCost?.resetsAt == nil)
        #expect(after.providerCost?.resetsAt == nil)
        #expect(await calls.whoamiCount == 1)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `profile dates do not imply an inference reset`(engine: ProviderPluginEngineKind) async throws {
        let runtime = try Self.runtime(
            engine: engine,
            billing: Self.billing.replacingOccurrences(of: ",\"periodEnd\":\"2025-09-01T00:00:00Z\"", with: ""))
        let snapshot = try await runtime.fetchUsage(
            secrets: ["HF_TOKEN": "fixture-a"], now: Date(timeIntervalSince1970: 1_756_900_000))
        #expect(snapshot.primary?.resetsAt == nil)
        #expect(snapshot.providerCost?.resetsAt == nil)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `billing request uses UTC month bounds and required authority`(engine: ProviderPluginEngineKind) async throws {
        let calls = HuggingFaceRequestLog()
        let runtime = try Self.runtime(engine: engine, calls: calls)
        _ = try await runtime.fetchUsage(secrets: ["HF_TOKEN": "fixture-a"], now: Self.now)
        let request = try #require(await calls.requests.first)
        #expect(request.url?.host == "huggingface.co")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-a")
        #expect(request.timeoutInterval == 15)
        let url = try #require(request.url)
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(query.first { $0.name == "startDate" }?.value == "1754006400")
        #expect(query.first { $0.name == "endDate" }?.value == "1755000000")
    }

    @Test
    func `retained production strategy caches identities across refreshes`() async throws {
        let calls = HuggingFaceRequestLog()
        let strategy = HuggingFaceScriptFetchStrategy(transport: Self.transport(calls: calls))
        for token in ["fixture-a", "fixture-b", "fixture-a"] {
            let result = try await strategy.fetch(Self.context(token: token))
            #expect(result.usage.identity?.accountID == token)
        }
        #expect(await calls.whoamiCount == 2)
    }

    static func fetch(
        billing: String = Self.billing,
        engine: ProviderPluginEngineKind,
        billingStatus: Int = 200,
        optionalStatus: Int = 200) async throws -> UsageSnapshot
    {
        let runtime = try Self.runtime(
            engine: engine, billing: billing, billingStatus: billingStatus, optionalStatus: optionalStatus)
        return try await runtime.fetchUsage(secrets: ["HF_TOKEN": "fixture-a"], now: Self.now)
    }

    private static func runtime(
        engine: ProviderPluginEngineKind,
        billing: String = Self.billing,
        billingStatus: Int = 200,
        optionalStatus: Int = 200,
        calls: HuggingFaceRequestLog = HuggingFaceRequestLog()) throws -> ProviderPluginRuntime
    {
        try BundledPluginTestSupport.runtime(
            "huggingface",
            engine: engine,
            transport: self.transport(
                billing: billing, billingStatus: billingStatus, optionalStatus: optionalStatus, calls: calls))
    }

    private static func transport(
        billing: String = Self.billing,
        billingStatus: Int = 200,
        optionalStatus: Int = 200,
        calls: HuggingFaceRequestLog) -> ProviderHTTPTransportHandler
    {
        ProviderHTTPTransportHandler { request in
            await calls.append(request)
            let path = request.url?.path
            let isBilling = path == "/api/settings/billing/usage-v2"
            let token = request.value(forHTTPHeaderField: "Authorization")?.replacingOccurrences(
                of: "Bearer ",
                with: "")
                ?? "missing"
            let profile = "{\"name\":\"\(token)\",\"email\":\"tester@example.com\",\"isPro\":true,"
                + "\"periodEnd\":\(token == "fixture-a" ? 1_756_700_000 : 1_756_800_000)}"
            let body = isBilling ? billing : path == "/api/whoami-v2" ? profile : Self.gpu
            return try Self.response(request, body: body, status: isBilling ? billingStatus : optionalStatus)
        }
    }

    private static func response(
        _ request: URLRequest,
        body: String,
        status: Int = 200) throws -> (Data, URLResponse)
    {
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(
            url: url,
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

    private static func context(token: String) -> ProviderFetchContext {
        let environment = ["HF_TOKEN": token]
        return ProviderFetchContext(
            runtime: .app,
            sourceMode: .api,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: environment,
            settings: nil,
            fetcher: UsageFetcher(environment: environment),
            claudeFetcher: HuggingFaceUnusedClaudeFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0))
    }
}

private actor HuggingFaceRequestLog {
    private(set) var requests: [URLRequest] = []
    var whoamiCount: Int {
        self.requests.filter { $0.url?.path == "/api/whoami-v2" }.count
    }

    var billingCount: Int {
        self.requests.filter { $0.url?.path == "/api/settings/billing/usage-v2" }.count
    }

    func append(_ request: URLRequest) { self.requests.append(request) }
}

private struct HuggingFaceUnusedClaudeFetcher: ClaudeUsageFetching {
    func detectVersion() -> String? { nil }
    func loadLatestUsage(model _: String) async throws -> ClaudeUsageSnapshot { throw CancellationError() }
    func debugRawProbe(model _: String) async -> String { "unused" }
}
