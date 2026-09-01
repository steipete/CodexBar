import Foundation
import Testing
@testable import CodexBarCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The Meta Model API publishes no usage, billing, or account endpoint, so the API path only validates
/// a key. These tests pin the endpoint the key is sent to, the host it must never leave, and the local
/// identity file. Token usage is covered by ``MuseLocalUsageReaderTests``.
struct MuseProviderTests {
    // MARK: - Credentials

    @Test
    func `api key prefers META_API_KEY and accepts the documented MODEL_API_KEY`() {
        #expect(MuseSettingsReader.apiKey(environment: ["META_API_KEY": "meta-key"]) == "meta-key")
        #expect(MuseSettingsReader.apiKey(environment: ["MODEL_API_KEY": "model-key"]) == "model-key")
        #expect(MuseSettingsReader.apiKey(
            environment: ["META_API_KEY": "meta-key", "MODEL_API_KEY": "model-key"]) == "meta-key")
        #expect(MuseSettingsReader.apiKey(environment: [:]) == nil)
        #expect(MuseSettingsReader.apiKey(environment: ["META_API_KEY": "   "]) == nil)
    }

    @Test
    func `api key strips wrapping quotes copied out of a shell profile`() {
        #expect(MuseSettingsReader.apiKey(environment: ["META_API_KEY": "\"quoted\""]) == "quoted")
        #expect(MuseSettingsReader.apiKey(environment: ["META_API_KEY": "'quoted'"]) == "quoted")
    }

    // MARK: - Endpoint override

    @Test
    func `base URL defaults to the documented Meta host`() throws {
        #expect(try MuseSettingsReader.baseURL(environment: [:]) == MuseSettingsReader.defaultBaseURL)
        #expect(MuseSettingsReader.defaultBaseURL.absoluteString == "https://api.meta.ai/v1")
    }

    @Test
    func `base URL honours the local login's recorded host before the built-in default`() throws {
        let localAuth = MuseLocalAuth(
            accountEmail: nil,
            accountName: nil,
            mechanism: "oauth",
            apiBaseURL: URL(string: "https://gateway.example.com/v1"))
        let resolved = try MuseSettingsReader.baseURL(environment: [:], localAuth: localAuth)
        #expect(resolved.absoluteString == "https://gateway.example.com/v1")
    }

    @Test
    func `base URL override accepts HTTPS and private-network HTTP`() throws {
        let https = try MuseSettingsReader.baseURL(environment: ["MUSE_BASE_URL": "https://proxy.internal/v1"])
        #expect(https.absoluteString == "https://proxy.internal/v1")

        let loopback = try MuseSettingsReader.baseURL(environment: ["MUSE_BASE_URL": "http://127.0.0.1:8080/v1"])
        #expect(loopback.absoluteString == "http://127.0.0.1:8080/v1")
    }

    @Test
    func `base URL override rejects remote plaintext HTTP before the key is sent`() {
        #expect(throws: MuseUsageError.invalidEndpointOverride("http://example.com/v1")) {
            try MuseSettingsReader.baseURL(environment: ["MUSE_BASE_URL": "http://example.com/v1"])
        }
    }

    /// A key scoped to a private gateway must never reach `api.meta.ai` because the override failed
    /// validation; the fetch has to fail loudly instead of silently retargeting Meta.
    @Test
    func `rejected base URL override never falls back to the Meta host`() {
        #expect(throws: MuseUsageError.self) {
            try MuseSettingsReader.baseURL(environment: ["MUSE_BASE_URL": "ftp://example.com/v1"])
        }
        #expect(MuseSettingsReader.hasBaseURLOverride(environment: ["MUSE_BASE_URL": "ftp://example.com/v1"]))
        #expect(!MuseSettingsReader.hasBaseURLOverride(environment: [:]))
    }

    // MARK: - Usage fetch

    @Test
    func `fetch requests only the documented read-only models endpoint`() async throws {
        let transport = MuseScriptedTransport(results: [.response(statusCode: 200, headers: [:])])
        _ = try await MuseUsageFetcher.fetchUsage(
            apiKey: "key",
            baseURL: #require(URL(string: "https://api.meta.ai/v1")),
            transport: transport)

        let requests = await transport.captured()
        #expect(requests.count == 1)
        #expect(requests[0].url == "https://api.meta.ai/v1/models")
        #expect(requests[0].method == "GET")
        #expect(requests[0].authorization == "Bearer key")
    }

    @Test
    func `fetch keeps the credential on the configured host`() async throws {
        let transport = MuseScriptedTransport(results: [.response(statusCode: 200, headers: [:])])
        _ = try await MuseUsageFetcher.fetchUsage(
            apiKey: "gateway-key",
            baseURL: #require(URL(string: "https://proxy.internal/v1")),
            transport: transport)

        let hosts = await transport.captured().map(\.host)
        #expect(hosts == ["proxy.internal"])
        #expect(!hosts.contains("api.meta.ai"))
    }

    /// A successful key check reports identity only; Muse exposes no free quota to report.
    @Test
    func `a successful key check yields identity without any usage window`() async throws {
        let transport = MuseScriptedTransport(results: [.response(statusCode: 200, headers: [:])])
        let localAuth = MuseLocalAuth(
            accountEmail: "dev@example.com",
            accountName: "Dev",
            mechanism: "oauth",
            apiBaseURL: nil)
        let snapshot = try await MuseUsageFetcher.fetchUsage(
            apiKey: "key",
            localAuth: localAuth,
            transport: transport)

        #expect(snapshot.primary == nil)
        #expect(snapshot.secondary == nil)
        #expect(snapshot.accountEmail == "dev@example.com")
        #expect(snapshot.plan == "Meta account")
    }

    @Test
    func `an empty API key fails before any request is made`() async {
        let transport = MuseScriptedTransport(results: [])
        await #expect(throws: MuseUsageError.missingCredentials) {
            try await MuseUsageFetcher.fetchUsage(apiKey: "   ", transport: transport)
        }
        #expect(await transport.captured().isEmpty)
    }

    @Test
    func `rejected credentials surface as an invalid key`() async {
        for status in [401, 403] {
            let transport = MuseScriptedTransport(results: [.response(statusCode: status, headers: [:])])
            await #expect(throws: MuseUsageError.invalidAPIKey) {
                try await MuseUsageFetcher.fetchUsage(apiKey: "key", transport: transport)
            }
        }
    }

    /// A server or transport failure must never be reported as a healthy configured provider.
    @Test
    func `server and transport failures surface instead of a placeholder snapshot`() async {
        let serverError = MuseScriptedTransport(results: [.response(statusCode: 500, headers: [:])])
        await #expect(throws: MuseUsageError.networkError("Muse key check failed (HTTP 500).")) {
            try await MuseUsageFetcher.fetchUsage(apiKey: "key", transport: serverError)
        }

        let notFound = MuseScriptedTransport(results: [.response(statusCode: 404, headers: [:])])
        await #expect(throws: MuseUsageError.networkError("Muse key check failed (HTTP 404).")) {
            try await MuseUsageFetcher.fetchUsage(apiKey: "key", transport: notFound)
        }

        let offline = MuseScriptedTransport(results: [.failure(URLError(.notConnectedToInternet))])
        await #expect(throws: MuseUsageError.self) {
            try await MuseUsageFetcher.fetchUsage(apiKey: "key", transport: offline)
        }
    }

    // MARK: - Local login metadata

    @Test
    func `local auth reads the account recorded by muse login`() throws {
        let json = """
        {"schema_version":2,"providers":{"meta":{"mechanism":"oauth","storage":"keychain",\
        "obtained_via":"device_code","api_base_url":"https://api.meta.ai/v1",\
        "user_full_name":"Ada Lovelace","user_email":"ada@example.com"}}}
        """
        let data = try #require(json.data(using: .utf8))
        let auth = try #require(MuseLocalAuthReader.parse(data: data))
        #expect(auth.accountEmail == "ada@example.com")
        #expect(auth.accountName == "Ada Lovelace")
        #expect(auth.mechanism == "oauth")
        #expect(auth.apiBaseURL?.absoluteString == "https://api.meta.ai/v1")
        #expect(auth.loginMethod == "Meta account")
    }

    @Test
    func `local auth labels a stored API key distinctly from an account login`() throws {
        let json = """
        {"schema_version":2,"providers":{"meta":{"mechanism":"api_key","storage":"keychain"}}}
        """
        let data = try #require(json.data(using: .utf8))
        let auth = try #require(MuseLocalAuthReader.parse(data: data))
        #expect(auth.loginMethod == "API key")
        #expect(auth.accountEmail == nil)
    }

    @Test
    func `local auth returns nothing for a logged-out or unusable file`() throws {
        let empty = """
        {"schema_version":2,"providers":{}}
        """
        let emptyData = try #require(empty.data(using: .utf8))
        #expect(MuseLocalAuthReader.parse(data: emptyData) == nil)

        let blankEntry = """
        {"schema_version":2,"providers":{"meta":{}}}
        """
        let blankData = try #require(blankEntry.data(using: .utf8))
        #expect(MuseLocalAuthReader.parse(data: blankData) == nil)
        #expect(MuseLocalAuthReader.parse(data: Data("not json".utf8)) == nil)
    }

    @Test
    func `local auth path is the documented muse config location`() {
        #expect(MuseLocalAuthReader.defaultPath(home: "/Users/example") == "/Users/example/.config/muse/auth.json")
    }

    @Test
    func `local auth ignores a recorded base URL that fails endpoint validation`() throws {
        let json = """
        {"schema_version":2,"providers":{"meta":{"mechanism":"oauth","api_base_url":"http://evil.example.com/v1"}}}
        """
        let data = try #require(json.data(using: .utf8))
        let auth = try #require(MuseLocalAuthReader.parse(data: data))
        #expect(auth.apiBaseURL == nil)
    }

    // MARK: - Snapshot mapping

    @Test
    func `snapshot maps onto the shared usage snapshot under the Muse identity`() {
        let snapshot = MuseUsageSnapshot(
            primary: RateWindow(usedPercent: 40, windowMinutes: 1, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 10, windowMinutes: 1, resetsAt: nil, resetDescription: nil),
            accountEmail: "dev@example.com",
            plan: "Meta account")
        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 40)
        #expect(usage.secondary?.usedPercent == 10)
        #expect(usage.identity?.providerID == .muse)
        #expect(usage.identity?.accountEmail == "dev@example.com")
        #expect(usage.identity?.loginMethod == "Meta account")
    }

    // MARK: - Descriptor

    @Test
    func `descriptor is registered with the documented Muse surfaces`() {
        let descriptor = MuseProviderDescriptor.descriptor
        #expect(descriptor.id == .muse)
        #expect(descriptor.metadata.cliName == "muse")
        #expect(descriptor.metadata.dashboardURL == "https://dev.meta.ai")
        #expect(descriptor.metadata.changelogURL == "https://dev.meta.ai/docs/muse-code/changelog")
        // Token history comes from local session logs; no version probe is spawned.
        #expect(descriptor.tokenCost.supportsTokenCost)
        #expect(descriptor.tokenCost.supportsTokenSnapshot)
        #expect(descriptor.cli.versionDetector == nil)
    }

    @Test
    func `fetch plan offers only the sources Muse actually supports`() {
        let modes = MuseProviderDescriptor.descriptor.fetchPlan.sourceModes
        #expect(modes.contains(.api))
        #expect(modes.contains(.cli))
        #expect(!modes.contains(.web))
        #expect(!modes.contains(.oauth))
    }

    /// A transport or endpoint failure must stay visible; only a credential problem may degrade to the
    /// local identity card, and only when a login actually exists.
    @Test
    func `the API strategy never degrades a transport failure to an identity card`() {
        let strategy = MuseAPIFetchStrategy()
        let context = Self.makeContext(sourceMode: .api)
        #expect(!strategy.shouldFallback(on: MuseUsageError.networkError("boom"), context: context))
        #expect(!strategy.shouldFallback(on: MuseUsageError.usageUnavailable, context: context))
        #expect(!strategy.shouldFallback(
            on: MuseUsageError.invalidEndpointOverride("http://example.com"),
            context: context))
        #expect(!strategy.shouldFallback(on: URLError(.timedOut), context: context))
    }

    private static func makeContext(
        sourceMode: ProviderSourceMode,
        env: [String: String] = [:]) -> ProviderFetchContext
    {
        let browserDetection = BrowserDetection(cacheTTL: 0)
        return ProviderFetchContext(
            runtime: .app,
            sourceMode: sourceMode,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: env,
            settings: nil,
            fetcher: UsageFetcher(),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
            browserDetection: browserDetection)
    }
}

private actor MuseScriptedTransport: ProviderHTTPTransport {
    enum Result {
        case response(statusCode: Int, headers: [String: String])
        case failure(URLError)
    }

    struct CapturedRequest {
        let url: String?
        let method: String?
        let host: String?
        let authorization: String?
    }

    private var results: [Result]
    private var capturedRequests: [CapturedRequest] = []

    init(results: [Result]) {
        self.results = results
    }

    func captured() -> [CapturedRequest] {
        self.capturedRequests
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        self.capturedRequests.append(CapturedRequest(
            url: request.url?.absoluteString,
            method: request.httpMethod,
            host: request.url?.host,
            authorization: request.value(forHTTPHeaderField: "Authorization")))

        guard !self.results.isEmpty else {
            throw URLError(.badServerResponse)
        }
        switch self.results.removeFirst() {
        case let .response(statusCode, headers):
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://api.meta.ai/v1/models")!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: headers)!
            return (Data("{\"data\":[]}".utf8), response)
        case let .failure(error):
            throw error
        }
    }
}
