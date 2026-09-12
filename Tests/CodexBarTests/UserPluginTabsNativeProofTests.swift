import AppKit
import Foundation
import XCTest
@testable import CodexBar
@testable import CodexBarCore

/// Opt-in interaction proof using production menus and synthetic, network-free plugins.
@MainActor
final class UserPluginTabsNativeProofTests: XCTestCase {
    func test_pluginSelectionAndScopedRefresh() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["CODEXBAR_PLUGIN_TABS_PROOF_DIR"] else {
            throw XCTSkip("Set CODEXBAR_PLUGIN_TABS_PROOF_DIR for signed native proof")
        }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        guard SettingsStore.isRunningTests,
              environment["CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS"] == "1",
              environment[CodexCredentialFileAccess.isolationEnvironmentKey] == "1",
              environment["CODEXBAR_TEST_SESSION_FILE_ISOLATION"] == "1",
              environment["CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS"] != "1",
              NSHomeDirectory().hasPrefix(output.deletingLastPathComponent().path + "/")
        else { return XCTFail("Native proof requires a contained home and credential/session isolation") }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let fixture = try CodexWorkspacesNavigationFixture(userDefaults: InMemoryUserDefaults())
        defer { fixture.cleanup() }
        let pluginsRoot = fixture.files.root.appendingPathComponent("plugins", isDirectory: true)
        try FileManager.default.createDirectory(at: pluginsRoot, withIntermediateDirectories: true)
        let topLevel = environment["CODEXBAR_PLUGIN_TABS_PROOF_LEGACY"] != "1"
        try Self.writePlugins(to: pluginsRoot, topLevel: topLevel)
        let loader = UserProviderPluginLoader(
            providersDirectory: pluginsRoot,
            cacheDirectory: fixture.files.root.appendingPathComponent("plugin-cache"),
            transport: PluginProofNoNetwork())
        let plugins = UserProviderPluginRegistry.refresh(loader: loader).compactMap(\.plugin)
        XCTAssertEqual(plugins.count, 3)
        defer {
            try? FileManager.default.removeItem(at: pluginsRoot)
            UserProviderPluginRegistry.refresh(loader: loader)
        }
        fixture.settings.mergeIcons = true
        fixture.settings.selectedMenuProvider = .codex
        fixture.settings.mergedMenuLastSelectedWasOverview = false
        for plugin in plugins {
            fixture.settings.setPluginEnabled(plugin.manifest.id, enabled: true)
            try fixture.store.pluginApprovalStore.record(plugin.approvalBinding(settings: [:]))
            fixture.store.snapshots[plugin.manifest.id] = UsageSnapshot(
                primary: RateWindow(usedPercent: 50, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                tertiary: nil,
                updatedAt: Date())
        }
        fixture.store._setSnapshotForTesting(UsageSnapshot(
            primary: RateWindow(usedPercent: 25, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            updatedAt: Date()), provider: .codex)
        let oldRendering = StatusItemController.menuCardRenderingEnabled
        let oldRefresh = StatusItemController.menuRefreshEnabled
        StatusItemController.menuCardRenderingEnabled = true
        StatusItemController.setMenuRefreshEnabledForTesting(true)
        defer {
            StatusItemController.menuCardRenderingEnabled = oldRendering
            StatusItemController.setMenuRefreshEnabledForTesting(oldRefresh)
        }
        let controller = fixture.makeController()
        defer { controller.releaseStatusItemsForTesting() }
        let app = NSApplication.shared
        guard app.delegate == nil else { return XCTFail("Use a standalone test application") }
        let previousApp = NSWorkspace.shared.frontmostApplication
        let previousPolicy = app.activationPolicy()
        let host = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 650, height: 800),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        host.title = "CodexBar — Synthetic Plugin Tabs"
        host.isReleasedWhenClosed = false
        func addButton(_ title: String, x: CGFloat, action: @escaping @MainActor (NSButton) -> Void) {
            let button = PluginProofButton(frame: NSRect(x: x, y: 725, width: 185, height: 32))
            button.title = title
            button.callback = action
            button.target = button
            button.action = #selector(PluginProofButton.activate)
            host.contentView?.addSubview(button)
        }
        addButton("Open usage menu", x: 20) { button in
            controller.statusItem.menu?.popUp(
                positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
        }
        addButton("Plugins only", x: 230) { _ in
            if let metadata = ProviderRegistry.shared.metadata[.codex] {
                fixture.settings.setProviderEnabled(provider: .codex, metadata: metadata, enabled: false)
                controller.refreshProviderSelectionDependentUI(refreshOpenMenus: true)
            }
        }
        var finished = false
        addButton("Finish proof", x: 440) { _ in finished = true }
        var seenSelections = Set<String>()
        var seenCards = Set<String>()
        let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated {
                let menu = controller.statusItem.menu
                let selection = controller.selectedMenuProvider?.rawValue ?? "none"
                seenSelections.insert(selection)
                let cards = menu?.items.compactMap { $0.representedObject as? String }
                    .filter { $0.hasPrefix("pluginCard:") } ?? []
                seenCards.formUnion(cards)
                let receipt: [String: Any] = [
                    "pid": ProcessInfo.processInfo.processIdentifier,
                    "window": host.windowNumber,
                    "topLevel": topLevel,
                    "selection": selection,
                    "seenSelections": seenSelections.sorted(),
                    "cards": cards,
                    "tabs": (menu?.items.first?.view as? ProviderSwitcherView)?._test_segmentTitles() ?? [],
                    "used": Dictionary(uniqueKeysWithValues: plugins.map {
                        ($0.manifest.id.rawValue, fixture.store.snapshots[$0.manifest.id]?.primary?.usedPercent ?? -1)
                    }),
                    "firstParty": fixture.store.enabledFirstPartyProvidersForDisplay().map(\.rawValue),
                    "openMenus": controller.openMenus.count,
                ]
                do {
                    try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
                        .write(to: output.appendingPathComponent("state.json"), options: .atomic)
                } catch { XCTFail("Could not write native proof receipt") }
            }
        }
        defer {
            timer.invalidate()
            controller.statusItem.menu?.cancelTracking()
            host.close()
            _ = app.setActivationPolicy(previousPolicy)
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                previousApp?.activate()
            }
        }
        _ = app.setActivationPolicy(.regular)
        app.finishLaunching()
        host.center()
        host.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        RunLoop.main.add(timer, forMode: .common)
        let deadline = Date().addingTimeInterval(600)
        while !finished, Date() < deadline {
            if let event = app.nextEvent(
                matching: .any, until: Date().addingTimeInterval(0.02), inMode: .default, dequeue: true)
            { app.sendEvent(event) }
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(finished, "Native proof timed out")
        XCTAssertTrue(seenCards.contains("pluginCard:legacy-meter"))
        if topLevel {
            XCTAssertTrue(seenSelections.contains("atlas-quota"))
            XCTAssertTrue(seenSelections.contains("boreal-quota"))
            let atlas = try XCTUnwrap(ProviderInstanceID(rawValue: "atlas-quota"))
            let boreal = try XCTUnwrap(ProviderInstanceID(rawValue: "boreal-quota"))
            XCTAssertEqual(fixture.store.snapshots[atlas]?.primary?.usedPercent, 24)
            XCTAssertEqual(fixture.store.snapshots[boreal]?.primary?.usedPercent, 50)
            XCTAssertTrue(fixture.store.enabledFirstPartyProvidersForDisplay().isEmpty)
        }
    }

    private static func writePlugins(to pluginsRoot: URL, topLevel: Bool) throws {
        for (id, name, monogram, tint, used, primaryTab) in [
            ("atlas-quota", "Atlas Quota", "AQ", "#336699", 24, true),
            ("boreal-quota", "Boreal Quota", "BQ", "#8054B3", 63, true),
            ("legacy-meter", "Legacy Meter", "LM", "#398A64", 40, false),
        ] {
            let source = """
            defineProvider({
              id: "\(id)", name: "\(name)",
              icon: {monogram: "\(monogram)", tint: "\(tint)"},
              topLevel: \(topLevel && primaryTab),
              endpoints: ["https://example.com"], settings: [],
              fetchUsage() { return {primary: {usedPercent: \(used)}}; }
            });
            """
            try Data(source.utf8).write(to: pluginsRoot.appendingPathComponent(id + ".js"))
        }
    }
}

@MainActor
private final class PluginProofButton: NSButton {
    var callback: (@MainActor (NSButton) -> Void)?

    @objc func activate() {
        self.callback?(self)
    }
}

private struct PluginProofNoNetwork: ProviderHTTPTransport {
    func data(for _: URLRequest) async throws -> (Data, URLResponse) {
        XCTFail("Synthetic plugin proof must not make network requests")
        throw URLError(.unsupportedURL)
    }
}
