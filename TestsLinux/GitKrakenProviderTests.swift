import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct GitKrakenProviderTests {
    private static let apiBody = Data(
        #"{"data":{"used":12500,"limit":400000,"resetsOn":"2026-09-27T00:00:00Z"},"error":null}"#.utf8)
    private static let cliOutput = "12,500 of 400,000 used (3% consumed)\nReset on 09/27/2026"

    private func context(
        source: ProviderSourceMode = .auto,
        environment: [String: String] = [:]) -> ProviderFetchContext
    {
        let browserDetection = BrowserDetection(cacheTTL: 0)
        return ProviderFetchContext(
            runtime: .app,
            sourceMode: source,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: environment,
            settings: nil,
            fetcher: UsageFetcher(),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
            browserDetection: browserDetection)
    }

    @Test
    func `Auto tries API then CLI while explicit modes never cross sources`() async {
        let pipeline = GitKrakenProviderDescriptor.descriptor.fetchPlan.pipeline
        let automatic = await pipeline.resolveStrategies(self.context())
        let api = await pipeline.resolveStrategies(self.context(source: .api))
        let cli = await pipeline.resolveStrategies(self.context(source: .cli))
        let web = await pipeline.resolveStrategies(self.context(source: .web))
        #expect(automatic.map(\.id) == ["gitkraken.api", "gitkraken.cli"])
        #expect(api.map(\.id) == ["gitkraken.api"])
        #expect(cli.map(\.id) == ["gitkraken.cli"])
        #expect(web.isEmpty)
    }

    @Test
    func `API is skipped without a token unless API or an organization is explicitly selected`() async {
        let strategy = GitKrakenAPIFetchStrategy()
        #expect(await !strategy.isAvailable(self.context()))
        #expect(await !strategy.isAvailable(self.context(environment: ["GITKRAKEN_API_TOKEN": "  "])))
        #expect(await strategy.isAvailable(self.context(source: .api)))
        #expect(await strategy.isAvailable(self.context(environment: ["GITKRAKEN_API_TOKEN": "fixture"])))
        #expect(await strategy.isAvailable(self.context(environment: ["GITKRAKEN_ORG_ID": "org-fixture"])))
    }

    @Test
    func `API without credentials has a specific noninteractive setup error`() async {
        await #expect(throws: GitKrakenUsageError.missingToken) {
            try await GitKrakenAPIFetchStrategy().fetch(self.context(source: .api))
        }
    }

    @Test
    func `fallback preserves explicit modes cancellation rate limits and pinned organizations`() {
        let api = GitKrakenAPIFetchStrategy()
        let auto = self.context()
        #expect(api.shouldFallback(on: GitKrakenUsageError.httpError(401), context: auto))
        #expect(api.shouldFallback(on: GitKrakenUsageError.httpError(503), context: auto))
        #expect(api.shouldFallback(on: GitKrakenUsageError.invalidResponse, context: auto))
        #expect(api.shouldFallback(on: URLError(.timedOut), context: auto))
        #expect(!api.shouldFallback(on: GitKrakenUsageError.httpError(429), context: auto))
        #expect(!api.shouldFallback(on: CancellationError(), context: auto))
        #expect(!api.shouldFallback(on: URLError(.cancelled), context: auto))
        #expect(!api.shouldFallback(on: GitKrakenUsageError.httpError(401), context: self.context(source: .api)))
        #expect(!api.shouldFallback(
            on: GitKrakenUsageError.httpError(401),
            context: self.context(environment: ["GITKRAKEN_ORG_ID": "org-fixture"])))
        #expect(!GitKrakenCLIFetchStrategy().shouldFallback(on: GitKrakenUsageError.cliFailed, context: auto))
    }

    @Test
    func `pinned API organization never implicitly becomes the CLI organization`() async {
        let environment = ["GITKRAKEN_ORG_ID": "org-fixture"]
        let cli = GitKrakenCLIFetchStrategy()
        #expect(await !cli.isAvailable(self.context(environment: environment)))
        #expect(await cli.isAvailable(self.context(source: .cli, environment: environment)))
    }

    @Test
    func `config fields use the existing credential projection without changing other providers`() throws {
        let descriptor = GitKrakenProviderDescriptor.descriptor
        let credentials = try #require(descriptor.credentials)
        let config = ProviderConfig(id: .gitkraken, apiKey: " fixture-token ", workspaceID: "org-fixture")
        let environment = credentials.applyConfig(base: ["UNCHANGED": "yes"], config: config)
        #expect(environment["GITKRAKEN_API_TOKEN"] == "fixture-token")
        #expect(environment["GITKRAKEN_ORG_ID"] == "org-fixture")
        #expect(environment["UNCHANGED"] == "yes")
        #expect(GitKrakenSettingsReader.accessToken(environment: environment) == "fixture-token")
        #expect(descriptor.metadata.defaultEnabled == false)
        #expect(descriptor.metadata.widgetSelectable == false)
        #expect(descriptor.fetchPlan.sourceModes.contains(.auto))
        #expect(descriptor.fetchPlan.sourceModes.contains(.api))
        #expect(descriptor.fetchPlan.sourceModes.contains(.cli))
        #expect(descriptor.presentation.menuCard.clearsPrimaryReset)
        #expect(!CodexBarConfigValidator.validate(CodexBarConfig(providers: [config]))
            .contains(where: { $0.code == "workspace_unused" || $0.code == "api_key_unused" }))
    }

    @Test
    func `API request is a cookie free GET with an optional organization header`() throws {
        let request = try GitKrakenUsageFetcher.makeRequest(token: "fixture-token", organizationID: "org-fixture")
        #expect(request.url?.absoluteString == "https://api.gitkraken.dev/v1/ai-tasks/usage")
        #expect(request.httpMethod == "GET")
        #expect(request.httpBody == nil)
        #expect(request.httpShouldHandleCookies == false)
        #expect(request.timeoutInterval == 15)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token")
        #expect(request.value(forHTTPHeaderField: "gk-org-id") == "org-fixture")
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request.value(forHTTPHeaderField: "Client-Name") == "CodexBar")
        #expect(request.value(forHTTPHeaderField: "Client-Version") != nil)
        let personal = try GitKrakenUsageFetcher.makeRequest(token: "fixture-token", organizationID: nil)
        #expect(personal.value(forHTTPHeaderField: "gk-org-id") == nil)
    }

    @Test(arguments: ["", "Bearer token", "a\nb", "a\rb", "a\tb", "非ascii"])
    func `API rejects invalid token headers without reflecting secrets`(token: String) {
        #expect(throws: GitKrakenUsageError.invalidToken) {
            try GitKrakenUsageFetcher.makeRequest(token: token, organizationID: nil)
        }
    }

    @Test
    func `API token length is bounded`() {
        #expect(throws: GitKrakenUsageError.invalidToken) {
            try GitKrakenUsageFetcher.makeRequest(token: String(repeating: "x", count: 16385), organizationID: nil)
        }
    }

    @Test(arguments: ["", "org\r\nCookie: injected", "two ids", String(repeating: "x", count: 257)])
    func `API rejects invalid organization headers`(organization: String) {
        #expect(throws: GitKrakenUsageError.invalidOrganization) {
            try GitKrakenUsageFetcher.makeRequest(token: "fixture", organizationID: organization)
        }
    }

    @Test
    func `API transport parses a successful fixture`() async throws {
        let transport = ProviderHTTPTransportHandler { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture")
            let response = try #require(HTTPURLResponse(
                url: GitKrakenUsageFetcher.usageURL, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (Self.apiBody, response)
        }
        let usage = try await GitKrakenUsageFetcher.fetch(token: "fixture", transport: transport)
        #expect(usage.personal.usedPercent == 3.125)
    }

    @Test(arguments: [401, 403, 429, 500, 302])
    func `API HTTP failures never parse or expose their response bodies`(status: Int) async {
        let transport = ProviderHTTPTransportHandler { _ in
            let response = try #require(HTTPURLResponse(
                url: GitKrakenUsageFetcher.usageURL, statusCode: status, httpVersion: nil, headerFields: nil))
            return (Data("secret-response-fixture".utf8), response)
        }
        await #expect(throws: GitKrakenUsageError.httpError(status)) {
            try await GitKrakenUsageFetcher.fetch(token: "fixture", transport: transport)
        }
        #expect(!GitKrakenUsageError.httpError(status).localizedDescription.contains("secret-response-fixture"))
    }

    @Test
    func `API transport cancellation stays cancellation`() async {
        let transport = ProviderHTTPTransportHandler { _ in throw CancellationError() }
        await #expect(throws: CancellationError.self) {
            try await GitKrakenUsageFetcher.fetch(token: "fixture", transport: transport)
        }
    }

    @Test
    func `CLI uses fixed read only arguments and never receives CodexBar API credentials`() async throws {
        let probe = GitKrakenCLIProbe { executable, arguments, environment in
            #expect(executable == "/fixture/gk")
            #expect(arguments == ["ai", "tokens"])
            #expect(environment["NO_COLOR"] == "1")
            #expect(environment["LC_ALL"] == "C")
            #expect(environment["HOME"] == "/fixture/home")
            #expect(environment["GITKRAKEN_API_TOKEN"] == nil)
            #expect(environment["GITKRAKEN_ORG_ID"] == nil)
            #expect(environment["GK_OUTPUT"] == nil)
            return Self.cliOutput
        }
        let usage = try await probe.fetch(executable: "/fixture/gk", environment: [
            "HOME": "/fixture/home", "GITKRAKEN_API_TOKEN": "secret-fixture",
            "GITKRAKEN_ORG_ID": "org-fixture", "GK_OUTPUT": "json",
        ])
        #expect(usage.personal.used == 12500)
        #expect(usage.organization == nil)
    }

    @Test
    func `CLI failed process never becomes successful usage or leaks stderr`() async {
        let probe = GitKrakenCLIProbe { _, _, _ in
            throw SubprocessRunnerError.nonZeroExit(code: 1, stderr: "secret-fixture\n\(Self.cliOutput)")
        }
        await #expect(throws: GitKrakenUsageError.cliFailed) {
            try await probe.fetch(executable: "/fixture/gk", environment: [:])
        }
        #expect(!GitKrakenUsageError.cliFailed.localizedDescription.contains("secret-fixture"))
    }

    @Test
    func `CLI cancellation propagates without parsing`() async {
        let probe = GitKrakenCLIProbe { _, _, _ in throw CancellationError() }
        await #expect(throws: CancellationError.self) {
            try await probe.fetch(executable: "/fixture/gk", environment: [:])
        }
    }

    @Test
    func `CLI metadata and version parser match the installed gk command`() {
        let cli = GitKrakenProviderDescriptor.descriptor.cli
        #expect(GitKrakenProviderDescriptor.descriptor.metadata.cliName == "gk")
        #expect(cli.name == "gk")
        #expect(cli.aliases.contains("gitkraken"))
        #expect(GitKrakenCLIProbe.parseVersionOutput(
            #"{"version":"3.1.75","composeTools":"0.8.1","installer":"3.1.70"}"#) == "3.1.75")
        #expect(GitKrakenCLIProbe.parseVersionOutput("not json") == nil)
    }
}
