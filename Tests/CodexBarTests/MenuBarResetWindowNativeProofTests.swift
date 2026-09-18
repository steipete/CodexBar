import AppKit
import SwiftUI
import XCTest
@testable import CodexBar
@testable import CodexBarCore

/// Native test-host evidence, deliberately separate from ordinary application startup.
@MainActor
final class MenuBarResetWindowNativeProofTests: XCTestCase {
    func test_pointerEditorAndTimerDelivery() throws {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_RESET_POINTER_DIR"] else {
            throw XCTSkip("Set CODEXBAR_RESET_POINTER_DIR for isolated pointer proof")
        }
        guard SettingsStore.isRunningTests,
              ProcessInfo.processInfo.environment["CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS"] == "1"
        else { return XCTFail("Requires an isolated test host") }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let defaults = InMemoryUserDefaults(values: ["debugDisableKeychainAccess": true])
        let config = CodexBarConfigStore(fileURL: output.appendingPathComponent("config.json"))
        try config.save(CodexBarConfig(providers: UsageProvider.allCases.map {
            ProviderConfig(id: $0.instanceID, enabled: $0 == .claude)
        }))
        let settings = self.settings(defaults: defaults, config: config)
        defer { settings.configFileWatcher?.stop() }
        settings.menuBarIconStyle = .iconAndPercent
        settings.setMenuBarLayout(MenuBarLayout(lines: [[.icon, .percent(window: .automatic)]]), for: nil)
        let isolated = ["HOME": output.path, "CODEX_HOME": output.appendingPathComponent("codex").path]
        let store = UsageStore(
            fetcher: UsageFetcher(environment: isolated),
            browserDetection: BrowserDetection(homeDirectory: output.path, cacheTTL: 0),
            costUsageFetcher: CostUsageFetcher(cacheRoot: output.appendingPathComponent("cost")),
            settings: settings,
            historicalUsageHistoryStore: HistoricalUsageHistoryStore(fileURL: output.appendingPathComponent("history")),
            planUtilizationHistoryStore: PlanUtilizationHistoryStore(directoryURL: nil),
            startupBehavior: .testing,
            environmentBase: isolated,
            widgetSnapshotURL: output.appendingPathComponent("widget.json"),
            widgetTimelineReloader: {})
        store._test_providerRefreshOverride = { _ in XCTFail("Unexpected provider transport") }
        store._test_widgetSnapshotSaveOverride = { _ in }
        defer { store.stopSharedSpendDashboardPublication() }
        Self.seedPointerWindows(store: store)
        let app = NSApplication.shared
        guard app.delegate == nil else { return XCTFail("Requires a standalone test application") }
        let previousPolicy = app.activationPolicy()
        let previousApp = NSWorkspace.shared.frontmostApplication
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 850),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "CodexBar Synthetic Reset Editor Proof"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ScrollView {
            MenuBarLayoutEditor(settings: settings, store: store).padding(20)
        }.preferredColorScheme(.light))
        defer {
            window.close()
            _ = app.setActivationPolicy(previousPolicy)
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                previousApp?.activate()
            }
        }
        _ = app.setActivationPolicy(.regular)
        app.finishLaunching()
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        let done = output.appendingPathComponent("done").path
        let deadline = Date().addingTimeInterval(600)
        while !FileManager.default.fileExists(atPath: done), Date() < deadline {
            let receipt: [String: String] = [
                "pid": String(ProcessInfo.processInfo.processIdentifier),
                "window": String(window.windowNumber),
                "weeklyPlaced": String(settings.menuBarLayout.lines.joined()
                    .contains(.windowResetCountdown(window: .weekly))),
            ]
            try JSONEncoder().encode(receipt).write(to: output.appendingPathComponent("state.json"), options: .atomic)
            if let event = app.nextEvent(
                matching: .any, until: Date().addingTimeInterval(0.02), inMode: .default, dequeue: true)
            {
                app.sendEvent(event)
            }
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: done), "Pointer proof timed out")
        XCTAssertTrue(settings.menuBarLayout.lines.joined().contains(.windowResetCountdown(window: .weekly)))
        let reloaded = self.settings(defaults: defaults, config: config)
        defer { reloaded.configFileWatcher?.stop() }
        XCTAssertEqual(reloaded.menuBarLayout, settings.menuBarLayout)
        try self.capture(window: window, output: output, name: "pointer-selected")
        try self.proveTimerDelivery(settings: settings, store: store, output: output)
    }

    private static func seedPointerWindows(store: UsageStore) {
        let now = Date()
        store._setSnapshotForTesting(UsageSnapshot(
            primary: RateWindow(
                usedPercent: 20,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(3600),
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 40,
                windowMinutes: 10080,
                resetsAt: now.addingTimeInterval(362),
                resetDescription: nil),
            updatedAt: now), provider: .claude)
    }

    private func proveTimerDelivery(settings: SettingsStore, store: UsageStore, output: URL) throws {
        Self.seedPointerWindows(store: store)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system,
            menuRefreshEnabled: false,
            observeProviderConfigNotifications: false)
        defer { controller.releaseStatusItemsForTesting() }
        controller.updateIcons()
        let button = try XCTUnwrap(controller.statusItems[.claude]?.button)
        let before = try XCTUnwrap(button.accessibilityTitle())
        XCTAssertTrue(controller._test_isMenuBarCountdownRefreshScheduled())
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 3))
        let after = try XCTUnwrap(button.accessibilityTitle())
        XCTAssertNotEqual(before, after, "The real scheduled controller task must refresh the status-item output")
        try JSONEncoder().encode(["before": before, "after": after, "delivery": "scheduled controller task"])
            .write(to: output.appendingPathComponent("timer.json"), options: .atomic)
    }

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
