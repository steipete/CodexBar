#if canImport(JavaScriptCore)
import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@Suite(.serialized)
@MainActor
struct UserPluginRefreshTests {
    enum Change: CaseIterable {
        case disable, disableAndReenable, setting, settingAndRestore, secret, reload, remove
    }

    @Test(arguments: Change.allCases, [false, true])
    func `obsolete plugin results and errors cannot publish`(change: Change, failure: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let request = Task { await fixture.store.refreshUserPlugin(fixture.id) }
        try await fixture.transport.waitForRequests(1)

        switch change {
        case .disable:
            fixture.settings.setPluginEnabled(fixture.id, enabled: false)
            fixture.store.clearDisabledProviderState(enabledProviders: Set(UsageProvider.allCases.map(\.instanceID)))
        case .disableAndReenable:
            fixture.settings.setPluginEnabled(fixture.id, enabled: false)
            fixture.settings.setPluginEnabled(fixture.id, enabled: true)
        case .setting:
            fixture.settings.updatePluginConfig(instanceID: fixture.id) { $0.pluginSettings = ["ACCOUNT": "second"] }
        case .settingAndRestore:
            fixture.settings.updatePluginConfig(instanceID: fixture.id) { $0.pluginSettings = ["ACCOUNT": "second"] }
            fixture.settings.updatePluginConfig(instanceID: fixture.id) { $0.pluginSettings = ["ACCOUNT": "first"] }
        case .secret:
            fixture.settings.updatePluginConfig(instanceID: fixture.id) { $0.pluginSecrets = ["TOKEN": "new-fixture"] }
        case .reload:
            fixture.store.refreshUserPluginDiscovery(loader: fixture.loader)
        case .remove:
            try FileManager.default.removeItem(at: fixture.pluginURL)
            fixture.store.refreshUserPluginDiscovery(loader: fixture.loader)
        }

        await fixture.transport.finish(1, used: 42, failure: failure)
        await request.value
        #expect(fixture.store.snapshots[fixture.id] == nil)
        #expect(fixture.store.errors[fixture.id] == nil)
        #expect(fixture.store.lastSourceLabels[fixture.id] == nil)
        #expect(!fixture.store.refreshingProviders.contains(fixture.id))
    }

    @Test
    func `replacement waits for retired work and uses configuration at fetch start`() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = Task { await fixture.store.refreshUserPlugin(fixture.id) }
        try await fixture.transport.waitForRequests(1)
        var replacementEntered = false
        let replacement = Task {
            replacementEntered = true
            await fixture.store.refreshUserPlugin(fixture.id)
        }
        while !replacementEntered {
            await Task.yield()
        }
        fixture.settings.updatePluginConfig(instanceID: fixture.id) { $0.pluginSettings = ["ACCOUNT": "after-queue"] }

        await fixture.transport.finish(1, used: 10)
        await first.value
        try await fixture.transport.waitForRequests(2)
        #expect(fixture.store.snapshots[fixture.id] == nil)
        #expect(fixture.store.refreshingProviders.contains(fixture.id))
        #expect(await fixture.transport.request(2)?.url?.query == "account=after-queue")

        await fixture.transport.finish(2, used: 80)
        await replacement.value
        #expect(fixture.store.snapshots[fixture.id]?.primary?.usedPercent == 80)
        #expect(fixture.store.errors[fixture.id] == nil)
        #expect(fixture.store.lastSourceLabels[fixture.id] == "js")
        #expect(!fixture.store.refreshingProviders.contains(fixture.id))
    }

    @Test
    func `reenabled plugin owns activity while its replacement waits`() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = Task { await fixture.store.refreshUserPlugin(fixture.id) }
        try await fixture.transport.waitForRequests(1)
        fixture.settings.setPluginEnabled(fixture.id, enabled: false)
        fixture.store.clearDisabledProviderState(enabledProviders: Set(UsageProvider.allCases.map(\.instanceID)))
        fixture.settings.setPluginEnabled(fixture.id, enabled: true)
        var replacementEntered = false
        let replacement = Task {
            replacementEntered = true
            await fixture.store.refreshUserPlugin(fixture.id)
        }
        while !replacementEntered {
            await Task.yield()
        }
        #expect(fixture.store.refreshingProviders.contains(fixture.id))
        await fixture.transport.finish(1, used: 10)
        await first.value
        #expect(fixture.store.refreshingProviders.contains(fixture.id))
        try await fixture.transport.waitForRequests(2)
        await fixture.transport.finish(2, used: 80)
        await replacement.value
        #expect(fixture.store.snapshots[fixture.id]?.primary?.usedPercent == 80)
        #expect(!fixture.store.refreshingProviders.contains(fixture.id))
    }

    @Test
    func `cancelled plugin refresh does not publish a failure`() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let request = Task { await fixture.store.refreshUserPlugin(fixture.id) }
        try await fixture.transport.waitForRequests(1)
        request.cancel()
        await fixture.transport.finish(1, used: 42, failure: true)
        await request.value
        #expect(fixture.store.snapshots[fixture.id] == nil)
        #expect(fixture.store.errors[fixture.id] == nil)
        #expect(!fixture.store.refreshingProviders.contains(fixture.id))
    }

    @Test
    func `display preference changes keep a valid plugin response publishable`() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let request = Task { await fixture.store.refreshUserPlugin(fixture.id) }
        try await fixture.transport.waitForRequests(1)
        fixture.settings.updatePluginConfig(instanceID: fixture.id) { $0.accentColor = "#FF0000" }
        await fixture.transport.finish(1, used: 42)
        await request.value
        #expect(fixture.store.snapshots[fixture.id]?.primary?.usedPercent == 42)
    }

    @Test
    func `current plugin failures remain visible`() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let request = Task { await fixture.store.refreshUserPlugin(fixture.id) }
        try await fixture.transport.waitForRequests(1)
        await fixture.transport.finish(1, used: 42, failure: true)
        await request.value
        #expect(fixture.store.errors[fixture.id] != nil)
        #expect(!fixture.store.refreshingProviders.contains(fixture.id))
    }

    @MainActor
    private struct Fixture {
        let root: URL
        let pluginURL: URL
        let loader: UserProviderPluginLoader
        let transport = GatedTransport()
        let settings: SettingsStore
        let store: UsageStore
        let id: ProviderInstanceID

        init() throws {
            self.root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let providers = self.root.appendingPathComponent("providers")
            try FileManager.default.createDirectory(at: providers, withIntermediateDirectories: true)
            self.pluginURL = providers.appendingPathComponent("refresh.js")
            try Data("""
            defineProvider({
              id: "refresh-fixture", name: "Refresh Fixture",
              endpoints: ["https://usage.example"],
              settings: [{key:"ACCOUNT",title:"Account",type:"plain"},{key:"TOKEN",title:"Token",type:"secure"}],
              async fetchUsage(ctx) {
                const result = await ctx.http.getJSON("https://usage.example/usage?account=" +
                  encodeURIComponent(ctx.settings.get("ACCOUNT")));
                return {primary:{usedPercent:result.json.used}};
              }
            });
            """.utf8).write(to: self.pluginURL)
            self.loader = UserProviderPluginLoader(
                providersDirectory: providers,
                cacheDirectory: self.root.appendingPathComponent("cache"),
                transport: self.transport)
            let plugin = try #require(UserProviderPluginRegistry.refresh(loader: self.loader).first?.plugin)
            self.id = plugin.manifest.id
            let approvals = ProviderPluginApprovalStore(fileURL: self.root.appendingPathComponent("approvals.json"))
            try approvals.record(plugin.approvalBinding(settings: ["ACCOUNT": "first"]))
            self.settings = testSettingsStore(
                suiteName: "UserPluginRefreshTests",
                userDefaults: InMemoryUserDefaults())
            self.settings.refreshFrequency = .manual
            self.settings.statusChecksEnabled = false
            self.settings.updatePluginConfig(instanceID: self.id) {
                $0.enabled = true
                $0.pluginSettings = ["ACCOUNT": "first"]
                $0.pluginSecrets = ["TOKEN": "fixture"]
            }
            self.store = UsageStore(
                fetcher: UsageFetcher(environment: [:]),
                browserDetection: BrowserDetection(cacheTTL: 0),
                settings: self.settings,
                startupBehavior: .testing,
                environmentBase: [:],
                pluginApprovalStore: approvals)
        }

        func remove() {
            try? FileManager.default.removeItem(at: self.root)
            UserProviderPluginRegistry.refresh(loader: self.loader)
        }
    }

    private actor GatedTransport: ProviderHTTPTransport {
        private var requests: [URLRequest] = []
        private var continuations: [Int: CheckedContinuation<(Data, URLResponse), any Error>] = [:]

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            self.requests.append(request)
            let index = self.requests.count
            return try await withCheckedThrowingContinuation { self.continuations[index] = $0 }
        }

        func request(_ index: Int) -> URLRequest? {
            self.requests.indices.contains(index - 1) ? self.requests[index - 1] : nil
        }

        func waitForRequests(_ count: Int) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while self.requests.count < count, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(self.requests.count >= count)
        }

        func finish(_ index: Int, used: Int, failure: Bool = false) {
            guard let continuation = self.continuations.removeValue(forKey: index),
                  let url = self.request(index)?.url,
                  let response = HTTPURLResponse(
                      url: url,
                      statusCode: failure ? 401 : 200,
                      httpVersion: nil,
                      headerFields: ["Content-Type": "application/json"])
            else { return }
            continuation.resume(returning: (Data("{\"used\":\(used)}".utf8), response))
        }
    }
}
#endif
