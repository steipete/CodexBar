import AppKit
import SwiftUI
import XCTest
@testable import CodexBar
@testable import CodexBarCore

/// Opt-in native proof through the actual status-item and editor data builders.
@MainActor
final class MenuBarBalanceNativeProofTests: XCTestCase {
    func test_balanceLayout() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["CODEXBAR_BALANCE_PROOF_DIR"] else {
            throw XCTSkip("Set CODEXBAR_BALANCE_PROOF_DIR for isolated native UI proof.")
        }
        guard SettingsStore.isRunningTests,
              environment["CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS"] == "1",
              environment[CodexCredentialFileAccess.isolationEnvironmentKey] == "1",
              environment["CODEXBAR_TEST_SESSION_FILE_ISOLATION"] == "1",
              environment["CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS"] != "1",
              environment["CODEXBAR_TEST_CODEX_FILE_FIXTURES"] == nil
        else { return XCTFail("Native proof requires credential and session isolation.") }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let root = directory.appendingPathComponent("fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let providers: [UsageProvider] = [.deepseek, .poe, .openrouter]
        let settings = try Self.settings(root: root, providers: providers)
        defer { settings.configFileWatcher?.stop() }
        let tokens: [MenuBarLayoutToken] = environment["CODEXBAR_BALANCE_PROOF_WITH_RESET"] == "1"
            ? [.icon, .percent(window: .automatic), .separatorDot, .resetCountdown]
            : [.icon, .percent(window: .automatic)]
        let layout = MenuBarLayout(lines: [tokens])
        settings.setMenuBarLayout(layout, for: nil)
        let isolated = ["HOME": root.path, "CODEX_HOME": root.appendingPathComponent("codex").path]
        settings._test_codexReconciliationEnvironment = isolated
        let store = UsageStore(
            fetcher: UsageFetcher(environment: isolated),
            browserDetection: BrowserDetection(homeDirectory: root.path, cacheTTL: 0),
            costUsageFetcher: CostUsageFetcher(cacheRoot: root.appendingPathComponent("cost")),
            settings: settings,
            historicalUsageHistoryStore: HistoricalUsageHistoryStore(fileURL: root.appendingPathComponent("history")),
            planUtilizationHistoryStore: PlanUtilizationHistoryStore(directoryURL: nil),
            startupBehavior: .testing,
            environmentBase: isolated,
            widgetSnapshotURL: root.appendingPathComponent("widget.json"),
            widgetTimelineReloader: {})
        store._test_providerRefreshOverride = { _ in XCTFail("Unexpected provider transport") }
        store._test_widgetSnapshotSaveOverride = { _ in }
        defer { store.stopSharedSpendDashboardPublication() }
        var snapshots = Self.snapshots(zero: false)
        for (provider, snapshot) in snapshots {
            store._setSnapshotForTesting(snapshot, provider: provider)
            store._setErrorForTesting(nil, provider: provider)
        }
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(
                email: nil,
                plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system,
            menuRefreshEnabled: false,
            observeProviderConfigNotifications: false)
        defer { controller.releaseStatusItemsForTesting() }
        let app = NSApplication.shared
        guard app.delegate == nil else { return XCTFail("Requires a standalone test application") }
        let oldPolicy = app.activationPolicy()
        let previousApp = NSWorkspace.shared.frontmostApplication
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 280),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "CodexBar — Synthetic Balance Proof"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: VStack(alignment: .leading, spacing: 22) {
            Text("Menu bar layout").font(.title2.bold())
            Text("Synthetic data · actual editor previews").foregroundStyle(.secondary)
            ForEach(providers, id: \.self) { provider in
                HStack {
                    Text(provider.rawValue).frame(width: 130, alignment: .leading)
                    MenuBarLayoutPreview(layout: layout, provider: provider, settings: settings, store: store)
                }
            }
        }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading))
        window.center()
        defer {
            window.close()
            _ = app.setActivationPolicy(oldPolicy)
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                previousApp?.activate()
            }
        }
        XCTAssertTrue(app.setActivationPolicy(.regular))
        app.finishLaunching()
        app.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        var zero = false
        let deadline = Date().addingTimeInterval(600)
        let done = directory.appendingPathComponent("done")
        while !FileManager.default.fileExists(atPath: done.path), Date() < deadline {
            let requestedZero = FileManager.default.fileExists(atPath: directory.appendingPathComponent("zero").path)
            if requestedZero != zero {
                zero = requestedZero
                snapshots = Self.snapshots(zero: zero)
                for (provider, snapshot) in snapshots {
                    store._setSnapshotForTesting(snapshot, provider: provider)
                }
            }
            settings.usageBarsShowUsed = FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("show-used").path)
            var receipt: [String: Any] = [
                "pid": ProcessInfo.processInfo.processIdentifier,
                "window": window.windowNumber,
                "zero": zero,
                "showUsed": settings.usageBarsShowUsed,
            ]
            for provider in providers {
                let snapshot = try XCTUnwrap(snapshots[provider])
                let item = controller.lazyStatusItem(for: provider)
                let applied = controller.applyStoredMenuBarLayoutIfNeeded(
                    provider: provider,
                    snapshot: snapshot,
                    icon: ProviderBrandIcon.image(for: provider),
                    warningFlash: false,
                    statusItem: item)
                XCTAssertNotNil(applied, "Must exercise the stored layout path")
                let data = controller.menuBarLayoutRenderData(
                    provider: provider, snapshot: snapshot, warningFlash: false)
                let preview = MenuBarLayoutPreview(layout: layout, provider: provider, settings: settings, store: store)
                    .liveData(provider: provider, snapshot: snapshot)
                let button = try XCTUnwrap(item.button)
                receipt[provider.rawValue] = [
                    "automaticText": data.automaticText ?? "nil",
                    "previewAutomaticText": preview.automaticText ?? "nil",
                    "accessibility": button.accessibilityTitle() ?? "nil",
                    "width": item.length, "visible": item.isVisible,
                    "frame": NSStringFromRect(button.window?.frame ?? .zero),
                ]
            }
            try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("state.json"), options: .atomic)
            if let event = app.nextEvent(
                matching: .any, until: Date().addingTimeInterval(0.05), inMode: .default, dequeue: true)
            { app.sendEvent(event) }
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: done.path), "Native proof timed out")
    }

    private static func snapshots(zero: Bool) -> [UsageProvider: UsageSnapshot] {
        let now = Date()
        return [
            .deepseek: DeepSeekUsageSnapshot(
                isAvailable: !zero,
                currency: "CNY",
                totalBalance: zero ? 0 : 100,
                grantedBalance: 0,
                toppedUpBalance: zero ? 0 : 100,
                updatedAt: now).toUsageSnapshot(),
            .poe: UsageSnapshot(
                primary: nil,
                secondary: nil,
                updatedAt: now,
                identity: ProviderIdentitySnapshot(
                    providerID: .poe,
                    accountEmail: nil,
                    accountOrganization: nil,
                    loginMethod: "Balance: 512 points")),
            .openrouter: OpenRouterUsageSnapshot(
                totalCredits: 50,
                totalUsage: 37.66,
                balance: 12.34,
                usedPercent: 75.32,
                keyLimit: 20,
                keyUsage: 5,
                rateLimit: nil,
                updatedAt: now).toUsageSnapshot(),
        ]
    }

    private static func settings(root: URL, providers: [UsageProvider]) throws -> SettingsStore {
        let defaults = InMemoryUserDefaults(values: [
            "debugDisableKeychainAccess": true, "codexbar.legacySecretsMigrationCompleted": true,
            "providerDetectionCompleted": true, "openAIWebAccessEnabled": false, "launchAtLogin": false,
            "tokenCostUsageEnabled": false, "agentSessionsEnabled": false, "iCloudSyncEnabled": false,
        ])
        let config = CodexBarConfigStore(fileURL: root.appendingPathComponent("config.json"))
        try config.save(CodexBarConfig(providers: UsageProvider.allCases.map {
            ProviderConfig(id: $0.instanceID, enabled: providers.contains($0))
        }))
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: config,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore(),
            codexCookieStore: InMemoryCookieHeaderStore(),
            claudeCookieStore: InMemoryCookieHeaderStore(),
            cursorCookieStore: InMemoryCookieHeaderStore(),
            opencodeCookieStore: InMemoryCookieHeaderStore(),
            factoryCookieStore: InMemoryCookieHeaderStore(),
            minimaxCookieStore: InMemoryMiniMaxCookieStore(),
            minimaxAPITokenStore: InMemoryMiniMaxAPITokenStore(),
            kimiTokenStore: InMemoryKimiTokenStore(),
            augmentCookieStore: InMemoryCookieHeaderStore(),
            ampCookieStore: InMemoryCookieHeaderStore(),
            copilotTokenStore: InMemoryCopilotTokenStore(),
            tokenAccountStore: InMemoryTokenAccountStore(fileURL: root.appendingPathComponent("accounts.json")),
            antigravityOAuthCredentialsStore: AntigravityOAuthCredentialsStore(
                fileURL: root.appendingPathComponent("antigravity.json")),
            keychainAccessPolicy: .init(setDisabled: { _ in }, isExplicitlyDisabled: { true }),
            performInitialProviderDetection: false)
        settings.refreshFrequency = .manual
        settings.refreshAllProvidersOnMenuOpen = false
        settings.statusChecksEnabled = false
        settings.openAIWebAccessEnabled = false
        settings.costUsageEnabled = false
        settings.mergeIcons = false
        settings.hidePersonalInfo = true
        settings.menuBarIconStyle = .iconAndPercent
        settings.menuBarLayoutConditionals = []
        return settings
    }
}
