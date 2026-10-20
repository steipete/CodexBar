#if canImport(JavaScriptCore)
import AppKit
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
        #expect(plugin.manifest.topLevel)

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

    @MainActor
    @Test
    func `sole top level plugin renders independently without a switcher`() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.write(
            name: "solo.js",
            source: Self.menuPlugin(id: "solo-meter", name: "Solo Meter"))
        let plugin = try #require(UserProviderPluginRegistry.refresh(
            loader: fixture.loader(transport: RecordingTransport(responseJSON: "{}"))).first?.plugin)
        let (controller, store, settings) = Self.makePluginMenuController(
            suiteName: "UserProviderPluginTests.soleTopLevel",
            selectedPluginID: plugin.manifest.id,
            enabledPluginIDs: [plugin.manifest.id],
            approvalStore: fixture.approvals)
        defer { controller.releaseStatusItemsForTesting() }

        let menu = try #require(controller.statusItem.menu)
        controller.populateMenu(menu, provider: nil)

        #expect(store.enabledFirstPartyProvidersForDisplay().isEmpty)
        #expect(controller.shouldMergeIcons)
        #expect(controller.statusItem.isVisible)
        #expect(menu === controller.mergedMenu)
        #expect(!(menu.items.first?.view is ProviderSwitcherView))
        #expect(Self.pluginCardIDs(in: menu) == ["pluginCard:solo-meter"])
        #expect(settings.selectedMenuProvider == plugin.manifest.id)
        #expect(controller.manualRefreshProvider(for: menu) == plugin.manifest.id)
    }

    @MainActor
    @Test
    func `top level plugin tabs retain legacy plugin cards without built in providers`() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.write(
            name: "first.js",
            source: Self.menuPlugin(id: "first-meter", name: "First Meter"))
        _ = try fixture.write(
            name: "second.js",
            source: Self.menuPlugin(id: "second-meter", name: "Second Meter"))
        _ = try fixture.write(
            name: "legacy.js",
            source: Self.menuPlugin(id: "legacy-meter", name: "Legacy Meter", topLevel: false))
        let plugins = UserProviderPluginRegistry.refresh(
            loader: fixture.loader(transport: RecordingTransport(responseJSON: "{}"))).compactMap(\.plugin)
        let firstID = try #require(ProviderInstanceID(rawValue: "first-meter"))
        let secondID = try #require(ProviderInstanceID(rawValue: "second-meter"))
        let (controller, store, settings) = Self.makePluginMenuController(
            suiteName: "UserProviderPluginTests.legacyCards",
            selectedPluginID: firstID,
            enabledPluginIDs: plugins.map(\.manifest.id),
            approvalStore: fixture.approvals)
        defer { controller.releaseStatusItemsForTesting() }

        let menu = controller.makeMenu()
        controller.populateMenu(menu, provider: nil)
        #expect(store.enabledFirstPartyProvidersForDisplay().isEmpty)
        #expect(menu.items.first?.view is ProviderSwitcherView)
        #expect(Self.pluginCardIDs(in: menu) == ["pluginCard:first-meter", "pluginCard:legacy-meter"])

        let wideDescriptor = MenuDescriptor(sections: [
            MenuDescriptor.Section(entries: [
                .action(String(repeating: "W", count: 60), .dashboard),
            ]),
        ])
        let measuredWidth = controller.measuredStandardMenuWidth(
            for: wideDescriptor.sections,
            baseWidth: StatusItemController.menuCardBaseWidth)
        #expect(measuredWidth > StatusItemController.menuCardBaseWidth)
        #expect(controller.menuCardWidth(
            for: [],
            selectedProvider: nil,
            descriptor: wideDescriptor) == measuredWidth)

        settings.selectedMenuProvider = secondID
        controller.populateMenu(menu, provider: nil)
        #expect(Self.pluginCardIDs(in: menu) == ["pluginCard:second-meter", "pluginCard:legacy-meter"])

        settings.mergedMenuLastSelectedWasOverview = true
        controller.populateMenu(menu, provider: nil)
        #expect(controller.includesOverviewTab(enabledProviders: []))
        let overviewIDs = menu.items.compactMap { $0.representedObject as? String }
            .filter { $0.hasPrefix("overviewRow-") }
        #expect(Set(overviewIDs) == Set(plugins.map { "overviewRow-\($0.manifest.id.rawValue)" }))
        #expect(Self.pluginCardIDs(in: menu).isEmpty)
    }

    @MainActor
    @Test
    func `top level plugin cache signature distinguishes delimiter containing metadata`() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source: (String, String) -> String = { name, monogram in
            """
            defineProvider({
              id: "collision-meter",
              name: "\(name)",
              icon: { monogram: "\(monogram)", tint: "#336699" },
              endpoints: ["https://collision.example"],
              settings: [],
              fetchUsage() { return { primary: { usedPercent: 12 } }; },
            });
            """
        }
        let url = try fixture.write(name: "collision.js", source: source("A:B", "C"))
        let firstPlugin = try #require(UserProviderPluginRegistry.refresh(
            loader: fixture.loader(transport: RecordingTransport(responseJSON: "{}"))).first?.plugin)
        let (controller, _, _) = Self.makePluginMenuController(
            suiteName: "UserProviderPluginTests.cacheSignature",
            selectedPluginID: firstPlugin.manifest.id,
            enabledPluginIDs: [firstPlugin.manifest.id],
            approvalStore: fixture.approvals)
        defer { controller.releaseStatusItemsForTesting() }

        let firstSignature = controller.menuLocalizationSignature()
        try Data(source("A", "B:C").utf8).write(to: url, options: .atomic)
        _ = UserProviderPluginRegistry.refresh(
            loader: fixture.loader(transport: RecordingTransport(responseJSON: "{}")))

        #expect(controller.menuLocalizationSignature() != firstSignature)
    }

    @MainActor
    @Test
    func `opening a selected top level plugin does not schedule Codex dashboard refresh`() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.write(
            name: "selected.js",
            source: Self.menuPlugin(id: "selected-meter", name: "Selected Meter"))
        let plugin = try #require(UserProviderPluginRegistry.refresh(
            loader: fixture.loader(transport: RecordingTransport(responseJSON: "{}"))).first?.plugin)
        let (controller, _, settings) = Self.makePluginMenuController(
            suiteName: "UserProviderPluginTests.menuOpenOwnership",
            selectedPluginID: plugin.manifest.id,
            enabledPluginIDs: [plugin.manifest.id],
            approvalStore: fixture.approvals)
        defer { controller.releaseStatusItemsForTesting() }
        try settings.setProviderEnabled(
            provider: .codex,
            metadata: #require(ProviderRegistry.shared.metadata[.codex]),
            enabled: true)
        controller.menuRefreshEnabledOverrideForTesting = true

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)

        #expect(controller.lastMenuProvider == plugin.manifest.id)
        #expect(controller.deferredOpenAIDashboardRefreshReason == nil)
    }

    @MainActor
    @Test(arguments: [false, true])
    func `persistent refresh targets the selected user plugin`(keyboard: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.write(
            name: "first.js",
            source: Self.menuPlugin(id: "first-meter", name: "First Meter"))
        _ = try fixture.write(
            name: "second.js",
            source: Self.menuPlugin(id: "second-meter", name: "Second Meter"))
        let plugins = UserProviderPluginRegistry.refresh(
            loader: fixture.loader(transport: RecordingTransport(responseJSON: "{}"))).compactMap(\.plugin)
        let selectedID = try #require(ProviderInstanceID(rawValue: "second-meter"))
        let selectedPlugin = try #require(plugins.first { $0.manifest.id == selectedID })
        try fixture.approvals.record(selectedPlugin.approvalBinding(settings: [:]))
        let (controller, store, settings) = Self.makePluginMenuController(
            suiteName: "UserProviderPluginTests.selectedRefresh",
            selectedPluginID: selectedID,
            enabledPluginIDs: plugins.map(\.manifest.id),
            approvalStore: fixture.approvals)
        defer {
            controller.manualRefreshTasks.values.forEach { $0.cancel() }
            controller.releaseStatusItemsForTesting()
        }

        controller.menuRefreshEnabledOverrideForTesting = true
        let menu = try #require(controller.statusItem.menu as? StatusItemMenu)
        controller.menuWillOpen(menu)
        #expect(controller.manualRefreshProvider(for: menu) == selectedID)
        try settings.setProviderEnabled(
            provider: .codex,
            metadata: #require(ProviderRegistry.shared.metadata[.codex]),
            enabled: true)
        settings.mergedMenuLastSelectedWasOverview = true
        #expect(controller.isMergedOverviewSelected(in: menu))
        settings.mergedMenuLastSelectedWasOverview = false
        #expect(!controller.isMergedOverviewSelected(in: menu))
        store.refreshingProviders.insert(plugins[0].manifest.id)
        #expect(!controller.isRefreshActionInFlight(for: menu))
        store.refreshingProviders.remove(plugins[0].manifest.id)
        if keyboard {
            let event = try #require(NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.command],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "r",
                charactersIgnoringModifiers: "r",
                isARepeat: false,
                keyCode: 15))
            #expect(menu.performKeyEquivalent(with: event))
            for _ in 0..<20 where controller.manualRefreshTasks[.provider(selectedID)] == nil {
                await Task.yield()
            }
        } else {
            controller.refreshMenuProviderNow(in: menu)
        }

        #expect(controller.manualRefreshTasks[.provider(selectedID)] != nil)
        #expect(controller.manualRefreshTasks[.global] == nil)
        #expect(controller.manualRefreshTasks[.provider(.codex)] == nil)
        #expect(controller.isRefreshActionInFlight(for: menu))

        await controller.manualRefreshTasks[.provider(selectedID)]?.value
        #expect(store.snapshots[selectedID]?.primary?.usedPercent == 12)
        let menuID = ObjectIdentifier(menu)
        for _ in 0..<20 where controller.menuNeedsRefresh(menu) {
            if let rebuild = controller.openMenuRebuildTasks[menuID] {
                await rebuild.value
            } else {
                await Task.yield()
            }
        }
        #expect(!controller.menuSession.isParentRebuildDeferred(menuID))
        let menuIsFresh = !controller.menuNeedsRefresh(menu)
        #expect(menuIsFresh)
        #expect(controller.manualRefreshProvider(for: menu) == selectedID)
    }

    @Test
    func `top level manifest field rejects non boolean values`() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = """
        defineProvider({
          id: "proxy-meter",
          name: "Proxy Meter",
          topLevel: "yes",
          endpoints: ["https://proxy.example"],
          settings: [],
          fetchUsage() { return { primary: { usedPercent: 12 } }; },
        });
        """

        #expect(throws: ProviderPluginError.self) {
            try fixture.loader(transport: RecordingTransport(responseJSON: "{}"))
                .load(fileURL: fixture.write(name: "invalid-top-level.js", source: source))
        }
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

    @Test(arguments: [false, true])
    func `delete removes source cache approval secrets config and history`(unavailableAtLoad: Bool) throws {
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
        if unavailableAtLoad {
            config = try JSONDecoder().decode(CodexBarConfig.self, from: JSONEncoder().encode(config))
            #expect(config.providers.isEmpty)
            #expect(config.unavailableProviders.count == 1)
        }
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
        #expect(config.unavailableProviders.isEmpty)
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

extension UserProviderPluginTests {
    @MainActor
    @Test(arguments: [nil, true, false] as [Bool?])
    func `plugin placement respects default explicit override and unmerged menus`(topLevel: Bool?) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.write(
            name: "placement.js",
            source: Self.menuPlugin(id: "placement-meter", name: "Placement Meter", topLevel: topLevel))
        let plugin = try #require(UserProviderPluginRegistry.refresh(
            loader: fixture.loader(transport: RecordingTransport(responseJSON: "{}"))).first?.plugin)
        #expect(plugin.manifest.topLevel == (topLevel ?? true))
        let (controller, _, settings) = Self.makePluginMenuController(
            suiteName: "UserProviderPluginTests.placement",
            selectedPluginID: .codex,
            enabledPluginIDs: [plugin.manifest.id],
            approvalStore: fixture.approvals)
        defer { controller.releaseStatusItemsForTesting() }
        for provider in [UsageProvider.codex, .claude] {
            try settings.setProviderEnabled(
                provider: provider,
                metadata: #require(ProviderRegistry.shared.metadata[provider]),
                enabled: true)
        }
        let expectedCards = topLevel == false ? ["pluginCard:placement-meter"] : []
        for overview in [false, true] {
            settings.mergedMenuLastSelectedWasOverview = overview
            let menu = controller.makeMenu()
            controller.populateMenu(menu, provider: nil)
            #expect(Self.pluginCardIDs(in: menu) == (overview ? [] : expectedCards))
            if overview {
                #expect(menu.items.contains { ($0.representedObject as? String) == "overviewRow-placement-meter" })
            }
            let switcher = try #require(menu.items.first?.view as? ProviderSwitcherView)
            #expect(switcher._test_segmentTitles().contains("Placement Meter") == (topLevel != false))
            controller.warmMergedSwitcherSiblingContent(in: menu)
            let caches = controller.mergedSwitcherContentCaches[ObjectIdentifier(menu)] ?? [:]
            let cachedPlugin = caches[.provider(plugin.manifest.id)]
            #expect((cachedPlugin != nil) == (topLevel != false))
        }
        settings.mergeIcons = false
        settings.mergedMenuLastSelectedWasOverview = false
        let unmerged = controller.makeMenu()
        controller.populateMenu(unmerged, provider: .codex)
        #expect(!controller.shouldMergeIcons)
        #expect(!(unmerged.items.first?.view is ProviderSwitcherView))
        #expect(Self.pluginCardIDs(in: unmerged) == ["pluginCard:placement-meter"])
        settings.setPluginEnabled(plugin.manifest.id, enabled: false)
        controller.populateMenu(unmerged, provider: .codex)
        #expect(Self.pluginCardIDs(in: unmerged).isEmpty)
        #expect(controller.topLevelUserProviderPlugins().isEmpty)
    }

    @MainActor
    @Test
    func `render default plugin placement with synthetic production menus`() throws {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_PLUGIN_DEFAULT_PROOF_DIR"] else { return }
        try #require(ProcessInfo.processInfo.environment["CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS"] == "1")
        try #require(ProcessInfo.processInfo.environment["CODEXBAR_TEST_CODEX_FILE_ISOLATION"] == "1")
        try #require(ProcessInfo.processInfo.environment["CODEXBAR_TEST_SESSION_FILE_ISOLATION"] == "1")
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.write(
            name: "github-ratelimit.js",
            source: Self.menuPlugin(id: "github-ratelimit", name: "GitHub Rate Limit"))
        let plugin = try #require(UserProviderPluginRegistry.refresh(
            loader: fixture.loader(transport: RecordingTransport(responseJSON: "{}"))).first?.plugin)
        let previousRendering = StatusItemController.menuCardRenderingEnabled
        StatusItemController.menuCardRenderingEnabled = true
        defer { StatusItemController.menuCardRenderingEnabled = previousRendering }
        let (controller, store, settings) = Self.makePluginMenuController(
            suiteName: "UserProviderPluginTests.renderDefault",
            selectedPluginID: .codex,
            enabledPluginIDs: [plugin.manifest.id],
            approvalStore: fixture.approvals)
        defer { controller.releaseStatusItemsForTesting() }
        settings.costUsageEnabled = false
        settings.hidePersonalInfo = true
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 25, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date())
        for provider in [UsageProvider.codex, .claude] {
            try settings.setProviderEnabled(
                provider: provider,
                metadata: #require(ProviderRegistry.shared.metadata[provider]),
                enabled: true)
            store._setSnapshotForTesting(snapshot, provider: provider)
        }
        store.snapshots[plugin.manifest.id] = snapshot
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stage = plugin.manifest.topLevel ? "after" : "before"
        var receipt: [String: [String]] = [:]
        for selection in ["codex", "overview", "plugin"] {
            if selection == "plugin", !plugin.manifest.topLevel { continue }
            settings.selectedMenuProvider = selection == "plugin" ? plugin.manifest.id : .codex
            settings.mergedMenuLastSelectedWasOverview = selection == "overview"
            let menu = controller.makeMenu()
            controller.populateMenu(menu, provider: nil)
            receipt[selection + "Cards"] = Self.pluginCardIDs(in: menu)
            receipt[selection + "Tabs"] = (menu.items.first?.view as? ProviderSwitcherView)?
                ._test_segmentTitles() ?? []
            // Use the actual menu's production views; no desktop capture or real provider data.
            let rows = menu.items.compactMap(\.view)
            let canvas = PluginMenuProofCanvas(frame: NSRect(
                x: 0,
                y: 0,
                width: (rows.map(\.frame.width).max() ?? 310) + 16,
                height: rows.reduce(16) { $0 + $1.frame.height + 4 }))
            canvas.appearance = NSAppearance(named: .aqua)
            canvas.wantsLayer = true
            canvas.layer?.backgroundColor = NSColor.white.cgColor
            var y: CGFloat = 8
            for row in rows {
                let wrapper = NSView(frame: NSRect(origin: NSPoint(x: 8, y: y), size: row.frame.size))
                row.setFrameOrigin(.zero)
                wrapper.addSubview(row)
                canvas.addSubview(wrapper)
                y += row.frame.height + 4
            }
            let png = try #require(MenuLayoutScreenshotRenderTests.pngDataWithWindow(hosting: canvas))
            try png.write(to: directory.appendingPathComponent("\(stage)-\(selection).png"))
        }
        try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys, .prettyPrinted])
            .write(to: directory.appendingPathComponent("\(stage)-menus.json"))
    }

    @MainActor
    @Test
    func `plugin svg icon is kept and rendered as a template image`() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let svg = #"""
        <svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 16 16">
        <path d="M2 2h12v12H2z"/></svg>
        """#
        _ = try fixture.write(name: "svg.js", source: Self.iconPlugin(id: "svg-meter", svg: svg))
        let plugin = try #require(UserProviderPluginRegistry.refresh(
            loader: fixture.loader(transport: RecordingTransport(responseJSON: "{}"))).first?.plugin)

        #expect(plugin.manifest.icon.svg == svg)
        let open = #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16">"#
        for paint in ["none", "currentColor", "black", "#fff", "#336699cc", "rgb(1, 2, 3)", "rgba(0,0,0,50%)"] {
            let shape = #"<path d="M2 2h12v12H2z" fill=""# + paint + #"" stroke=""# + paint
                + #"" transform="rotate(45 8 8)"/>"#
            #expect(ProviderPluginIconSVG.isValid(open + shape + "</svg>"), "rejected: \(paint)")
        }
        #expect(plugin.manifest.icon.monogram == "SV")
        let image = try #require(StatusItemController.userPluginSVGImage(plugin))
        #expect(image.isTemplate)
        #expect(image.size == NSSize(width: 16, height: 16))
        let bitmap = try #require(image.representations.first as? NSBitmapImageRep)
        #expect(bitmap.pixelsWide == 32)
        #expect(bitmap.pixelsHigh == 32)
        #expect(image.representations.count == 1)
        let center = try #require(bitmap.colorAt(x: 16, y: 16))
        #expect(center.alphaComponent > 0.9)
    }

    @Test
    func `unsafe or oversized svg icons fall back to the monogram`() throws {
        let open = #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16">"#
        let rejected = [
            #"<svg width="1000000000" height="16"><path d="M0 0h1v1z"/></svg>"#,
            #"<svg viewBox="0 0 1e100 16"><path d="M0 0h1v1z"/></svg>"#,
            #"<svg width="16" viewBox="0 0 16 1e-99"><path d="M0 0h1v1z"/></svg>"#,
            open + "<script>alert(1)</script></svg>",
            open + "<style>path{fill:red}</style></svg>",
            open + "<foreignObject><div/></foreignObject></svg>",
            open + #"<image href="https://example.com/x.png"/></svg>"#,
            open + #"<path d="M0 0h1v1z" fill="url(#g)"/></svg>"#,
            open + #"<path d="M0 0h1v1z" onload="x()"/></svg>"#,
            // CSS escapes, comments and character references cannot smuggle a URL past the check.
            open + #"<path d="M0 0h1v1z" fill="u\72l(https://example.com/p.svg#x)"/></svg>"#,
            open + #"<path d="M0 0h1v1z" stroke="U\52L(#g)"/></svg>"#,
            open + #"<path d="M0 0h1v1z" fill="&#117;rl(#g)"/></svg>"#,
            open + #"<path d="M0 0h1v1z" fill="red;background:url(x)"/></svg>"#,
            open + #"<path d="M0 0h1v1z" fill="/**/red"/></svg>"#,
            #"<svg xmlns="https://example.com/other" viewBox="0 0 16 16"><path d="M0 0h1v1z"/></svg>"#,
            // Red team: other ways to reference or inject.
            open + #"<path d="M0 0h1v1z" fill="&#x55;RL(#g)"/></svg>"#,
            open + #"<path d="M0 0h1v1z" fill="\#u{FF55}\#u{FF52}\#u{FF4C}(#g)"/></svg>"#,
            open + #"<path d="M0 0h1v1z" fill="url (#g)"/></svg>"#,
            open + #"<path d="M0 0h1v1z" fill="image-set(&quot;x.png&quot; 1x)"/></svg>"#,
            open + #"<path d="M0 0h1v1z" style="fill:red"/></svg>"#,
            open + ##"<use href="#a"/></svg>"##,
            open + #"<a href="https://example.com"><path d="M0 0h1v1z"/></a></svg>"#,
            open + #"<path xlink:href="https://example.com/x" d="M0 0h1v1z"/></svg>"#,
            #"<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"><path d="M0 0h1v1z"/></svg>"#,
            #"<svg xmlns="http://www.w3.org/2000/svg" xml:base="https://example.com/"><path d="M0 0h1v1z"/></svg>"#,
            open + #"<path xmlns="https://example.com/other" d="M0 0h1v1z"/></svg>"#,
            #"<?xml-stylesheet href="https://example.com/s.css"?><svg xmlns="http://www.w3.org/2000/svg"/>"#,
            open + #"<path d="M0 0h1v1z" fill="red&#59;x"/></svg>"#,
            open + #"<path d="M0 0h1v1z" fill="image-set(x.png 1x)"/></svg>"#,
            open + #"<path d="M0 0h1v1z" stroke="paint(x)"/></svg>"#,
            open + #"<path d="M0 0h1v1z" fill="var(--x)"/></svg>"#,
            open + "<path d=\"M0 0h1v1z\" fill=\"red\u{0}\"/></svg>",
            #"<!DOCTYPE svg [<!ENTITY x "y">]><svg><path d="&x;"/></svg>"#,
            #"<g><path d="M0 0h1v1z"/></g>"#,
            open + #"<path d=""# + String(repeating: "M0 0h1v1z", count: 1000) + #""/></svg>"#,
            "",
        ]
        for svg in rejected {
            #expect(!ProviderPluginIconSVG.isValid(svg), "accepted: \(svg.prefix(60))")
        }

        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.write(name: "bad.js", source: Self.iconPlugin(id: "bad-meter", svg: rejected[0]))
        let plugin = try #require(UserProviderPluginRegistry.refresh(
            loader: fixture.loader(transport: RecordingTransport(responseJSON: "{}"))).first?.plugin)
        #expect(plugin.manifest.icon.svg == nil)
        #expect(plugin.manifest.icon.monogram == "SV")
        #expect(ProviderPluginIcon(monogram: "SV", tint: "#336699", svg: rejected[0]).svg == nil)
    }

    private static func iconPlugin(id: String, svg: String) -> String {
        // Test SVGs contain no backticks or `${`, so a JS template literal carries them verbatim.
        let literal = "`" + svg + "`"
        return """
        defineProvider({
          id: "\(id)",
          name: "SVG Meter",
          icon: { monogram: "SV", tint: "#0176D3", svg: \(literal) },
          endpoints: ["https://\(id).example"],
          settings: [],
          fetchUsage() { return { primary: { usedPercent: 12 } }; },
        });
        """
    }

    private static func menuPlugin(id: String, name: String, topLevel: Bool? = nil) -> String {
        """
        defineProvider({
          id: "\(id)",
          name: "\(name)",
          \(topLevel.map { "topLevel: \($0)," } ?? "")
          endpoints: ["https://\(id).example"],
          settings: [],
          fetchUsage() { return { primary: { usedPercent: 12 } }; },
        });
        """
    }

    @MainActor
    private static func makePluginMenuController(
        suiteName: String,
        selectedPluginID: ProviderInstanceID,
        enabledPluginIDs: [ProviderInstanceID],
        approvalStore: ProviderPluginApprovalStore)
        -> (StatusItemController, UsageStore, SettingsStore)
    {
        let settings = testSettingsStore(
            suiteName: suiteName,
            userDefaults: InMemoryUserDefaults(),
            tokenAccountStore: InMemoryTokenAccountStore())
        settings.providerDetectionCompleted = true
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = selectedPluginID
        for provider in UsageProvider.allCases {
            guard let metadata = ProviderRegistry.shared.metadata[provider] else { continue }
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: false)
        }
        for pluginID in enabledPluginIDs {
            settings.setPluginEnabled(pluginID, enabled: true)
        }
        let fetcher = UsageFetcher()
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            pluginApprovalStore: approvalStore)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: testStatusBar())
        return (controller, store, settings)
    }

    @MainActor
    private static func pluginCardIDs(in menu: NSMenu) -> [String] {
        menu.items.compactMap { $0.representedObject as? String }.filter { $0.hasPrefix("pluginCard:") }
    }
}

extension UserProviderPluginTests {
    @Test(arguments: [false, true])
    func `recovered plugin settings retain secrets without duplicating the opaque record`(opaqueNumber: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let id = try #require(ProviderInstanceID(rawValue: "recovered-fixture"))
        let raw = #"""
        {"version":1,"providers":[{"id":"recovered-fixture","enabled":true,
         "pluginSettings":{"REGION":"west"},"pluginSecrets":{"TOKEN":"fixture-secret"}}]}
        """#
        let input = opaqueNumber ? raw.replacingOccurrences(
            of: "\"enabled\":true", with: "\"enabled\":true,\"future\":1.0000000000000000000000000001") : raw
        // Use a distinct ID for each argument so registry state cannot pre-load the next fixture.
        let fixtureID = opaqueNumber ? "recovered-numeric-fixture" : id.rawValue
        var config = try CodexBarConfig.decode(from: Data(input.replacingOccurrences(
            of: id.rawValue, with: fixtureID).utf8))
        #expect(config.unavailableProviders.count == 1)
        _ = try fixture.write(name: "recover.js", source: Self.javaScriptPlugin(id: fixtureID))
        UserProviderPluginRegistry.refresh(loader: fixture.loader(transport: RecordingTransport(responseJSON: "{}")))
        let recoveredID = try #require(ProviderInstanceID(rawValue: fixtureID))
        var provider = try #require(config.providerConfig(for: recoveredID))
        provider.enabled = false
        config.setProviderConfig(provider)
        let saved = try config.encodedData()
        if opaqueNumber {
            let text = try #require(String(data: saved, encoding: .utf8))
            #expect(text.contains("1.0000000000000000000000000001"))
        }
        let reloaded = try CodexBarConfig.decode(from: saved)
        #expect(reloaded.providers.count == (opaqueNumber ? 0 : 1))
        #expect(reloaded.providerConfig(for: recoveredID)?.enabled == opaqueNumber)
        #expect(reloaded.providerConfig(for: recoveredID)?.pluginSecrets == ["TOKEN": "fixture-secret"])
        #expect(reloaded.providerConfig(for: recoveredID)?.pluginSettings == ["REGION": "west"])
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

@MainActor
private final class PluginMenuProofCanvas: NSView {
    override var isFlipped: Bool {
        true
    }

    override var fittingSize: NSSize {
        self.frame.size
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
        UserProviderPluginRegistry.refresh(loader: UserProviderPluginLoader(
            providersDirectory: self.root.appendingPathComponent("empty"),
            cacheDirectory: self.cache))
        try? FileManager.default.removeItem(at: self.root)
    }
}

extension UserProviderPluginTests {
    @MainActor
    @Test
    func `top level plugin becomes a stable provider switcher segment`() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = """
        defineProvider({
          id: "proxy-meter",
          name: "Proxy Meter",
          icon: { monogram: "PM", tint: "#336699" },
          endpoints: ["https://proxy.example"],
          settings: [],
          fetchUsage() { return { primary: { usedPercent: 12 } }; },
        });
        """
        _ = try fixture.write(name: "proxy.js", source: source)
        let plugin = try #require(UserProviderPluginRegistry.refresh(
            loader: fixture.loader(transport: RecordingTransport(responseJSON: "{}"))).first?.plugin)
        var selected: ProviderSwitcherSelection?
        let view = ProviderSwitcherView(
            providers: [.codex],
            pluginProviders: [plugin],
            selected: .provider(.codex),
            includesOverview: false,
            width: 240,
            showsIcons: true,
            iconProvider: { _ in NSImage(size: NSSize(width: 16, height: 16)) },
            pluginIconProvider: { _ in NSImage(size: NSSize(width: 16, height: 16)) },
            weeklyRemainingProvider: { _ in 75 },
            onSelect: { selected = $0 })

        #expect(plugin.manifest.topLevel)
        #expect(view._test_quotaIndicatorFillRatios() == [0.75, 0.75])
        #expect(view._test_segmentTitles() == ["Codex", "Proxy Meter"])
        #expect(view._test_simulateRuntimeClick(buttonTag: 1))
        #expect(selected == .provider(plugin.manifest.id))

        #expect(StatusItemController.userPluginsForMenu(
            [plugin],
            isEnabled: { _ in true },
            topLevelSwitcherVisible: true,
            selectedPluginID: nil).isEmpty)
        #expect(StatusItemController.userPluginsForMenu(
            [plugin],
            isEnabled: { _ in true },
            topLevelSwitcherVisible: true,
            selectedPluginID: plugin.manifest.id).map(\.manifest.id) == [plugin.manifest.id])
        #expect(StatusItemController.isUserPluginSelection(.provider(plugin.manifest.id)))
        #expect(!StatusItemController.isUserPluginSelection(.provider(.codex)))
        #expect(ProviderSwitcherSelection.provider(plugin.manifest.id).provider == nil)
        #expect(ProviderSwitcherSelection.provider(.codex).provider == .codex)
        #expect(StatusItemController.resolvedSwitcherProviderID(
            providerIDs: [plugin.manifest.id],
            selectedProviderID: nil,
            fallbackProviderID: .codex) == plugin.manifest.id)

        let previousMenuCardRendering = StatusItemController.menuCardRenderingEnabled
        let previousMenuRefresh = StatusItemController.menuRefreshEnabled
        StatusItemController.menuCardRenderingEnabled = false
        StatusItemController.setMenuRefreshEnabledForTesting(false)
        defer {
            StatusItemController.menuCardRenderingEnabled = previousMenuCardRendering
            StatusItemController.setMenuRefreshEnabledForTesting(previousMenuRefresh)
        }
        let (controller, store, settings) = Self.makePluginMenuController(
            suiteName: "UserProviderPluginTests.topLevelMenuCards",
            selectedPluginID: plugin.manifest.id,
            enabledPluginIDs: [plugin.manifest.id],
            approvalStore: fixture.approvals)
        defer { controller.releaseStatusItemsForTesting() }

        let emptyMenu = NSMenu()
        controller.addUserPluginMenuCards(to: emptyMenu, width: 240, selectedPluginID: plugin.manifest.id)
        #expect(emptyMenu.items.first?.isSeparatorItem == false)
        #expect(emptyMenu.items.first?.representedObject as? String == "pluginCard:proxy-meter")

        let menuAfterSeparator = NSMenu()
        menuAfterSeparator.addItem(.separator())
        controller.addUserPluginMenuCards(to: menuAfterSeparator, width: 240, selectedPluginID: plugin.manifest.id)
        let emptyIDs = emptyMenu.items.map { $0.representedObject as? String }
        let separatedIDs = menuAfterSeparator.items.dropFirst().map { $0.representedObject as? String }
        #expect(emptyIDs == separatedIDs)

        try settings.setProviderEnabled(
            provider: .codex,
            metadata: #require(ProviderRegistry.shared.metadata[.codex]),
            enabled: true)
        settings.setProviderOrder([plugin.manifest.id, .codex])
        #expect(controller.overviewProviderIDs(enabledProviders: [.codex]) == [plugin.manifest.id, .codex])
        let active: [ProviderInstanceID] = [.codex, plugin.manifest.id]
        _ = settings.setMergedOverviewProviderSelection(provider: .codex, isSelected: false, activeProviders: active)
        #expect(settings.resolvedMergedOverviewProviders(activeProviders: active) == [plugin.manifest.id])
        let exported = try settings.exportPreferences()
        #expect(try exported
            .value("mergedOverviewSelectedProviders", as: [String].self) == [plugin.manifest.id.rawValue])
        settings.mergedMenuLastSelectedWasOverview = true
        settings.usageBarsShowUsed = false
        store.snapshots[plugin.manifest.id] = UsageSnapshot(
            primary: RateWindow(usedPercent: 20, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 75, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            updatedAt: .distantPast)
        let overview = controller.makeMenu()
        controller.populateMenu(overview, provider: nil)
        #expect(controller.includesOverviewTab(enabledProviders: [.codex]))
        let overviewRow = try #require(overview.items.first {
            ($0.representedObject as? String) == "overviewRow-proxy-meter"
        })
        #expect(overviewRow.action == #selector(StatusItemController.selectOverviewProvider(_:)))
        #expect(Self.pluginCardIDs(in: overview).isEmpty)
        #expect(controller.switcherWeeklyRemaining(for: plugin.manifest.id) == 25)
        controller.selectOverviewProvider(plugin.manifest.id, menu: overview)
        #expect(settings.selectedMenuProvider == plugin.manifest.id)
        #expect(!settings.mergedMenuLastSelectedWasOverview)
    }
}

#endif
