import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

/// The flicker probe's `ProbeSession` is driven by a `[weak self]` timer, so it
/// only works while something strong owns the session. These tests pin the
/// ownership contract (sessions live in `MenuSwitchFlickerProbe.activeSessions`
/// until `finish()`) and prove a session actually records switch activity and
/// frame samples when run against a synthetic merged menu.
@MainActor
@Suite(.serialized)
struct MenuSwitchFlickerProbeTests {
    private func makeSettings() -> SettingsStore {
        let suite = "MenuSwitchFlickerProbeTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        return SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
    }

    @Test
    func `retained probe session records switch activity and frame samples`() throws {
        let previousMenuCardRendering = StatusItemController.menuCardRenderingEnabled
        let previousMenuRefresh = StatusItemController.menuRefreshEnabled
        StatusItemController.menuCardRenderingEnabled = false
        StatusItemController.setMenuRefreshEnabledForTesting(false)
        defer {
            StatusItemController.menuCardRenderingEnabled = previousMenuCardRendering
            StatusItemController.setMenuRefreshEnabledForTesting(previousMenuRefresh)
        }

        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        let registry = ProviderRegistry.shared
        for provider in UsageProvider.allCases {
            guard let metadata = registry.metadata[provider] else { continue }
            let shouldEnable = provider == .codex || provider == .claude
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: shouldEnable)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system)

        // Synthetic merged menu: the switcher view is hosted in a real window so
        // the session can resolve a window number for its frame grabber.
        let switcher = ProviderSwitcherView(
            providers: [.codex, .claude],
            selected: .provider(.codex),
            includesOverview: true,
            width: 320,
            showsIcons: false,
            iconProvider: { _ in NSImage() },
            weeklyRemainingProvider: { _ in nil },
            onSelect: { _ in })
        let menu = StatusItemMenu()
        let switcherItem = NSMenuItem()
        switcherItem.view = switcher
        menu.addItem(switcherItem)
        menu.addItem(.separator())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        defer { window.orderOut(nil) }
        window.contentView?.addSubview(switcher)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("flicker-probe-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var sessionWasRetainedWhileRunning = false
        func pumpSession() {
            controller.openMenus[ObjectIdentifier(menu)] = menu
            let deadline = Date().addingTimeInterval(10)
            while let session = MenuSwitchFlickerProbe.activeSessions.last,
                  session.timer != nil,
                  Date() < deadline
            {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
            controller.openMenus.removeValue(forKey: ObjectIdentifier(menu))
        }

        var configuration = MenuSwitchFlickerProbe.ProbeSession.Configuration()
        configuration.switchScheduleMs = [40, 80, 120, 160, 200, 240]
        configuration.sessionEndMs = 400
        configuration.openMenu = {
            // Stand-in for NSMenu's blocking tracking loop: expose the menu the
            // way tracking would and pump the run loop until the session's
            // timer schedule completes.
            sessionWasRetainedWhileRunning = !MenuSwitchFlickerProbe.activeSessions.isEmpty
            pumpSession()
        }

        MenuSwitchFlickerProbe.beginRetainedSession(
            controller: controller,
            directory: directory,
            holdMode: false,
            configuration: configuration)

        #expect(sessionWasRetainedWhileRunning, "session must be strongly owned while it runs")
        #expect(MenuSwitchFlickerProbe.activeSessions.isEmpty, "finished session must be released")

        let log = try String(contentsOf: directory.appendingPathComponent("probe-log.txt"), encoding: .utf8)
        #expect(log.contains("menu located"), "probe never found the open menu: \(log)")
        #expect(log.contains("handled=true"), "probe never performed a switch: \(log)")

        let capturedLine = try #require(
            log.split(separator: "\n").first { $0.hasPrefix("captured ") },
            "probe log missing sample summary: \(log)")
        let sampleCount = try #require(Int(capturedLine.split(separator: " ")[1]))
        #expect(sampleCount > 0, "probe recorded no frame samples: \(log)")

        let overdueDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("flicker-probe-overdue-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: overdueDirectory) }
        var overdueConfiguration = MenuSwitchFlickerProbe.ProbeSession.Configuration()
        overdueConfiguration.switchScheduleMs = [0, 0, 0, 0, 0, 0]
        overdueConfiguration.sessionEndMs = 0
        overdueConfiguration.openMenu = { pumpSession() }

        MenuSwitchFlickerProbe.beginRetainedSession(
            controller: controller,
            directory: overdueDirectory,
            holdMode: false,
            configuration: overdueConfiguration)

        let overdueLog = try String(
            contentsOf: overdueDirectory.appendingPathComponent("probe-log.txt"),
            encoding: .utf8)
        let overdueSwitches = overdueLog.split(separator: "\n").filter { $0.hasPrefix("switch#") }
        #expect(
            overdueSwitches.count == 6,
            "probe did not drain overdue switches one per tick: \(overdueLog)")
        #expect(
            overdueSwitches.allSatisfy { $0.contains("handled=true") },
            "probe did not handle every overdue switch: \(overdueLog)")
        #expect(MenuSwitchFlickerProbe.activeSessions.isEmpty, "overdue session must be released")
    }
}
