import AppKit
import CodexBarCore
import Foundation
import Observation
import SwiftUI
import XCTest
@testable import CodexBar

/// Opt-in pointer-driven proof using production provider settings and contained synthetic stores.
@MainActor
final class ProviderUsageItemVisibilityNativeProofTests: XCTestCase {
    func test_interactiveVisibilityAndReload() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["CODEXBAR_USAGE_VISIBILITY_NATIVE_PROOF_DIR"] else {
            throw XCTSkip("Set CODEXBAR_USAGE_VISIBILITY_NATIVE_PROOF_DIR for native proof.")
        }
        guard SettingsStore.isRunningTests,
              environment["CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS"] == "1",
              environment[CodexCredentialFileAccess.isolationEnvironmentKey] == "1",
              environment["CODEXBAR_TEST_SESSION_FILE_ISOLATION"] == "1",
              environment["CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS"] != "1"
        else { return XCTFail("Native proof requires credential and session isolation") }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let state = try UsageVisibilityNativeState(root: root)
        defer { state.store.stopSharedSpendDashboardPublication() }
        let app = NSApplication.shared
        guard app.delegate == nil else { return XCTFail("Use a standalone native test host") }
        let previousApp = NSWorkspace.shared.frontmostApplication
        let oldPolicy = app.activationPolicy()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 760),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "CodexBar — Synthetic Usage Visibility"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: UsageVisibilityNativeView(state: state))
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
        let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated {
                do {
                    let receipt = state.receipt(window: window)
                    try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys, .prettyPrinted])
                        .write(to: root.appendingPathComponent("state.json"), options: .atomic)
                } catch { XCTFail("Could not persist synthetic proof receipt") }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        defer { timer.invalidate() }
        let done = root.appendingPathComponent("done").path
        let deadline = Date().addingTimeInterval(600)
        while !FileManager.default.fileExists(atPath: done), Date() < deadline {
            if let event = app.nextEvent(
                matching: .any, until: Date().addingTimeInterval(0.02), inMode: .default, dequeue: true)
            { app.sendEvent(event) }
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: done), "Native proof timed out")
        XCTAssertGreaterThan(state.reloads, 0, "Exercise a persisted reload")
        XCTAssertTrue(state.settings.hiddenUsageItemIDs(for: .codex).contains(.metric("primary")))
        XCTAssertFalse(state.model(for: .codex).metrics.contains { $0.id == "primary" })
        XCTAssertTrue(state.model(for: .claude).metrics.contains { $0.id == "primary" })
        XCTAssertEqual(state.settings.providerConfigRevision(for: .codex), state.fetchRevision)
        let disk = try XCTUnwrap(state.configStore.load())
        XCTAssertTrue(disk.providers.first { $0.id == .codex }?.hiddenUsageItemIDs?.contains("metric:primary") == true)
    }
}

@MainActor
@Observable
private final class UsageVisibilityNativeState {
    let root: URL
    let configStore: CodexBarConfigStore
    var settings: SettingsStore
    var store: UsageStore
    var reloads = 0
    var fetchRevision: UInt64

    init(root: URL) throws {
        self.root = root
        self.configStore = CodexBarConfigStore(fileURL: root.appendingPathComponent("config.json"))
        if try self.configStore.load() == nil {
            try self.configStore.save(CodexBarConfig(providers: UsageProvider.allCases.map {
                ProviderConfig(id: $0.instanceID, enabled: [.codex, .claude].contains($0))
            }))
        }
        let settings = Self.makeSettings(root: root, configStore: self.configStore)
        self.settings = settings
        self.store = Self.makeStore(root: root, settings: settings)
        self.fetchRevision = settings.providerConfigRevision(for: .codex)
    }

    func reload() {
        self.store.stopSharedSpendDashboardPublication()
        self.settings = Self.makeSettings(root: self.root, configStore: self.configStore)
        self.store = Self.makeStore(root: self.root, settings: self.settings)
        self.fetchRevision = self.settings.providerConfigRevision(for: .codex)
        self.reloads += 1
    }

    func model(for provider: UsageProvider) -> UsageMenuCardView.Model {
        ProvidersPane(provider: provider, settings: self.settings, store: self.store).menuCardModel(for: provider)
    }

    func receipt(window: NSWindow) -> [String: Any] {
        [
            "pid": ProcessInfo.processInfo.processIdentifier,
            "window": window.windowNumber,
            "reloads": self.reloads,
            "hidden": self.settings.hiddenUsageItemIDs(for: .codex).map(\.rawValue).sorted(),
            "codexMetrics": self.model(for: .codex).metrics.map(\.id),
            "claudeMetrics": self.model(for: .claude).metrics.map(\.id),
            "fetchRevisionUnchanged": self.settings.providerConfigRevision(for: .codex) == self.fetchRevision,
        ]
    }

    private static func makeSettings(root: URL, configStore: CodexBarConfigStore) -> SettingsStore {
        let defaults = InMemoryUserDefaults(values: [
            AppGroupSupport.migrationVersionKey: AppGroupSupport.migrationVersion,
            "codexbar.legacySecretsMigrationCompleted": true,
            "providerDetectionCompleted": true,
            "debugDisableKeychainAccess": true,
        ])
        let settings = ProviderUsageItemVisibilityTests.settings(defaults: defaults, configStore: configStore)
        settings._test_managedCodexAccountStoreURL = root.appendingPathComponent("managed-accounts.json")
        settings._test_codexReconciliationEnvironment = self.environment(root: root)
        settings.statusChecksEnabled = false
        settings.openAIWebAccessEnabled = false
        settings.costUsageEnabled = false
        settings.refreshFrequency = .manual
        return settings
    }

    private static func environment(root: URL) -> [String: String] {
        [
            "HOME": root.path,
            "CODEX_HOME": root.appendingPathComponent("codex-home").path,
            "XDG_CONFIG_HOME": root.appendingPathComponent("xdg-config").path,
        ]
    }

    private static func makeStore(root: URL, settings: SettingsStore) -> UsageStore {
        let environment = self.environment(root: root)
        let store = UsageStore(
            fetcher: UsageFetcher(environment: environment),
            browserDetection: BrowserDetection(homeDirectory: root.path, cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: environment)
        store._test_providerRefreshOverride = { _ in XCTFail("Unexpected provider transport") }
        store._test_widgetSnapshotSaveOverride = { _ in }
        for provider in [UsageProvider.codex, .claude] {
            store._setSnapshotForTesting(UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 25,
                    windowMinutes: 300,
                    resetsAt: Date().addingTimeInterval(3600),
                    resetDescription: nil),
                secondary: RateWindow(
                    usedPercent: 60,
                    windowMinutes: 10080,
                    resetsAt: Date().addingTimeInterval(172_800),
                    resetDescription: nil),
                updatedAt: Date()), provider: provider)
        }
        return store
    }
}

@MainActor
private struct UsageVisibilityNativeView: View {
    @Bindable var state: UsageVisibilityNativeState

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Synthetic data · production provider settings")
                Spacer()
                Button("Reload persisted settings") { self.state.reload() }
                    .accessibilityIdentifier("proof-reload-settings")
            }
            .padding(12)
            ProvidersPane(provider: .codex, settings: self.state.settings, store: self.state.store)
                .id(self.state.reloads)
        }
    }
}
