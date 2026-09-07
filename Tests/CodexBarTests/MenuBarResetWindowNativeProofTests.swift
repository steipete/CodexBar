import AppKit
import SwiftUI
import XCTest
@testable import CodexBar
@testable import CodexBarCore

/// Native test-host evidence, deliberately separate from ordinary application startup.
@MainActor
final class MenuBarResetWindowNativeProofTests: XCTestCase {
    func test_editorAndReloadWithSyntheticWindows() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let directory = environment["CODEXBAR_RESET_NATIVE_PROOF_DIR"] else {
            throw XCTSkip("Set CODEXBAR_RESET_NATIVE_PROOF_DIR for isolated native editor proof")
        }
        guard SettingsStore.isRunningTests,
              environment["CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS"] == "1",
              environment[CodexCredentialFileAccess.isolationEnvironmentKey] == "1",
              environment["CODEXBAR_TEST_SESSION_FILE_ISOLATION"] == "1",
              environment["CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS"] != "1"
        else { return XCTFail("Native proof requires test-host, credential, Keychain and session isolation") }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let application = NSApplication.shared
        guard application.delegate == nil else { return XCTFail("Requires a standalone test application") }
        let previousPolicy = application.activationPolicy()
        let previousApplication = NSWorkspace.shared.frontmostApplication
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 850),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.title = "Reset windows — isolated native test host"
        defer {
            window.close()
            _ = application.setActivationPolicy(previousPolicy)
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                previousApplication?.activate()
            }
        }
        _ = application.setActivationPolicy(.regular)
        application.finishLaunching()
        window.center()
        window.makeKeyAndOrderFront(nil)
        application.activate(ignoringOtherApps: true)

        var records: [[String: Any]] = []
        for phase in ["fresh", "upgrade-v2"] {
            let defaults = InMemoryUserDefaults(values: ["debugDisableKeychainAccess": true])
            if phase == "upgrade-v2" {
                // Literal released discriminator/key: do not silently seed the new format instead.
                defaults.set(
                    Data(#"{"lines":[[{"resetCountdown":{}},{"resetAbsolute":{}}]]}"#.utf8),
                    forKey: "menuBarLayoutV2")
            }
            let config = CodexBarConfigStore(fileURL: output.appendingPathComponent("\(phase)-config.json"))
            try config.save(CodexBarConfig(providers: UsageProvider.allCases.map {
                ProviderConfig(id: $0.instanceID, enabled: $0 == .codex)
            }))
            let settings = self.settings(defaults: defaults, config: config)
            if phase == "upgrade-v2" {
                XCTAssertEqual(settings.menuBarLayout.lines, [[.resetCountdown, .resetAbsolute]])
            }
            let store = UsageStore(
                fetcher: UsageFetcher(),
                browserDetection: BrowserDetection(cacheTTL: 0),
                settings: settings,
                startupBehavior: .testing)
            let now = Date()
            let reset = now.addingTimeInterval(6 * 60 + 2)
            store._setSnapshotForTesting(UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 20,
                    windowMinutes: 300,
                    resetsAt: now.addingTimeInterval(3600),
                    resetDescription: nil),
                secondary: RateWindow(
                    usedPercent: 40,
                    windowMinutes: 10080,
                    resetsAt: reset,
                    resetDescription: nil),
                updatedAt: now), provider: .codex)
            window.contentView = NSHostingView(rootView: ScrollView {
                MenuBarLayoutEditor(settings: settings, store: store).padding(20)
            }.preferredColorScheme(.light))
            try self.capture(window: window, output: output, name: "\(phase)-before")
            let selected = MenuBarLayout(lines: [[
                .resetCountdown, .separatorDot, .windowResetCountdown(window: .weekly),
                .separatorDot, .windowResetAbsolute(window: .session),
            ]])
            // Exercise the same mutation/persistence entry point as editor actions; this is not a UI click claim.
            MenuBarLayoutEditorPersistence.activate(selected, for: nil, settings: settings)
            XCTAssertEqual(settings.menuBarLayout, selected)
            try self.capture(window: window, output: output, name: "\(phase)-selected")
            let reloaded = self.settings(defaults: defaults, config: config)
            XCTAssertEqual(reloaded.menuBarLayout, selected)
            window.contentView = NSHostingView(rootView: ScrollView {
                MenuBarLayoutEditor(settings: reloaded, store: store).padding(20)
            }.preferredColorScheme(.light))
            try self.capture(window: window, output: output, name: "\(phase)-reloaded")

            let tickStart = Date()
            let tickReset = tickStart.addingTimeInterval(6 * 60 + 2)
            let delay = try XCTUnwrap(StatusItemController.menuBarCountdownRefreshDelay(
                resetDates: [tickReset], now: tickStart))
            XCTAssertEqual(delay, 2.05, accuracy: 0.01)
            let before = UsageFormatter.resetCountdownDescription(from: tickReset, now: tickStart)
            // Wait a real display boundary; this verifies formatter/scheduler timing, not timer delivery in the app.
            RunLoop.main.run(until: Date(timeIntervalSinceNow: delay))
            let after = UsageFormatter.resetCountdownDescription(from: tickReset, now: Date())
            XCTAssertNotEqual(before, after)
            records.append([
                "phase": phase, "selectionAppliedVia": "MenuBarLayoutEditorPersistence.activate",
                "settingsReconstruction": "same isolated in-memory defaults, production SettingsStore loader",
                "reloadMatches": reloaded.menuBarLayout == selected,
                "countdownBefore": before, "countdownAfter": after, "schedulerDelay": delay,
                "scope": "native test host; no ordinary app startup, pointer click or automatic timer delivery claimed",
            ])
        }
        try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("native-reset-proof.json"), options: .atomic)
    }

    private func capture(window: NSWindow, output: URL, name: String) throws {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = [
            "-x",
            "-o",
            "-l",
            String(window.windowNumber),
            output.appendingPathComponent("\(name).png").path,
        ]
        try capture.run()
        capture.waitUntilExit()
        XCTAssertEqual(capture.terminationStatus, 0)
    }

    private func settings(defaults: UserDefaults, config: CodexBarConfigStore) -> SettingsStore {
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
            tokenAccountStore: InMemoryTokenAccountStore(),
            performInitialProviderDetection: false)
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        return settings
    }
}
