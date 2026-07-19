import CodexBarCore
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCLI

/// Fixtures below were captured verbatim from a locally running Wayfinder gateway
/// (`wayfinder-router serve`, two-tier priced config) after routing real traffic.
struct WayfinderProviderLinuxTests {
    @Test
    func `assembles a snapshot from live gateway payloads`() throws {
        let snapshot = try Self.makeSnapshot()

        #expect(snapshot.gatewayStatus == "ok")
        #expect(!snapshot.offline)
        #expect(!snapshot.dryRun)
        #expect(snapshot.missingKeys.isEmpty)
        #expect(snapshot.modelCount == 2)
        #expect(snapshot.requests == 14)
        #expect(snapshot.tokens == 1028)
        #expect(snapshot.priced)
        #expect(snapshot.saved == 0.005694)
        #expect(snapshot.savedPct == 61.5)
        #expect(snapshot.routes.map(\.name) == ["local", "cloud"])
        #expect(snapshot.routes.first { $0.name == "local" }?.requests == 10)
        #expect(snapshot.routes.first { $0.name == "cloud" }?.requests == 4)
        #expect(snapshot.statusLabel == "Local gateway")
        #expect(snapshot.gatewaySummary == "ok · 2 models")
        #expect(snapshot.displayLines == [
            "Gateway: ok · 2 models",
            "Routed: local: 10 · cloud: 4",
            "Saved: <$0.01 · 61.5% vs highest-cost route",
            "Avg decision: 0.1 ms",
        ])

        let avgMs = try #require(snapshot.avgDecisionMs)
        #expect(abs(avgMs - 0.0804) < 0.001)
    }

    @Test
    func `maps the snapshot onto the shared usage snapshot`() throws {
        let usage = try Self.makeSnapshot().toUsageSnapshot()

        #expect(usage.primary == nil)
        #expect(usage.secondary == nil)
        #expect(usage.providerCost == nil)
        #expect(usage.identity?.providerID == .wayfinder)
        #expect(usage.identity?.accountEmail == nil)
        #expect(usage.identity?.accountOrganization == "2 models · local gateway")
        #expect(usage.identity?.loginMethod == "Local gateway")
        #expect(usage.dataConfidence == .exact)
    }

    @Test
    func `degraded health reports the missing key count`() throws {
        let snapshot = try Self.makeSnapshot(healthData: Self.healthDegraded)
        #expect(snapshot.gatewayStatus == "degraded")
        #expect(snapshot.missingKeys == ["cloud"])
        #expect(snapshot.statusLabel == "Degraded — 1 key missing")
    }

    @Test
    func `empty savings suppress the routed and saved summaries`() throws {
        let snapshot = try Self.makeSnapshot(savingsData: Self.savingsZeros)
        #expect(snapshot.requests == 0)
        #expect(snapshot.routedSummary == nil)
        #expect(snapshot.savedSummary == nil)
        #expect(snapshot.toUsageSnapshot().providerCost == nil)
    }

    @Test
    func `unpriced savings never render dollars`() throws {
        let snapshot = try Self.makeSnapshot(savingsData: Self.savingsUnpriced)
        #expect(!snapshot.priced)
        #expect(snapshot.savedSummary == "40% vs highest-cost route")
        #expect(snapshot.toUsageSnapshot().providerCost == nil)
    }

    @Test
    func `sub-cent priced savings render below one cent`() throws {
        let snapshot = try Self.makeSnapshot()
        #expect(snapshot.routedSummary == "local: 10 · cloud: 4")
        #expect(snapshot.savedSummary == "<$0.01 · 61.5% vs highest-cost route")
        #expect(snapshot.avgDecisionSummary == "0.1 ms")
    }

    @Test
    func `metrics parsing is best effort`() throws {
        #expect(WayfinderUsageFetcher._averageDecisionMillisecondsForTesting("") == nil)
        #expect(WayfinderUsageFetcher._averageDecisionMillisecondsForTesting("garbage\nlines\n") == nil)
        #expect(WayfinderUsageFetcher._averageDecisionMillisecondsForTesting(
            "wayfinder_router_decision_latency_seconds_sum 1.5\n") == nil)
        #expect(WayfinderUsageFetcher._averageDecisionMillisecondsForTesting(
            "wayfinder_router_decision_latency_seconds_sum 1.5\n" +
                "wayfinder_router_decision_latency_seconds_count 0\n") == nil)

        let labeled = WayfinderUsageFetcher._averageDecisionMillisecondsForTesting(
            "wayfinder_router_decision_latency_seconds_sum{route=\"all\"} 2.0\n" +
                "wayfinder_router_decision_latency_seconds_count{route=\"all\"} 4\n")
        #expect(labeled == 500)

        let snapshot = try Self.makeSnapshot(metricsText: nil)
        #expect(snapshot.avgDecisionMs == nil)
        #expect(snapshot.avgDecisionSummary == nil)
    }

    @Test
    func `endpoint URLs preserve prefixes and trailing slashes`() throws {
        func endpoint(_ base: String, _ path: String) throws -> String {
            try WayfinderUsageFetcher._endpointURLForTesting(
                baseURL: #require(URL(string: base)),
                path: path).absoluteString
        }
        #expect(try endpoint("http://127.0.0.1:8088", "healthz") == "http://127.0.0.1:8088/healthz")
        #expect(try endpoint("http://127.0.0.1:8088/", "healthz") == "http://127.0.0.1:8088/healthz")
        #expect(try endpoint("https://wayfinder.example.com/wf", "v1/savings") ==
            "https://wayfinder.example.com/wf/v1/savings")
    }

    @Test
    func `gateway URL override allows loopback HTTP and rejects remote HTTP`() throws {
        let key = WayfinderSettingsReader.baseURLEnvironmentKey

        try WayfinderSettingsReader.validateEndpointOverride(environment: [key: "http://127.0.0.1:9090"])
        try WayfinderSettingsReader.validateEndpointOverride(environment: [key: "http://localhost:8088"])
        try WayfinderSettingsReader.validateEndpointOverride(environment: [key: "https://wayfinder.example.com"])
        #expect(WayfinderSettingsReader.baseURL(environment: [key: "http://127.0.0.1:9090"]).absoluteString ==
            "http://127.0.0.1:9090")

        #expect(throws: WayfinderSettingsError.invalidEndpointOverride(key)) {
            try WayfinderSettingsReader.validateEndpointOverride(environment: [key: "http://192.168.1.5:8088"])
        }
        #expect(throws: WayfinderSettingsError.invalidEndpointOverride(key)) {
            try WayfinderSettingsReader.validateEndpointOverride(environment: [key: "http://user@127.0.0.1:8088"])
        }
        #expect(WayfinderSettingsReader.baseURL(environment: [key: "http://attacker.test"]) ==
            WayfinderSettingsReader.defaultBaseURL)
        #expect(WayfinderSettingsReader.baseURL(environment: [:]) == WayfinderSettingsReader.defaultBaseURL)
    }

    @Test
    func `dashboard URL follows the configured gateway and preserves its prefix`() {
        let key = WayfinderSettingsReader.baseURLEnvironmentKey

        #expect(WayfinderSettingsReader.dashboardURL(environment: [:]).absoluteString ==
            "http://127.0.0.1:8088/router")
        #expect(WayfinderSettingsReader.dashboardURL(
            environment: [key: "http://localhost:9191/wayfinder/"]).absoluteString ==
            "http://localhost:9191/wayfinder/router")
    }

    @Test
    func `config projects the gateway URL into the fetch environment`() {
        let config = ProviderConfig(id: .wayfinder, enterpriseHost: "http://localhost:9099")
        let environment = ProviderConfigEnvironment.applyProviderConfigOverrides(
            base: [:],
            provider: .wayfinder,
            config: config)

        #expect(environment[WayfinderSettingsReader.baseURLEnvironmentKey] == "http://localhost:9099")
        #expect(WayfinderSettingsReader.baseURL(environment: environment).absoluteString == "http://localhost:9099")
    }

    @Test
    func `descriptor is registered`() {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .wayfinder)
        #expect(descriptor.metadata.displayName == "Wayfinder")
        #expect(descriptor.metadata.cliName == "wayfinder")
        #expect(descriptor.cli.aliases.contains("wayfinder-router"))
        #expect(!descriptor.metadata.defaultEnabled)
    }

    @Test
    func `usage snapshot preserves Wayfinder detail when cached`() throws {
        let snapshot = try Self.makeSnapshot()
        let encoded = try JSONEncoder().encode(snapshot.toUsageSnapshot())
        let decoded = try JSONDecoder().decode(UsageSnapshot.self, from: encoded)

        #expect(decoded.wayfinderUsage == snapshot)
        #expect(decoded.identity?.providerID == .wayfinder)
    }

    @Test
    func `fetch polls only the documented read-only endpoints`() async throws {
        let log = RequestLog()
        let transport = ProviderHTTPTransportHandler { request in
            let url = try #require(request.url)
            log.append(url)
            #expect(request.httpMethod == "GET")
            let body: Data = switch url.path {
            case "/healthz": Self.healthOK
            case "/router/models": Self.models
            case "/v1/savings": Self.savings30d
            case "/metrics": Data(Self.metricsText.utf8)
            default: Data()
            }
            let response = try #require(HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil))
            return (body, response)
        }

        let snapshot = try await WayfinderUsageFetcher.fetchUsage(
            baseURL: #require(URL(string: "http://127.0.0.1:8088")),
            transport: transport)

        #expect(snapshot.requests == 14)
        #expect(log.paths() == ["/healthz", "/router/models", "/v1/savings", "/metrics"])
        #expect(log.queries().contains("period=30d"))
    }

    @Test
    func `fetch maps HTTP failures to actionable errors`() async throws {
        let failing = ProviderHTTPTransportHandler { _ in
            throw URLError(.cannotConnectToHost)
        }
        await #expect(throws: WayfinderUsageError.gatewayUnreachable) {
            _ = try await WayfinderUsageFetcher.fetchUsage(
                baseURL: #require(URL(string: "http://127.0.0.1:8088")),
                transport: failing)
        }

        let serverError = ProviderHTTPTransportHandler { request in
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: url,
                statusCode: 500,
                httpVersion: nil,
                headerFields: nil))
            return (Data(), response)
        }
        await #expect(throws: WayfinderUsageError.apiError(500)) {
            _ = try await WayfinderUsageFetcher.fetchUsage(
                baseURL: #require(URL(string: "http://127.0.0.1:8088")),
                transport: serverError)
        }
    }

    @Test
    func `required request cancellation remains cancellation`() async throws {
        for error in [CancellationError() as any Error, URLError(.cancelled) as any Error] {
            let cancelling = ProviderHTTPTransportHandler { _ in throw error }
            await #expect(throws: CancellationError.self) {
                _ = try await WayfinderUsageFetcher.fetchUsage(
                    baseURL: #require(URL(string: "http://127.0.0.1:8088")),
                    transport: cancelling)
            }
        }
    }

    @Test
    func `optional metrics cancellation remains cancellation`() async throws {
        let cancelling = ProviderHTTPTransportHandler { request in
            let url = try #require(request.url)
            if url.path == "/metrics" {
                throw CancellationError()
            }
            let body: Data = switch url.path {
            case "/healthz": Self.healthOK
            case "/router/models": Self.models
            case "/v1/savings": Self.savings30d
            default: Data()
            }
            let response = try #require(HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil))
            return (body, response)
        }

        await #expect(throws: CancellationError.self) {
            _ = try await WayfinderUsageFetcher.fetchUsage(
                baseURL: #require(URL(string: "http://127.0.0.1:8088")),
                transport: cancelling)
        }
    }

    @Test
    func `fetch rejects responses from a different origin`() async throws {
        let redirecting = ProviderHTTPTransportHandler { _ in
            let elsewhere = try #require(URL(string: "http://attacker.test/healthz"))
            let response = try #require(HTTPURLResponse(
                url: elsewhere,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil))
            return (Self.healthOK, response)
        }
        await #expect(throws: WayfinderUsageError.unexpectedRedirect) {
            _ = try await WayfinderUsageFetcher.fetchUsage(
                baseURL: #require(URL(string: "http://127.0.0.1:8088")),
                transport: redirecting)
        }
    }

    @Test
    func `text CLI renders gateway health routed split savings and latency`() throws {
        let output = try CLIRenderer.renderText(
            provider: .wayfinder,
            snapshot: Self.makeSnapshot().toUsageSnapshot(),
            credits: nil,
            context: RenderContext(
                header: "Wayfinder (api)",
                status: nil,
                useColor: false,
                resetStyle: .countdown))

        #expect(output.contains("Gateway: ok · 2 models"))
        #expect(output.contains("Routed: local: 10 · cloud: 4"))
        #expect(output.contains("Saved: <$0.01 · 61.5% vs highest-cost route"))
        #expect(output.contains("Avg decision: 0.1 ms"))
        #expect(!output.contains("Cost:"))
    }

    @Test
    func `routed summary reflects request counts regardless of configured model order`() throws {
        // The heavier-traffic route ("primary-tier") is configured SECOND in /router/models,
        // and the lighter one ("secondary-tier") FIRST — proving nothing in the summary is
        // derived from array position (the gateway's config order is not a semantic signal).
        let reorderedModels = Data("""
        {"models":[{"name":"secondary-tier","endpoint":"http://127.0.0.1:9102/v1",\
        "model":"stand-in-large","api_key_env":"RIG_CLOUD_KEY","key_ok":true},\
        {"name":"primary-tier","endpoint":"http://127.0.0.1:9101/v1","model":"stand-in-small",\
        "api_key_env":null,"key_ok":true}],"dry_run":false}
        """.utf8)
        let snapshot = try Self.makeSnapshot(modelsData: reorderedModels)

        #expect(snapshot.routedSummary == "local: 10 · cloud: 4")
        #expect(snapshot.routes.first?.name == "local")
    }

    @Test
    func `routed summary uses the gateway's own route names, not a hardcoded local or cloud label`() throws {
        // Route names are whatever the user named their endpoints in the Wayfinder config —
        // there is no "local"/"cloud" semantic anywhere in the gateway's JSON.
        let customNamedSavings = Data("""
        {"period_days":30,"unit":"usd","priced":true,"requests":14,"estimated_requests":0,\
        "tokens":1028,"realized":0.003558,"baseline":0.009252,"saved":0.005694,"saved_pct":61.5,\
        "by_route":{"groq-8b":{"requests":10,"realized":0.000264,"baseline":0.005958,\
        "saved":0.005694,"tokens":662},"openai-o1":{"requests":4,"realized":0.003294,\
        "baseline":0.003294,"saved":0.0,"tokens":366}},"by_key":{},\
        "price_table_version":"a3db80fd9a78"}
        """.utf8)
        let snapshot = try Self.makeSnapshot(savingsData: customNamedSavings)
        let summary = try #require(snapshot.routedSummary)

        #expect(summary == "groq-8b: 10 · openai-o1: 4")
        #expect(!summary.contains("local"))
        #expect(!summary.contains("cloud"))
    }

    // MARK: - Helpers

    private static func makeSnapshot(
        healthData: Data = Self.healthOK,
        modelsData: Data = Self.models,
        savingsData: Data = Self.savings30d,
        metricsText: String? = Self.metricsText) throws -> WayfinderUsageSnapshot
    {
        try WayfinderUsageFetcher._makeSnapshotForTesting(
            healthData: healthData,
            modelsData: modelsData,
            savingsData: savingsData,
            metricsText: metricsText,
            updatedAt: Date(timeIntervalSince1970: 1))
    }

    private final class RequestLog: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL] = []

        func append(_ url: URL) {
            self.lock.lock()
            defer { self.lock.unlock() }
            self.urls.append(url)
        }

        func paths() -> [String] {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.urls.map(\.path)
        }

        func queries() -> [String] {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.urls.compactMap(\.query)
        }
    }

    // MARK: - Fixtures (captured from a live gateway)

    private static let healthOK = Data("""
    {"status":"ok","models":["cloud","local"],"offline":false}
    """.utf8)

    private static let healthDegraded = Data("""
    {"status":"degraded","models":["cloud","local"],"offline":false,"missing_keys":["cloud"]}
    """.utf8)

    private static let models = Data("""
    {"models":[{"name":"local","endpoint":"http://127.0.0.1:9101/v1","model":"stand-in-small",\
    "api_key_env":null,"key_ok":true},{"name":"cloud","endpoint":"http://127.0.0.1:9102/v1",\
    "model":"stand-in-large","api_key_env":"RIG_CLOUD_KEY","key_ok":true}],"dry_run":false}
    """.utf8)

    private static let savings30d = Data("""
    {"period_days":30,"unit":"usd","priced":true,"requests":14,"estimated_requests":0,\
    "tokens":1028,"realized":0.003558,"baseline":0.009252,"saved":0.005694,"saved_pct":61.5,\
    "by_route":{"cloud":{"requests":4,"realized":0.003294,"baseline":0.003294,"saved":0.0,\
    "tokens":366},"local":{"requests":10,"realized":0.000264,"baseline":0.005958,\
    "saved":0.005694,"tokens":662}},"by_key":{},"price_table_version":"a3db80fd9a78"}
    """.utf8)

    private static let savingsZeros = Data("""
    {"period_days":30,"unit":"usd","priced":true,"requests":0,"estimated_requests":0,\
    "tokens":0,"realized":0.0,"baseline":0.0,"saved":0.0,"saved_pct":0.0,"by_route":{},\
    "by_key":{},"price_table_version":"a3db80fd9a78"}
    """.utf8)

    private static let savingsUnpriced = Data("""
    {"period_days":30,"unit":"relative","priced":false,"requests":5,"estimated_requests":0,\
    "tokens":420,"realized":1.8,"baseline":3.0,"saved":1.2,"saved_pct":40.0,\
    "by_route":{"local":{"requests":4,"realized":0.8,"baseline":2.0,"saved":1.2,"tokens":320},\
    "cloud":{"requests":1,"realized":1.0,"baseline":1.0,"saved":0.0,"tokens":100}},\
    "by_key":{},"price_table_version":"a3db80fd9a78"}
    """.utf8)

    private static let metricsText = """
    # HELP wayfinder_router_requests_total Routed requests by model and mode.
    # TYPE wayfinder_router_requests_total counter
    wayfinder_router_requests_total{model="local",mode="scored"} 10
    wayfinder_router_requests_total{model="cloud",mode="scored"} 4
    # HELP wayfinder_router_decision_latency_seconds Time to score a prompt and pick a model (no model call).
    # TYPE wayfinder_router_decision_latency_seconds histogram
    wayfinder_router_decision_latency_seconds_bucket{le="0.0001"} 13
    wayfinder_router_decision_latency_seconds_bucket{le="0.00025"} 14
    wayfinder_router_decision_latency_seconds_bucket{le="+Inf"} 14
    wayfinder_router_decision_latency_seconds_sum 0.00112602
    wayfinder_router_decision_latency_seconds_count 14
    """
}
