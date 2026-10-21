import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct OllamaAPIBalanceTests {
    /// Synthetic values following the response schema reported in #4399; never a live key/account.
    static let fixture = """
    {"included":{"balance_usd":"52.50","allowance_usd":60,
      "period":{"from":"2026-09-30T15:14:29Z","until":"2026-10-30T15:14:29Z"}},
     "purchased":{"balance_usd":"18.25"}}
    """

    @Test(arguments: BundledPluginTestSupport.engines)
    func `API key refresh supplies included usage and purchased balance`(
        engine: ProviderPluginEngineKind) async throws
    {
        let usage = try await Self.fetch(engine: engine)
        #expect(usage.primary?.usedPercent == 12.5)
        #expect(usage.primary?.windowMinutes == ProviderPaceCapability.monthlyWindowSentinelMinutes)
        #expect(usage.primary?.resetsAt == ISO8601DateFormatter().date(from: "2026-10-30T15:14:29Z"))
        #expect(usage.detailRow(label: "Credit balance")?.value == "$18.25")
        #expect(usage.detailRow(label: "Monthly credits used")?.value == "$7.50")
        #expect(usage.details.first?.title == "Credits")
        #expect(usage.identity?.providerID == .ollama)
        #expect(usage.identity?.loginMethod == "API key")
        #expect(usage.identity?.accountEmail == nil)
        #expect(usage.secondary == nil)
        #expect(usage.providerCost == nil)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    @MainActor
    func `API and cookie snapshots share monthly and credit presentation`(
        engine: ProviderPluginEngineKind) async throws
    {
        let html = OllamaCreditWalletTests.wallet
            .replacingOccurrences(of: "$4.50", with: "$7.50") + """
            <div><span>Monthly usage</span><span>$7.50 of $60 used</span>
            <div data-time="2026-10-30T15:14:29Z">Resets in 4 weeks.</div></div>
            """
        let web = try OllamaUsageParser.parse(html: html).toUsageSnapshot()
        let api = try await Self.fetch(engine: engine)
        #expect(api.primary == web.primary)
        #expect(api.details.first?.title == web.details.first?.title)
        for label in ["Credit balance", "Monthly credits used"] {
            #expect(api.detailRow(label: label)?.value == web.detailRow(label: label)?.value)
        }
        #expect(MenuBarLayoutBalanceResolver.balance(provider: .ollama, snapshot: api) == "$18.25")
        #expect(OllamaProviderDescriptor.primaryLabel(window: api.primary) == "Monthly")
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `allowance only and purchased only accounts keep their own measurements`(
        engine: ProviderPluginEngineKind) async throws
    {
        let included = try await Self.fetch(
            #"{"included":{"allowance_usd":"60","balance_usd":45}}"#, engine: engine)
        #expect(included.primary?.usedPercent == 25)
        #expect(included.primary?.resetsAt == nil)
        #expect(included.detailRow(label: "Credit balance") == nil)
        #expect(included.detailRow(label: "Monthly credits used")?.value == "$15.00")
        let purchased = try await Self.fetch(#"{"purchased":{"balance_usd":0}}"#, engine: engine)
        #expect(purchased.primary == nil)
        #expect(purchased.details.first?.rows.map(\.value) == ["$0.00"])
        let zero = try await Self.fetch(
            #"{"included":{"allowance_usd":0,"balance_usd":"0"}}"#, engine: engine)
        #expect(zero.primary == nil)
        #expect(zero.detailRow(label: "Monthly credits used")?.value == "$0.00")
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `decimal amounts and exhausted allowances match cookie percentage clamping`(
        engine: ProviderPluginEngineKind) async throws
    {
        let usage = try await Self.fetch(
            #"{"included":{"allowance_usd":"60.00","balance_usd":"-2.50"},"purchased":{"balance_usd":18.25}}"#,
            engine: engine)
        #expect(usage.primary?.usedPercent == 100)
        #expect(usage.detailRow(label: "Monthly credits used")?.value == "$62.50")
        #expect(usage.detailRow(label: "Credit balance")?.value == "$18.25")
    }

    @Test(arguments: [
        "not-json", "null", "[]", "{}", #"{"included":{}}"#,
        #"{"included":{"allowance_usd":-1,"balance_usd":0}}"#,
        #"{"included":{"allowance_usd":60,"balance_usd":true}}"#,
        #"{"purchased":{"balance_usd":null}}"#, #"{"purchased":{"balance_usd":""}}"#,
        #"{"purchased":{"balance_usd":"0x10"}}"#, #"{"purchased":{"balance_usd":"NaN"}}"#,
        #"{"purchased":{"balance_usd":1e999}}"#, #"{"purchased":{"balance_usd":[]}}"#,
    ], BundledPluginTestSupport.engines)
    func `malformed balances fail safely`(body: String, engine: ProviderPluginEngineKind) async throws {
        do {
            _ = try await Self.fetch(body, engine: engine)
            Issue.record("Expected parse failure")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == .parseFailure)
            #expect(error.message == "Ollama returned an unrecognized credit balance response.")
        }
    }

    @Test(
        arguments: ["2026-10-30", "2026-02-31T12:00:00Z", "2026-99-01T12:00:00Z", "private-response"],
        BundledPluginTestSupport.engines)
    func `malformed supplied resets fail without leaking the response`(
        until: String, engine: ProviderPluginEngineKind) async throws
    {
        let body = Self.fixture.replacingOccurrences(of: "2026-10-30T15:14:29Z", with: until)
        do {
            _ = try await Self.fetch(body, engine: engine)
            Issue.record("Expected parse failure")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == .parseFailure)
            #expect(!error.message.contains(until))
        }
    }

    @Test(arguments: [
        (401, ProviderFetchClassifiedError.Kind.authenticationExpired), (403, .authenticationExpired),
        (429, .rateLimited), (503, .providerUnavailable), (404, .apiFailure),
    ], BundledPluginTestSupport.engines)
    func `HTTP failures classify auth and outages without exposing the response`(
        argument: (Int, ProviderFetchClassifiedError.Kind), engine: ProviderPluginEngineKind) async throws
    {
        do {
            _ = try await Self.fetch("private-response", engine: engine, status: argument.0)
            Issue.record("Expected HTTP failure")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == argument.1)
            #expect(!error.message.contains("private-response"))
            if argument.0 == 401 || argument.0 == 403 {
                #expect(!UsageStore.shouldPreservePriorSnapshot(after: error, hadPriorData: true))
            }
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    @MainActor
    func `transport failures preserve retry and cancellation identity`(engine: ProviderPluginEngineKind) async throws {
        for code in [URLError.Code.timedOut, .notConnectedToInternet, .cancelled] {
            let runtime = try BundledPluginTestSupport.runtime(
                "ollama-api", engine: engine, transport: ProviderHTTPTransportHandler { _ in throw URLError(code) })
            do {
                _ = try await runtime.fetchUsage(secrets: ["OLLAMA_API_KEY": "fixture-key"])
                Issue.record("Expected transport failure")
            } catch {
                if code == .cancelled {
                    #expect(error is CancellationError)
                } else {
                    #expect(UsageStore.shouldPreservePriorSnapshot(after: error, hadPriorData: true))
                    #expect(UsageStore.isStartupConnectivityRetryableError(error))
                }
            }
        }
    }

    @Test
    func `provider API strategy uses the plugin with either key alias`() async throws {
        let browserDetection = BrowserDetection(cacheTTL: 0)
        for key in OllamaAPISettingsReader.apiKeyEnvironmentKeys {
            let context = ProviderFetchContext(
                runtime: .cli,
                sourceMode: .api,
                includeCredits: false,
                webTimeout: 15,
                webDebugDumpHTML: false,
                verbose: false,
                env: [key: "fixture-key"],
                settings: nil,
                fetcher: UsageFetcher(),
                claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
                browserDetection: browserDetection)
            let strategy = OllamaProviderDescriptor.apiStrategy(transport: Self.transport(Self.fixture))
            #expect(await strategy.isAvailable(context))
            let result = try await strategy.fetch(context)
            #expect(result.sourceLabel == "api")
            #expect(result.usage.primary?.usedPercent == 12.5)
        }
    }

    static func fetch(
        _ body: String = Self.fixture,
        engine: ProviderPluginEngineKind,
        status: Int = 200) async throws -> UsageSnapshot
    {
        let runtime = try BundledPluginTestSupport.runtime(
            "ollama-api", engine: engine, transport: Self.transport(body, status: status))
        return try await runtime.fetchUsage(secrets: ["OLLAMA_API_KEY": "fixture-key"])
    }

    static func transport(_ body: String, status: Int = 200) -> ProviderHTTPTransportHandler {
        ProviderHTTPTransportHandler { request in
            #expect(request.url?.absoluteString == "https://ollama.com/api/balance")
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
            #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
            let response = try #require(HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json", "Retry-After": "0"]))
            return (Data(body.utf8), response)
        }
    }
}
