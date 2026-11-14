import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct HostResultProviderTests {
    static let now = Date(timeIntervalSince1970: 1_700_179_200)
    static let spend = #"{"lineItems":[{"totalCost":{"currencyCode":"USD","units":"0","nanos":530000000}},{"totalCost":{"currencyCode":"EUR","units":"20","nanos":0}}]}"#
    static let account = #"{"accounts":[{"name":"accounts/fixture-team"}]}"#
    static let emptyPage = #"{"data":[],"has_more":false}"#

    @Test(arguments: ProviderPluginTransportTests.engines)
    func `Fireworks discovers across pages and returns an allowlisted update`(
        engine: ProviderPluginEngineKind) async throws
    {
        let transport = ResultFixtureTransport([
            .init("/v1/accounts", #"{"accounts":[],"nextPageToken":"page two"}"#),
            .init("/v1/accounts", Self.account), .init("/v1/accounts/fixture-team/billing/summary", Self.spend),
        ])
        let result = try await Self.runtime("fireworks", transport: transport, engine: engine)
            .fetchResult(secrets: ["FIREWORKS_API_KEY": "fixture-key"], now: Self.now.addingTimeInterval(0.125))
        #expect(result.usage.providerCost?.used == 0.53)
        #expect(result.usage.primary == nil && result.usage.identity == nil)
        #expect(result.sourceLabel == "api · fixture-team (auto-discovered)")
        #expect(result.persist == ["ACCOUNT_SLUG": "fixture-team"])
        let requests = await transport.requests
        #expect(Self.query("pageToken", requests[1]) == "page two")
        let end = try #require(Self.query("endTime", requests[2]).flatMap(ISO8601DateParser.parse))
        let start = try #require(Self.query("startTime", requests[2]).flatMap(ISO8601DateParser.parse))
        #expect(end == Self.now && end.timeIntervalSince(start) == 30 * 86400)
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key" })
        #expect(requests.allSatisfy { $0.timeoutInterval <= 15 })
    }

    @Test(arguments: ProviderPluginTransportTests.engines)
    func `Fireworks recovers stale slug and validates empty configured accounts`(
        engine: ProviderPluginEngineKind) async throws
    {
        let recovery = ResultFixtureTransport([
            .init("/v1/accounts/stale/billing/summary", "{}", 404), .init("/v1/accounts", Self.account),
            .init("/v1/accounts/fixture-team/billing/summary", "{}"),
        ])
        let recovered = try await Self.runtime("fireworks", transport: recovery, engine: engine)
            .fetchResult(settings: ["ACCOUNT_SLUG": "stale"], secrets: ["FIREWORKS_API_KEY": "fixture-key"])
        #expect(recovered.persist == ["ACCOUNT_SLUG": "fixture-team"])
        #expect(recovered.usage.providerCost == nil)
        let listed = ResultFixtureTransport([
            .init("/v1/accounts/fixture-team/billing/summary", "{}"), .init("/v1/accounts", Self.account),
        ])
        let result = try await Self.runtime("fireworks", transport: listed, engine: engine)
            .fetchResult(settings: ["ACCOUNT_SLUG": "fixture-team"], secrets: ["FIREWORKS_API_KEY": "fixture-key"])
        #expect(result.persist.isEmpty && result.usage.identity == nil && result.usage.providerCost == nil)
        #expect(result.sourceLabel == "api · fixture-team")
        let unlisted = ResultFixtureTransport([
            .init("/v1/accounts/unknown/billing/summary", "{}"), .init("/v1/accounts", Self.account),
        ])
        await #expect(throws: ProviderFetchClassifiedError.self) {
            try await Self.runtime("fireworks", transport: unlisted, engine: engine)
                .fetchResult(settings: ["ACCOUNT_SLUG": "unknown"], secrets: ["FIREWORKS_API_KEY": "fixture-key"])
        }
    }

    @Test(arguments: ProviderPluginTransportTests.engines)
    func `Fireworks rejects ambiguous malformed and unsafe accounts`(engine: ProviderPluginEngineKind) async throws {
        for body in [#"{"accounts":[]}"#, #"{"accounts":[{"id":"b"},{"id":"a"}]}"#, #"{"accounts":false}"#] {
            let transport = ResultFixtureTransport([.init("/v1/accounts", body)])
            await #expect(throws: ProviderFetchClassifiedError.self) {
                try await Self.runtime("fireworks", transport: transport, engine: engine)
                    .fetchResult(secrets: ["FIREWORKS_API_KEY": "fixture-key"])
            }
        }
        for slug in ["..", ".", "../other", "x?query=y", "x#frag", "x/y"] {
            let transport = ResultFixtureTransport([])
            await #expect(throws: ProviderFetchClassifiedError.self) {
                try await Self.runtime("fireworks", transport: transport, engine: engine)
                    .fetchResult(settings: ["ACCOUNT_SLUG": slug], secrets: ["FIREWORKS_API_KEY": "fixture-key"])
            }
            #expect(await transport.requests.isEmpty)
        }
    }

    @Test(arguments: ProviderPluginTransportTests.engines, [401, 403, 429, 500])
    func `Fireworks classifies HTTP failures`(engine: ProviderPluginEngineKind, status: Int) async throws {
        let transport = ResultFixtureTransport([.init("/v1/accounts", "{}", status)])
        do {
            _ = try await Self.runtime("fireworks", transport: transport, engine: engine)
                .fetchResult(secrets: ["FIREWORKS_API_KEY": "fixture-key"])
            Issue.record("Expected failure")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == (status == 429 ? .rateLimited : status == 500 ? .apiFailure : .authenticationExpired))
        }
    }

    @Test(arguments: [ProviderSettingsSaveOutcome.saved, .unchanged, .stale, .failed])
    func `Fireworks retains usage and source when the host save fails`(
        outcome: ProviderSettingsSaveOutcome) async throws
    {
        let transport = ResultFixtureTransport([
            .init("/v1/accounts", Self.account),
            .init("/v1/accounts/fixture-team/billing/summary", Self.spend),
        ])
        let result = try await FireworksProviderDescriptor.scriptStrategy(transport: transport).fetch(
            Self.context(environment: ["FIREWORKS_KEY": "fixture-key"], writer: { provider, values in
                #expect(provider == .fireworks && values == ["ACCOUNT_SLUG": "fixture-team"])
                return outcome
            }))
        #expect(result.usage.providerCost?.used == 0.53)
        #expect(result.sourceLabel == "api · fixture-team (auto-discovered)")
        #expect((result.diagnostic != nil) == (outcome == .failed || outcome == .stale))
    }

    @Test(arguments: ProviderPluginTransportTests.engines)
    func `OpenAI billing fallback retains balance and source`(engine: ProviderPluginEngineKind) async throws {
        let transport = ResultFixtureTransport([
            .init("/v1/organization/costs", "{}", 403),
            .init(
                "/v1/dashboard/billing/credit_grants",
                #"{"total_granted":100,"total_used":25,"total_available":75,"grants":{"data":[{"expires_at":1800000000},{"expires_at":1}]}}"#),
        ])
        let result = try await Self.runtime("openai", transport: transport, engine: engine).fetchResult(
            settings: ["OPENAI_ALLOW_BALANCE_FALLBACK": "1"], secrets: ["OPENAI_API_KEY": "fixture-key"], now: Self.now)
        #expect(result.sourceLabel == "billing-api" && result.usage.openAIAPIUsage == nil)
        #expect(result.usage.providerCost?.used == 25 && result.usage.primary?.usedPercent == 25)
        #expect(result.usage.identity?.loginMethod == "API balance: $75.00")
        #expect(result.usage.primary?.resetsAt == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(result.usage.details.isEmpty)
    }

    @Test(arguments: ProviderPluginTransportTests.engines)
    func `OpenAI rejects service account billing with useful guidance`(engine: ProviderPluginEngineKind) async throws {
        let transport = ResultFixtureTransport([
            .init("/v1/organization/costs", "{}", 401), .init("/v1/dashboard/billing/credit_grants", "{}", 401),
        ])
        do {
            _ = try await Self.runtime("openai", transport: transport, engine: engine).fetchResult(
                settings: ["OPENAI_ALLOW_BALANCE_FALLBACK": "1"], secrets: ["OPENAI_API_KEY": "fixture-key"])
            Issue.record("Expected authentication error")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == .authenticationExpired)
            #expect(error.message.contains("service-account keys"))
        }
    }

    @Test(arguments: [true, false])
    func `OpenAI configured project preserves scoped source and fallback policy`(adminKey: Bool) async throws {
        let transport = ResultFixtureTransport([
            .init("/v1/organization/costs", Self.emptyPage), .init(
                "/v1/organization/usage/completions",
                Self.emptyPage),
        ])
        let key = adminKey ? "OPENAI_ADMIN_KEY" : "OPENAI_API_KEY"
        let context = Self.context(environment: [key: "fixture-key", "OPENAI_PROJECT_ID": "proj_fixture"])
        let result = try await OpenAIAPIProviderDescriptor.scriptStrategy(transport: transport).fetch(context)
        #expect(result.sourceLabel == "admin-api:project")
        #expect(result.usage.openAIAPIUsage?.projectID == "proj_fixture")
        #expect(result.usage.identity?.accountOrganization == "Project: proj_fixture")
        #expect(await transport.requests.allSatisfy { Self.query("project_ids", $0) == "proj_fixture" })
        let rejected = ResultFixtureTransport([
            .init("/v1/organization/costs", "{}", 403),
            .init(
                "/v1/dashboard/billing/credit_grants",
                #"{"total_granted":100,"total_used":25,"total_available":75}"#),
        ])
        do {
            let fallback = try await OpenAIAPIProviderDescriptor.scriptStrategy(transport: rejected).fetch(context)
            #expect(!adminKey && fallback.sourceLabel == "billing-api")
        } catch let error as ProviderFetchClassifiedError {
            #expect(adminKey && error.kind == .authenticationExpired)
        }
        #expect(await rejected.requests.count == (adminKey ? 1 : 2))
    }

    static func runtime(_ provider: String, transport: any ProviderHTTPTransport, engine: ProviderPluginEngineKind)
        throws -> ProviderPluginRuntime
    {
        try BundledPluginTestSupport.runtime(provider, engine: engine, transport: transport)
    }

    static func context(
        environment: [String: String],
        writer: ProviderFetchContext.SettingsWriter? = nil) -> ProviderFetchContext
    {
        let browser = BrowserDetection(cacheTTL: 0)
        return ProviderFetchContext(
            runtime: .cli,
            sourceMode: .api,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: environment,
            settings: nil,
            fetcher: UsageFetcher(environment: environment),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browser),
            browserDetection: browser,
            settingsWriter: writer)
    }

    static func query(_ key: String, _ request: URLRequest) -> String? {
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == key }?.value
    }
}

actor ResultFixtureTransport: ProviderHTTPTransport {
    struct Step: Sendable {
        let path: String
        let body: String
        let status: Int
        init(_ path: String, _ body: String, _ status: Int = 200) {
            self.path = path
            self.body = body
            self.status = status
        }
    }

    let steps: [Step]
    var requests: [URLRequest] = []
    init(_ steps: [Step]) { self.steps = steps }
    func data(for request: URLRequest) throws -> (Data, URLResponse) {
        let index = self.requests.count
        self.requests.append(request)
        guard self.steps.indices.contains(index) else { throw URLError(.badServerResponse) }
        let step = self.steps[index]
        #expect(request.url?.path == step.path)
        return (Data(step.body.utf8), HTTPURLResponse(
            url: request.url!,
            statusCode: step.status,
            httpVersion: nil,
            headerFields: nil)!)
    }
}

extension HostResultProviderTests {
    @Test(arguments: ProviderPluginTransportTests.engines, [
        "[]", "not json", #"{"lineItems":false}"#, #"{"lineItems":[null]}"#,
        #"{"lineItems":[{"totalCost":{"currencyCode":"USD","units":2,"nanos":0}}]}"#,
        #"{"lineItems":[{"totalCost":{"currencyCode":"USD","units":"2","nanos":0.5}}]}"#,
    ])
    func `Fireworks rejects malformed billing`(engine: ProviderPluginEngineKind, body: String) async throws {
        let transport = ResultFixtureTransport([.init("/v1/accounts/fixture-team/billing/summary", body)])
        await #expect(throws: ProviderFetchClassifiedError.self) {
            try await Self.runtime("fireworks", transport: transport, engine: engine).fetchResult(
                settings: ["ACCOUNT_SLUG": "fixture-team"], secrets: ["FIREWORKS_API_KEY": "fixture-key"])
        }
    }

    @Test(arguments: ProviderPluginTransportTests.engines)
    func `Fireworks keeps rated zero and rejects repeated discovery pages`(
        engine: ProviderPluginEngineKind) async throws
    {
        let transport = ResultFixtureTransport([.init(
            "/v1/accounts/fixture-team/billing/summary",
            #"{"lineItems":[{"totalCost":{"currencyCode":"USD","units":"0","nanos":0}}]}"#)])
        let result = try await Self.runtime("fireworks", transport: transport, engine: engine).fetchResult(
            settings: ["ACCOUNT_SLUG": "fixture-team"], secrets: ["FIREWORKS_API_KEY": "fixture-key"])
        #expect(result.usage.providerCost?.used == 0 && result.persist.isEmpty)
        #expect(result.sourceLabel == "api · fixture-team")
        #expect(await transport.requests.count == 1)
        let repeated = ResultFixtureTransport([
            .init("/v1/accounts", #"{"accounts":[],"nextPageToken":"same"}"#),
            .init("/v1/accounts", #"{"accounts":[],"nextPageToken":"same"}"#),
        ])
        await #expect(throws: ProviderFetchClassifiedError.self) {
            try await Self.runtime("fireworks", transport: repeated, engine: engine)
                .fetchResult(secrets: ["FIREWORKS_API_KEY": "fixture-key"])
        }
        #expect(await repeated.requests.count == 2)
    }

    @Test
    func `missing persistence writer preserves discovered usage with a diagnostic`() async throws {
        let transport = ResultFixtureTransport([
            .init("/v1/accounts", Self.account),
            .init("/v1/accounts/fixture-team/billing/summary", Self.spend),
        ])
        let result = try await FireworksProviderDescriptor.scriptStrategy(transport: transport).fetch(
            Self.context(environment: ["FIREWORKS_API_KEY": "fixture-key"]))
        #expect(result.usage.providerCost?.used == 0.53)
        #expect(result.diagnostic?.contains("could not be saved") == true)
    }
}

extension HostResultProviderTests {
    @Test(arguments: ProviderPluginTransportTests.engines)
    func `OpenAI preserves non-auth usage failures when billing also fails`(
        engine: ProviderPluginEngineKind) async throws
    {
        let transport = ResultFixtureTransport([
            .init("/v1/organization/costs", "<html>unavailable</html>", 418),
            .init("/v1/dashboard/billing/credit_grants", "<html>forbidden</html>", 403),
        ])
        do {
            _ = try await Self.runtime("openai", transport: transport, engine: engine).fetchResult(
                settings: ["OPENAI_ALLOW_BALANCE_FALLBACK": "1"], secrets: ["OPENAI_API_KEY": "fixture-key"])
            Issue.record("Expected usage failure")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == .apiFailure && error.message.contains("418"))
        }
    }

    @Test(arguments: ProviderPluginTransportTests.engines)
    func `OpenAI scoped outage retries without unscoped billing`(engine: ProviderPluginEngineKind) async throws {
        let transport = ResultFixtureTransport([
            .init("/v1/organization/costs", "<html>unavailable</html>", 503),
            .init("/v1/organization/costs", "<html>unavailable</html>", 503),
        ])
        await #expect(throws: ProviderFetchClassifiedError.self) {
            try await Self.runtime("openai", transport: transport, engine: engine).fetchResult(
                settings: ["OPENAI_PROJECT_ID": "proj_fixture", "OPENAI_ALLOW_BALANCE_FALLBACK": "0"],
                secrets: ["OPENAI_API_KEY": "fixture-key"])
        }
        #expect(await transport.requests.count == 2)
    }
}

extension HostResultProviderTests {
    @Test(arguments: ProviderPluginTransportTests.engines)
    func `OpenAI queries and filters buckets using the refresh clock`(engine: ProviderPluginEngineKind) async throws {
        let future = Int(Self.now.timeIntervalSince1970) + 86400
        let body = """
        {"data":[{"start_time":\(future),"end_time":\(future + 86400),
          "results":[{"amount":{"value":1,"currency":"usd"}}]}],"has_more":false}
        """
        let transport = ResultFixtureTransport([
            .init("/v1/organization/costs", body), .init("/v1/organization/usage/completions", Self.emptyPage),
        ])
        let result = try await Self.runtime("openai", transport: transport, engine: engine).fetchResult(
            settings: ["OPENAI_HISTORY_DAYS": "1"], secrets: ["OPENAI_API_KEY": "fixture-key"], now: Self.now)
        #expect(result.usage.openAIAPIUsage?.daily.isEmpty == true)
        let requests = await transport.requests
        #expect(Self.query("start_time", requests[0]) == String(Int(Self.now.timeIntervalSince1970)))
    }
}
