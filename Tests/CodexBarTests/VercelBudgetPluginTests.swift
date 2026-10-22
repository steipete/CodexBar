import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct VercelBudgetPluginTests {
    static let settings = ["VERCEL_TEAM_ID": "team_fixture"]
    static let secrets = ["VERCEL_ACCESS_TOKEN": "fixture-token"]
    /// Wednesday, 2026-10-14 12:00 UTC.
    static let now = Date(timeIntervalSince1970: 1_791_979_200)
    static let user = #"{"user":{"id":"fixtureUser","email":"fixture@example.com"}}"#

    static func budget(
        _ user: String = "usr_fixtureUser",
        spend: String = "30",
        limit: String = "120",
        period: String = "monthly",
        source: String? = nil) -> String
    {
        """
        {"scopeType":"user","scopeId":"\(user)","currentSpend":\(spend),"limitAmount":\(limit),\
        "refreshPeriod":"\(period)","active":true,"archived":false\(source.map { ",\"source\":\"\($0)\"" } ?? "")}
        """
    }

    static func page(_ budgets: [String], next: String? = nil) -> String {
        #"{"budgets":[\#(budgets.joined(separator: ","))]\#(next.map { #","nextCursor":"\#($0)""# } ?? "")}"#
    }

    /// Serves `/v2/user`, then budget pages keyed by the request's cursor (`""` for the first page).
    static func transport(
        pages: [String: String],
        recorder: Recorder = Recorder()) -> ProviderHTTPTransportHandler
    {
        ProviderHTTPTransportHandler { request in
            recorder.append(request)
            let url = try #require(request.url)
            #expect(url.host == "api.vercel.com")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token")
            if url.path == "/v2/user" { return try Self.response(request, body: Self.user) }
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            #expect(items.first { $0.name == "teamId" }?.value == "team_fixture")
            #expect(items.first { $0.name == "scopeType" }?.value == "user")
            let cursor = items.first { $0.name == "cursor" }?.value ?? ""
            return try Self.response(request, body: #require(pages[cursor]))
        }
    }

    static func fetch(
        pages: [String: String],
        engine: ProviderPluginEngineKind = .quickJS,
        settings: [String: String] = Self.settings,
        recorder: Recorder = Recorder()) async throws -> UsageSnapshot
    {
        let runtime = try BundledPluginTestSupport.runtime(
            "vercel-budget", engine: engine, transport: Self.transport(pages: pages, recorder: recorder))
        return try await runtime.fetchUsage(settings: settings, secrets: Self.secrets, now: Self.now)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `own custom budget wins across pages and other users are ignored`(
        engine: ProviderPluginEngineKind) async throws
    {
        let recorder = Recorder()
        let first = [
            Self.budget("user_other", spend: "1", limit: "2"),
            Self.budget(spend: "5", limit: "50", source: "default"),
        ]
        let pages = ["": Self.page(first, next: "page 2"), "page 2": Self.page([Self.budget()])]
        let snapshot = try await Self.fetch(pages: pages, engine: engine, recorder: recorder)
        #expect(snapshot.primary?.usedPercent == 25)
        #expect(snapshot.primary?.resetDescription == "$30.00 / $120.00")
        #expect(snapshot.details.first?.title == "Personal budget")
        #expect(snapshot.details.first?.rows.map(\.value) == ["$30.00", "$120.00", "$90.00"])
        #expect(snapshot.details.first?.rows.map(\.label) == ["Spend", "Limit", "Remaining"])
        #expect(snapshot.identity?.accountID == "fixtureUser")
        #expect(snapshot.identity?.accountOrganization == "team_fixture")
        #expect(snapshot.dataConfidence == .exact)
        #expect(recorder.all.compactMap(\.url?.path) == [
            "/v2/user",
            "/ai-gateway/budgets/list",
            "/ai-gateway/budgets/list",
        ])
    }

    @Test
    func `native user scope IDs remain supported`() async throws {
        let snapshot = try await Self.fetch(pages: ["": Self.page([Self.budget("fixtureUser")])])
        #expect(snapshot.primary?.usedPercent == 25)
        #expect(snapshot.identity?.accountID == "fixtureUser")
    }

    @Test(arguments: [
        ("daily", 1440, "2026-10-15T00:00:00Z"),
        ("weekly", 10080, "2026-10-19T00:00:00Z"),
        ("monthly", 44640, "2026-11-01T00:00:00Z"),
    ])
    func `documented UTC refresh boundaries set the reset`(
        period: String, minutes: Int, reset: String) async throws
    {
        let snapshot = try await Self.fetch(pages: ["": Self.page([Self.budget(period: period)])])
        #expect(snapshot.primary?.windowMinutes == minutes)
        #expect(snapshot.primary?.resetsAt == ISO8601DateFormatter().date(from: reset))
    }

    @Test
    func `cumulative budget has no reset and missing budget is not zero`() async throws {
        let cumulative = try await Self.fetch(pages: ["": Self.page([Self.budget(period: "none")])])
        #expect(cumulative.primary?.resetsAt == nil)
        #expect(cumulative.primary?.windowMinutes == nil)

        let missing = try await Self.fetch(pages: ["": Self.page([Self.budget("user_other")])])
        #expect(missing.primary == nil)
        #expect(missing.details.first?.rows.first?.label == "No personal budget configured")
        #expect(missing.details.first?.rows.first?.value == "—")
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `malformed own budget cannot masquerade as not configured`(engine: ProviderPluginEngineKind) async throws {
        let malformed = Self.budget().replacingOccurrences(of: "\"active\":true,", with: "")
        do {
            _ = try await Self.fetch(pages: ["": Self.page([malformed])], engine: engine)
            Issue.record("Expected malformed own budget to fail closed")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == .parseFailure)
        }
    }

    @Test(arguments: [
        ("repeated cursor", ["": Self.page([], next: "a"), "a": Self.page([], next: "a")]),
        ("ambiguous custom", ["": Self.page([Self.budget(), Self.budget()])]),
        ("negative spend", ["": Self.page([Self.budget(spend: "-1")])]),
        ("zero limit", ["": Self.page([Self.budget(limit: "0")])]),
        ("unknown period", ["": Self.page([Self.budget(period: "hourly")])]),
        ("missing list", ["": #"{"nextCursor":null}"#]),
        ("malformed", ["": "private-response"]),
    ])
    func `malformed or incomplete budgets fail closed`(name: String, pages: [String: String]) async throws {
        do {
            _ = try await Self.fetch(pages: pages)
            Issue.record("Expected \(name) to fail")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == .parseFailure)
            #expect(!error.message.contains("private-response"))
        }
    }

    @Test
    func `pagination stops after twenty pages`() async throws {
        let recorder = Recorder()
        var pages = ["": Self.page([], next: "c1")]
        for index in 1...25 {
            pages["c\(index)"] = Self.page([], next: "c\(index + 1)")
        }
        await #expect(throws: ProviderFetchClassifiedError.self) {
            try await Self.fetch(pages: pages, recorder: recorder)
        }
        #expect(recorder.all.count == 21)
    }

    @Test
    func `HTTP failures expose status without response bodies`() async throws {
        for (code, kind) in [
            (401, ProviderFetchClassifiedError.Kind.authenticationExpired), (403, .permissionDenied),
            (429, .rateLimited), (503, .providerUnavailable), (400, .apiFailure),
        ] {
            let runtime = try BundledPluginTestSupport.runtime(
                "vercel-budget", engine: .quickJS, transport: ProviderHTTPTransportHandler { request in
                    try Self.response(request, body: "private-response", status: code)
                })
            do {
                _ = try await runtime.fetchUsage(settings: Self.settings, secrets: Self.secrets)
                Issue.record("Expected HTTP \(code) to fail")
            } catch let error as ProviderFetchClassifiedError {
                #expect(error.kind == kind)
                #expect(error.message.contains("HTTP \(code)"))
                #expect(!error.message.contains("private-response"))
            }
        }
    }

    @Test
    func `missing team fails before any request`() async throws {
        let recorder = Recorder()
        do {
            _ = try await Self.fetch(pages: [:], settings: [:], recorder: recorder)
            Issue.record("Expected a missing team ID to fail")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == .missingCredential)
        }
        #expect(recorder.all.isEmpty)
    }

    @Test
    func `token cannot reach the gateway origin`() async throws {
        let url = try #require(CodexBarCoreResources.bundle?.url(forResource: "vercel-budget", withExtension: "js"))
        let source = try String(contentsOf: url, encoding: .utf8).replacingOccurrences(
            of: #"read("https://api.vercel.com/v2/user")"#, with: #"read("https://ai-gateway.vercel.sh/v1/credits")"#)
        let transport = ProviderHTTPTransportHandler { request in
            Issue.record("Unexpected request to \(request.url?.absoluteString ?? "")")
            return try Self.response(request, body: "{}")
        }
        let runtime = try ProviderPluginRuntime(source: source, transport: transport, engine: .quickJS)
        do {
            _ = try await runtime.fetchUsage(settings: Self.settings, secrets: Self.secrets)
            Issue.record("Expected the undeclared gateway origin to be rejected")
        } catch let ProviderPluginError.script(message) {
            #expect(message.contains("origin 'https://ai-gateway.vercel.sh' is not declared"))
        }
    }

    @Test
    func `configured token selects the budget script even without a gateway key`() async throws {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .vercel)
        let config = ProviderConfig(
            id: UsageProvider.vercel.instanceID,
            workspaceID: "team_fixture",
            pluginSecrets: ["VERCEL_ACCESS_TOKEN": "fixture-token"])
        let environment = try #require(descriptor.credentials).applyConfig(base: [:], config: config)
        #expect(environment["VERCEL_ACCESS_TOKEN"] == "fixture-token")
        #expect(environment["VERCEL_TEAM_ID"] == "team_fixture")
        #expect(environment["AI_GATEWAY_API_KEY"] == nil)

        let tokenOnly = ProviderCutoverTestSupport.context(environment: environment)
        let strategies = await descriptor.fetchPlan.pipeline.resolveStrategies(tokenOnly)
        #expect(strategies.map(\.id) == ["vercel-budget.js"])
        let keyOnly = ProviderCutoverTestSupport.context(environment: ["AI_GATEWAY_API_KEY": "fixture-gateway"])
        #expect(await descriptor.fetchPlan.pipeline.resolveStrategies(keyOnly).map(\.id) == ["vercel.js"])

        let strategy = VercelProviderDescriptor.budgetStrategy(transport: Self.transport(pages: [
            "": Self.page([Self.budget()]),
        ]))
        #expect(await strategy.isAvailable(tokenOnly))
        let result = try await strategy.fetch(tokenOnly)
        #expect(result.strategyID == "vercel-budget.js")
        #expect(result.usage.identity?.providerID == .vercel)
        #expect(result.usage.primary?.usedPercent == 25)
    }

    static func response(_ request: URLRequest, body: String, status: Int = 200) throws -> (Data, URLResponse) {
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]))
        return (Data(body.utf8), response)
    }

    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [URLRequest] = []

        func append(_ request: URLRequest) {
            self.lock.withLock { self.requests.append(request) }
        }

        var all: [URLRequest] {
            self.lock.withLock { self.requests }
        }
    }
}
