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
    func `user plugin broker owns identity encoding and rejects compressed responses`() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = """
        defineProvider({
          id: "encoded-meter",
          name: "Encoded Meter",
          endpoints: ["https://encoded.example"],
          settings: [],
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
