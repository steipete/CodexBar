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
        #expect(plugin.manifest.topLevel == false)

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
    func `top level plugin becomes a stable provider switcher segment`() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = """
        defineProvider({
          id: "proxy-meter",
          name: "Proxy Meter",
          icon: { monogram: "PM", tint: "#336699" },
          topLevel: true,
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
            weeklyRemainingProvider: { _ in nil },
            onSelect: { selected = $0 })

        #expect(plugin.manifest.topLevel)
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
        let (controller, _, _) = Self.makePluginMenuController(
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
    }

    @MainActor
    @Test
    func `sole top level plugin renders independently without a switcher`() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.write(
            name: "solo.js",
            source: Self.menuPlugin(id: "solo-meter", name: "Solo Meter", topLevel: true))
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
            source: Self.menuPlugin(id: "first-meter", name: "First Meter", topLevel: true))
        _ = try fixture.write(
            name: "second.js",
            source: Self.menuPlugin(id: "second-meter", name: "Second Meter", topLevel: true))
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
              topLevel: true,
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
            source: Self.menuPlugin(id: "selected-meter", name: "Selected Meter", topLevel: true))
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
    @Test
    func `persistent refresh targets the selected user plugin`() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.write(
            name: "first.js",
            source: Self.menuPlugin(id: "first-meter", name: "First Meter", topLevel: true))
        _ = try fixture.write(
            name: "second.js",
            source: Self.menuPlugin(id: "second-meter", name: "Second Meter", topLevel: true))
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
        #expect(!controller.isMergedOverviewSelected(in: menu))
        store.refreshingProviders.insert(plugins[0].manifest.id)
        #expect(!controller.isRefreshActionInFlight(for: menu))
        store.refreshingProviders.remove(plugins[0].manifest.id)
        controller.refreshMenuProviderNow(in: menu)

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

extension UserProviderPluginTests {
    private static func menuPlugin(id: String, name: String, topLevel: Bool) -> String {
        """
        defineProvider({
          id: "\(id)",
          name: "\(name)",
          topLevel: \(topLevel),
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
