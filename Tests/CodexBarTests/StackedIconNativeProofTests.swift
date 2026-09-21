import AppKit
import SwiftUI
import XCTest
@testable import CodexBar
@testable import CodexBarCore

@MainActor
final class StackedIconNativeProofTests: XCTestCase {
    func test_interactiveSyntheticSettingsAndStatusItem() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["CODEXBAR_STACKED_PROOF_DIR"] else {
            throw XCTSkip("Set CODEXBAR_STACKED_PROOF_DIR for signed synthetic computer-use proof")
        }
        guard SettingsStore.isRunningTests,
              env["CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS"] == "1",
              env[CodexCredentialFileAccess.isolationEnvironmentKey] == "1",
              env["CODEXBAR_TEST_SESSION_FILE_ISOLATION"] == "1",
              env["CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS"] != "1"
        else { return XCTFail("Use an isolated test host") }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let settings = testSettingsStore(
            suiteName: "StackedIconProof",
            userDefaults: InMemoryUserDefaults(),
            config: testConfigWithAllProvidersDisabled())
        settings.mergeIcons = true
        settings.menuBarIconStyle = .iconAndPercent
        settings.usageBarsShowUsed = true
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.randomBlinkEnabled = false
        enableTestProviders([.codex, .claude], settings: settings)
        settings.setMenuBarLayout(MenuBarLayout(lines: [[.icon, .percent(window: .automatic)]]), for: nil)
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        store._setSnapshotForTesting(Self.snapshot(provider: .codex, used: 25), provider: .codex)
        store._setSnapshotForTesting(Self.snapshot(provider: .claude, used: 60), provider: .claude)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection())
        defer {
            controller.releaseStatusItemsForTesting()
            settings.configFileWatcher?.stop()
        }
        let app = NSApplication.shared
        let previousApp = NSWorkspace.shared.frontmostApplication
        let previousPolicy = app.activationPolicy()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 900),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "CodexBar — Synthetic stacked icon proof"
        window.isReleasedWhenClosed = false
        let claudeMetadata = try XCTUnwrap(ProviderRegistry.shared.metadata[.claude])
        let view = VStack(spacing: 0) {
            MenuBarPane(settings: settings, store: store)
            HStack {
                Text("Synthetic data only").foregroundStyle(.secondary)
                Button("Change Claude usage") {
                    store._setSnapshotForTesting(Self.snapshot(provider: .claude, used: 85), provider: .claude)
                }
                Button("Toggle Claude") {
                    let enabled = settings.isProviderEnabled(provider: .claude, metadata: claudeMetadata)
                    settings.setProviderEnabled(
                        provider: .claude,
                        metadata: claudeMetadata,
                        enabled: !enabled)
                }
                Button("Finish proof") {
                    FileManager.default.createFile(atPath: output.appendingPathComponent("done").path, contents: Data())
                }
            }.padding(12)
        }
        window.contentView = NSHostingView(rootView: view.environment(\.locale, Locale(identifier: "en_US")))
        defer {
            window.close()
            _ = app.setActivationPolicy(previousPolicy)
            previousApp?.activate()
        }
        _ = app.setActivationPolicy(.regular)
        app.finishLaunching()
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        let deadline = Date().addingTimeInterval(480)
        repeat {
            let button = controller.statusItem.button
            let receipt: [String: Any] = [
                "pid": ProcessInfo.processInfo.processIdentifier,
                "window": window.windowNumber,
                "syntheticOnly": true,
                "requestedStyle": settings.mergedIconDisplayStyle.rawValue,
                "effectiveStyle": settings.mergedIconPresentation(
                    activeProviders: store.enabledFirstPartyProvidersForDisplay()).effectiveStyle.rawValue,
                "title": button?.attributedTitle.string ?? "",
                "accessibility": button?.accessibilityTitle() ?? "",
            ]
            try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
                .write(to: output.appendingPathComponent("state.json"), options: .atomic)
            if FileManager.default.fileExists(atPath: output.appendingPathComponent("done").path) { return }
            try await Task.sleep(for: .milliseconds(150))
        } while Date() < deadline
        XCTFail("Native proof was not completed before its deadline")
    }

    private static func snapshot(provider: UsageProvider, used: Double) -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(
                usedPercent: used,
                windowMinutes: 300,
                resetsAt: Date().addingTimeInterval(7200),
                resetDescription: nil),
            secondary: nil,
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: provider.instanceID,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: "Synthetic"))
    }
}
