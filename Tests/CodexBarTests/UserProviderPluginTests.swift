#if canImport(JavaScriptCore)
import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCLI
@testable import CodexBarCore
@testable import CodexBarWidget

@Suite(.serialized)
struct UserProviderPluginTests {
    @Test
    func `JavaScript plugin discovers approves fetches and produces a generic snapshot`() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let pluginURL = try fixture.write(
            name: "acme.js",
            source: Self.javaScriptPlugin(origin: "https://api.acme.test"))
        let transport = RecordingTransport(responseJSON: #"{"used":42}"#)
        let loader = fixture.loader(transport: transport)

        let results = UserProviderPluginRegistry.refresh(loader: loader)
        let plugin = try #require(results.first?.plugin)
        #expect(plugin.fileURL.resolvingSymlinksInPath() == pluginURL.resolvingSymlinksInPath())
        #expect(plugin.manifest.id.rawValue == "acme-meter")
        #expect(plugin.manifest.icon.monogram == "AM")
        #expect(plugin.manifest.icon.tint == "#336699")

        let binding = try plugin.approvalBinding(settings: [:])
        await #expect(throws: UserProviderPluginError.self) {
            try await plugin.fetchUsage(
                settings: [:],
                secrets: ["TOKEN": "fixture-secret"],
                approvalStore: fixture.approvals)
        }
        #expect(transport.requestCount == 0)

        try fixture.approvals.record(binding)
        let snapshot = try await plugin.fetchUsage(
            settings: [:],
            secrets: ["TOKEN": "fixture-secret"],
            approvalStore: fixture.approvals)
        #expect(snapshot.primary?.usedPercent == 42)
        #expect(snapshot.details.first?.rows.first?.value == "42%")
        #expect(snapshot.identity?.providerID?.rawValue == "acme-meter")
        #expect(transport.requestCount == 1)
        #expect(transport.lastRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-secret")
        #expect(transport.lastRequest?.value(forHTTPHeaderField: "Accept-Encoding") == "identity")
    }

    @Test
    func `http status capability keeps identity encoding and compressed response rejection`() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = """
        defineProvider({
          id: "encoded-meter",
          name: "Encoded Meter",
          endpoints: ["https://encoded.example"],
          settings: [],
          capabilities: ["http-status"],
          async fetchUsage(ctx) {
            const response = await ctx.http.getJSON("https://encoded.example/usage", {
              headers: { "Accept-Encoding": "gzip" },
            });
            return { primary: { usedPercent: response.json.used } };
          },
        });
        """
        let transport = RecordingTransport(
            responseJSON: #"{"used":42}"#,
            responseHeaders: ["Content-Type": "application/json", "Content-Encoding": "gzip"])
        let plugin = try fixture.loader(transport: transport)
            .load(fileURL: fixture.write(name: "encoded.js", source: source))
        try fixture.approvals.record(plugin.approvalBinding(settings: [:]))

        do {
            _ = try await plugin.fetchUsage(
                settings: [:],
                secrets: [:],
                approvalStore: fixture.approvals)
            Issue.record("Expected compressed response rejection")
        } catch {
            #expect(error.localizedDescription.contains("compressed responses are not allowed"))
        }
        #expect(transport.lastRequest?.value(forHTTPHeaderField: "Accept-Encoding") == "identity")
    }

    @Test
    func `TypeScript plugin transpiles once and reuses the SHA keyed cache`() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = """
        const percentage: number = 37;
        defineProvider({
          id: "typed-meter",
          name: "Typed Meter",
          endpoints: ["https://typed.example"],
          settings: [],
          async fetchUsage(ctx: unknown) {
            return { primary: { usedPercent: percentage } };
          },
        });
        """
        let url = try fixture.write(name: "typed.ts", source: source)
        let loader = fixture.loader(transport: RecordingTransport(responseJSON: "{}"))

        let first = try loader.load(fileURL: url)
        let second = try loader.load(fileURL: url)

        #expect(first.transpileCacheHit == false)
        #expect(second.transpileCacheHit == true)
        #expect(first.transpiledCacheURL == second.transpiledCacheURL)
        #expect(first.transpiledCacheURL?.lastPathComponent.contains(first.sourceHash) == true)
        #expect(first.manifest.id.rawValue == "typed-meter")
    }

    @Test
    func `collisions invalid manifests and oversized sources report per file errors`() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.write(name: "collision.js", source: Self.javaScriptPlugin(id: "codex"))
        _ = try fixture.write(name: "invalid.js", source: "defineProvider({id: 'Bad ID'});")
        let oversized = fixture.providers.appendingPathComponent("oversized.js")
        try Data(repeating: UInt8(ascii: "x"), count: UserProviderPlugin.maximumSourceBytes + 1)
            .write(to: oversized)

        let results = fixture.loader(transport: RecordingTransport(responseJSON: "{}")).discover()
        let errors = Dictionary(uniqueKeysWithValues: results.map { ($0.fileURL.lastPathComponent, $0.error ?? "") })
        #expect(errors["collision.js"]?.contains("collides") == true)
        #expect(errors["invalid.js"]?.contains("Invalid provider plugin manifest") == true)
        #expect(errors["oversized.js"]?.contains("1 MiB") == true)
    }

    @Test
    func `undeclared cookie capability fails without invoking its resolver`() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = """
        defineProvider({
          id: "cookie-probe",
          name: "Cookie Probe",
          endpoints: ["https://cookie.example"],
          settings: [],
          async fetchUsage(ctx) {
            await ctx.browser.cookieHeader("cookie.example");
            return { primary: { usedPercent: 1 } };
          },
        });
        """
        let plugin = try fixture.loader(transport: RecordingTransport(responseJSON: "{}"))
            .load(fileURL: fixture.write(name: "cookie.js", source: source))
        let binding = try plugin.approvalBinding(settings: [:])
        try fixture.approvals.record(binding)
        let access = ResolverAccess()

        await #expect(throws: ProviderPluginError.self) {
            try await plugin.fetchUsage(
                settings: [:],
                secrets: [:],
                approvalStore: fixture.approvals,
                cookieResolver: { provider, domain in
                    await access.record(provider: provider, domain: domain)
                    return "session=fixture"
                })
        }
        #expect(await access.calls == 0)
    }

    @Test
    func `delete removes source cache approval secrets config and history`() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let plugin = try fixture.loader(transport: RecordingTransport(responseJSON: "{}"))
            .load(fileURL: fixture.write(name: "delete-me.ts", source: Self.typeScriptPlugin()))
        let binding = try plugin.approvalBinding(settings: [:])
        try fixture.approvals.record(binding)
        var config = CodexBarConfig(providers: [
            ProviderConfig(
                id: plugin.manifest.id,
                enabled: true,
                pluginSettings: ["REGION": "west"],
                pluginSecrets: ["TOKEN": "fixture-secret"]),
        ])
        try FileManager.default.createDirectory(at: fixture.history, withIntermediateDirectories: true)
        let historyURL = fixture.history.appendingPathComponent("delete-me.json")
        try Data("history".utf8).write(to: historyURL)
        let staleCacheURL = fixture.cache.appendingPathComponent(
            "delete-me-oldhash-sucrase-\(UserProviderPluginLoader.sucraseVersion).js")
        try Data("stale".utf8).write(to: staleCacheURL)

        try UserProviderPluginManager.delete(
            plugin,
            approvalStore: fixture.approvals,
            config: &config,
            historyDirectory: fixture.history)

        #expect(!FileManager.default.fileExists(atPath: plugin.fileURL.path))
        #expect(plugin.transpiledCacheURL.map { !FileManager.default.fileExists(atPath: $0.path) } == true)
        #expect(!FileManager.default.fileExists(atPath: staleCacheURL.path))
        #expect(!fixture.approvals.isApproved(binding))
        #expect(config.providers.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: historyURL.path))
    }

    @Test
    func `origin change invalidates approval before the next transport call`() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let url = try fixture.write(
            name: "changing.js",
            source: Self.javaScriptPlugin(origin: "https://one.example"))
        let transport = RecordingTransport(responseJSON: #"{"used":9}"#)
        let loader = fixture.loader(transport: transport)
        let first = try loader.load(fileURL: url)
        try fixture.approvals.record(first.approvalBinding(settings: [:]))
        _ = try await first.fetchUsage(
            settings: [:],
            secrets: ["TOKEN": "fixture-secret"],
            approvalStore: fixture.approvals)
        #expect(transport.requestCount == 1)

        try Data(Self.javaScriptPlugin(origin: "https://two.example").utf8).write(to: url, options: .atomic)
        let changed = try loader.load(fileURL: url)
        await #expect(throws: UserProviderPluginError.self) {
            try await changed.fetchUsage(
                settings: [:],
                secrets: ["TOKEN": "fixture-secret"],
                approvalStore: fixture.approvals)
        }
        #expect(transport.requestCount == 1)
    }

    @Test
    func `unknown instance IDs stay inert in menu history CLI and widget surfaces`() throws {
        let unknown = try #require(ProviderInstanceID(rawValue: "unknown-local-plugin"))

        #expect(UserProviderPluginRegistry.plugin(for: unknown) == nil)
        #expect(SettingsPane(persistenceToken: "provider:\(unknown.rawValue)") == nil)
        #expect(ProviderSelection(argument: unknown.rawValue) == nil)
        #expect(ProviderChoice(rawValue: unknown.rawValue) == nil)

        let history = PlanUtilizationHistoryStore(
            directoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        #expect(history.load()[unknown] == nil)
    }

    @Test
    func `settings endpoints normalize IPv6 loopback and require typed approval`() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = """
        defineProvider({
          id: "local-meter",
          name: "Local Meter",
          endpoints: [{ setting: "BASE_URL", policy: "https-or-loopback-http" }],
          settings: [{ key: "BASE_URL", title: "Base URL", type: "plain" }],
          fetchUsage() { return { primary: { usedPercent: 1 } }; },
        });
        """
        let plugin = try fixture.loader(transport: RecordingTransport(responseJSON: "{}"))
            .load(fileURL: fixture.write(name: "local.js", source: source))

        let binding = try plugin.approvalBinding(settings: ["BASE_URL": "http://[::1]:8080/path"])

        #expect(binding.origins == ["http://[::1]:8080"])
        #expect(binding.typedConfirmationOrigins == binding.origins)
    }

    @Test
    func `LLM Proxy private HTTP requires approval and keeps auth bound to the typed origin`() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = """
        defineProvider({
          id: "llmproxy-prototype",
          name: "LLM Proxy Prototype",
          endpoints: [{ setting: "BASE_URL", policy: "https-or-private-network-http" }],
          auth: { type: "bearer", secret: "TOKEN" },
          settings: [
            { key: "BASE_URL", title: "Base URL", type: "plain" },
            { key: "TOKEN", title: "API token", type: "secure" },
          ],
          async fetchUsage(ctx) {
            const response = await ctx.http.getJSON(`${ctx.settings.get("BASE_URL")}/usage`);
            return { identity: { organization: response.json.organization } };
          },
        });
        """
        let transport = RecordingTransport(responseJSON: #"{"organization":"Acme gateway"}"#)
        let plugin = try fixture.loader(transport: transport)
            .load(fileURL: fixture.write(name: "llmproxy.js", source: source))
        let settings = ["BASE_URL": "http://192.168.1.20:4000"]
        let binding = try plugin.approvalBinding(settings: settings)

        #expect(binding.origins == ["http://192.168.1.20:4000"])
        #expect(binding.typedConfirmationOrigins == binding.origins)
        let localBinding = try plugin.approvalBinding(settings: ["BASE_URL": "http://gateway.local.:4000"])
        #expect(localBinding.typedConfirmationOrigins == localBinding.origins)
        await #expect(throws: UserProviderPluginError.self) {
            _ = try await plugin.fetchUsage(
                settings: settings,
                secrets: ["TOKEN": "fixture-secret"],
                approvalStore: fixture.approvals)
        }
        #expect(transport.requestCount == 0)

        try fixture.approvals.record(binding)
        let snapshot = try await plugin.fetchUsage(
            settings: settings,
            secrets: ["TOKEN": "fixture-secret"],
            approvalStore: fixture.approvals)

        #expect(snapshot.identity?.accountOrganization == "Acme gateway")
        #expect(transport.lastRequest?.url?.absoluteString == "http://192.168.1.20:4000/usage")
        #expect(transport.lastRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-secret")

        #expect(throws: ProviderPluginError.self) {
            _ = try plugin.approvalBinding(settings: ["BASE_URL": "http://gateway.example"])
        }
    }

    @Test
    func `plugin CLI renders identity only snapshots`() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let plugin = try fixture.loader(transport: RecordingTransport(responseJSON: "{}"))
            .load(fileURL: fixture.write(name: "identity.js", source: Self.javaScriptPlugin()))
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            tertiary: nil,
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: plugin.manifest.id,
                accountEmail: "user@example.com",
                accountOrganization: "Acme",
                loginMethod: "API key",
                accountID: "acct-1"))

        #expect(CodexBarCLI.pluginSnapshotLines(plugin: plugin, snapshot: snapshot) == [
            "Acme Meter",
            "Account: user@example.com",
            "Organization: Acme",
            "Plan: API key",
            "Account ID: acct-1",
        ])
    }

    @Test
    func `NeuralWatt style Retry After failure delays once then succeeds`() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let transport = SequenceResponseTransport(responses: [
            (429, #"{"error":"slow down"}"#, ["Retry-After": "0"]),
            (200, #"{"balance":5}"#, [:]),
        ])
        let plugin = try fixture.loader(transport: transport).load(fileURL: fixture.write(
            name: "neuralwatt.js",
            source: Self.retryAfterPlugin(capabilities: #"capabilities: ["http-status"],"#)))
        let binding = try plugin.approvalBinding(settings: [:])
        try fixture.approvals.record(binding)

        let snapshot = try await plugin.fetchUsage(
            settings: [:],
            secrets: [:],
            approvalStore: fixture.approvals)

        #expect(binding.capabilities == ["http-status"])
        #expect(snapshot.providerCost?.used == 5)
        #expect(await transport.requestCount == 2)
    }

    @Test
    func `naive user plugin automatically retries host 429 once`() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let transport = SequenceResponseTransport(responses: [
            (429, #"{"error":"slow down"}"#, ["Retry-After": "0"]),
            (200, #"{"used":42}"#, [:]),
        ])
        let plugin = try fixture.loader(transport: transport).load(fileURL: fixture.write(
            name: "naive.js",
            source: Self.naiveUsagePlugin()))
        try fixture.approvals.record(plugin.approvalBinding(settings: [:]))

        let snapshot = try await plugin.fetchUsage(
            settings: [:],
            secrets: [:],
            approvalStore: fixture.approvals)

        #expect(snapshot.primary?.usedPercent == 42)
        #expect(await transport.requestCount == 2)
    }

    @Test
    func `host 503 without Retry After requests one second retry without sleeping`() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let transport = SequenceResponseTransport(responses: [
            (503, #"{"error":"unavailable"}"#, [:]),
            (200, #"{"used":17}"#, [:]),
        ])
        let plugin = try fixture.loader(transport: transport).load(fileURL: fixture.write(
            name: "naive.js",
            source: Self.naiveUsagePlugin()))
        let delays = RetryDelayRecorder()

        let snapshot = try await ProviderFetchDelayedRetry.run(sleeper: { seconds in
            await delays.record(seconds)
        }, operation: {
            try await plugin.runtime.fetchUsage()
        })

        #expect(snapshot.primary?.usedPercent == 17)
        #expect(await transport.requestCount == 2)
        #expect(await delays.values == [1])
    }

    @Test
    func `host 404 remains unclassified and fails without retry`() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let transport = SequenceResponseTransport(responses: [
            (404, #"{"error":"not found"}"#, [:]),
        ])
        let plugin = try fixture.loader(transport: transport).load(fileURL: fixture.write(
            name: "naive.js",
            source: Self.naiveUsagePlugin()))
        try fixture.approvals.record(plugin.approvalBinding(settings: [:]))

        do {
            _ = try await plugin.fetchUsage(
                settings: [:],
                secrets: [:],
                approvalStore: fixture.approvals)
            Issue.record("Expected host HTTP status rejection")
        } catch {
            #expect(error.localizedDescription.contains("request returned HTTP 404"))
        }
        #expect(await transport.requestCount == 1)
    }

    @Test
    func `http status capability parses and unknown capability remains rejected`() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let loader = fixture.loader(transport: RecordingTransport(responseJSON: "{}"))
        let plugin = try loader.load(fileURL: fixture.write(
            name: "http-status.js",
            source: Self.retryAfterPlugin(capabilities: #"capabilities: ["http-status"],"#)))

        #expect(plugin.manifest.capabilities == [.httpStatus])
        #expect(throws: ProviderPluginError.self) {
            _ = try loader.load(fileURL: fixture.write(
                name: "unknown.js",
                source: Self.retryAfterPlugin(capabilities: #"capabilities: ["unknown"],"#)))
        }
    }

    private static func javaScriptPlugin(
        id: String = "acme-meter",
        origin: String = "https://api.acme.test") -> String
    {
        """
        defineProvider({
          id: "\(id)",
          name: "Acme Meter",
          icon: { monogram: "AM", tint: "#336699" },
          endpoints: ["\(origin)"],
          auth: { type: "bearer", secret: "TOKEN" },
          settings: [{ key: "TOKEN", title: "API token", type: "secure" }],
          async fetchUsage(ctx) {
            const response = await ctx.http.getJSON("\(origin)/usage");
            const used = response.json.used;
            return {
              primary: { usedPercent: used },
              identity: { loginMethod: "plugin" },
              details: [{ title: "Usage", rows: [{ label: "Used", value: `${used}%` }] }],
            };
          },
        });
        """
    }

    private static func typeScriptPlugin() -> String {
        """
        const used: number = 12;
        defineProvider({
          id: "delete-me",
          name: "Delete Me",
          endpoints: ["https://delete.example"],
          settings: [],
          fetchUsage() { return { primary: { usedPercent: used } }; },
        });
        """
    }

    private static func retryAfterPlugin(capabilities: String = "") -> String {
        """
        defineProvider({
          id: "neuralwatt-prototype",
          name: "NeuralWatt Prototype",
          endpoints: ["https://api.neuralwatt.test"],
          settings: [],
          \(capabilities)
          async fetchUsage(ctx) {
            const response = await ctx.http.getJSON("https://api.neuralwatt.test/v1/quota");
            if (response.status === 429) {
              throw ctx.fail.rateLimited("rate limited", {
                retryAfterSeconds: Number(response.headers["retry-after"] || 1),
              });
            }
            return { cost: { used: response.json.balance, currency: "USD" } };
          },
        });
        """
    }

    private static func naiveUsagePlugin() -> String {
        """
        defineProvider({
          id: "naive-meter",
          name: "Naive Meter",
          endpoints: ["https://api.naive.test"],
          settings: [],
          async fetchUsage(ctx) {
            const response = await ctx.http.getJSON("https://api.naive.test/usage");
            return { primary: { usedPercent: response.json.used } };
          },
        });
        """
    }
}

private final class RecordingTransport: ProviderHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let responseJSON: String
    private let responseHeaders: [String: String]
    private var requests: [URLRequest] = []

    init(responseJSON: String, responseHeaders: [String: String] = ["Content-Type": "application/json"]) {
        self.responseJSON = responseJSON
        self.responseHeaders = responseHeaders
    }

    var requestCount: Int {
        self.lock.withLock { self.requests.count }
    }

    var lastRequest: URLRequest? {
        self.lock.withLock { self.requests.last }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        self.lock.withLock { self.requests.append(request) }
        let response = try HTTPURLResponse(
            url: #require(request.url),
            statusCode: 200,
            httpVersion: nil,
            headerFields: self.responseHeaders)!
        return (Data(self.responseJSON.utf8), response)
    }
}

private actor ResolverAccess {
    private(set) var calls = 0

    func record(provider _: UsageProvider, domain _: String) {
        self.calls += 1
    }
}

private actor RetryDelayRecorder {
    private(set) var values: [TimeInterval] = []

    func record(_ seconds: TimeInterval) {
        self.values.append(seconds)
    }
}

private actor SequenceResponseTransport: ProviderHTTPTransport {
    private var responses: [(status: Int, body: String, headers: [String: String])]
    private(set) var requestCount = 0

    init(responses: [(Int, String, [String: String])]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        self.requestCount += 1
        let response = self.responses.removeFirst()
        var headers = response.headers
        headers["Content-Type"] = "application/json"
        let httpResponse = try HTTPURLResponse(
            url: #require(request.url),
            statusCode: response.status,
            httpVersion: nil,
            headerFields: headers)!
        return (Data(response.body.utf8), httpResponse)
    }
}

private struct Fixture {
    let root: URL
    let providers: URL
    let cache: URL
    let history: URL
    let approvals: ProviderPluginApprovalStore

    init() throws {
        self.root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UserProviderPluginTests-\(UUID().uuidString)", isDirectory: true)
        self.providers = self.root.appendingPathComponent("providers", isDirectory: true)
        self.cache = self.root.appendingPathComponent("cache", isDirectory: true)
        self.history = self.root.appendingPathComponent("history", isDirectory: true)
        self.approvals = ProviderPluginApprovalStore(fileURL: self.root.appendingPathComponent("approvals.json"))
        try FileManager.default.createDirectory(at: self.providers, withIntermediateDirectories: true)
    }

    func write(name: String, source: String) throws -> URL {
        let url = self.providers.appendingPathComponent(name)
        try Data(source.utf8).write(to: url, options: .atomic)
        return url
    }

    func loader(transport: any ProviderHTTPTransport) -> UserProviderPluginLoader {
        UserProviderPluginLoader(
            providersDirectory: self.providers,
            cacheDirectory: self.cache,
            transport: transport)
    }

    func remove() {
        try? FileManager.default.removeItem(at: self.root)
    }
}
#endif
