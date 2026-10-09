#if DEBUG
import AppKit
import CodexBarCore
import Foundation
@preconcurrency import UserNotifications

/// Documentation-only launcher. The notifier, notification delegate, AppDelegate click
/// handler, pending startup route, settings controller, and About pane remain production code.
@MainActor
enum HomebrewUpdateAppProof {
    static var isRequested: Bool {
        Bundle.main.object(forInfoDictionaryKey: "CodexBarHomebrewUpdateProof") as? Bool == true
            && Bundle.main.bundleIdentifier == "local.codexbar.homebrew-update-proof"
    }

    static let output = Bundle.main.bundleURL.deletingLastPathComponent()
    static var fetchCount = 0
    static var launchNumber = 0

    static func makeUpdater() -> HomebrewUpdaterController {
        let defaults = UserDefaults.standard
        return HomebrewUpdaterController(
            savedAutoCheck: defaults.object(forKey: "autoUpdateEnabled") as? Bool ?? true,
            dependencies: .init(
                installedVersion: { "99.0.0" },
                fetchCaskSource: {
                    await MainActor.run {
                        self.fetchCount += 1
                        self.record("cask_fetch", ["count": self.fetchCount])
                        return "version \"\(UserDefaults.standard.string(forKey: "proofVersion") ?? "99.0.1")\""
                    }
                },
                runUpgrade: { throw HomebrewUpdateError.brewNotFound },
                relaunch: {},
                cask: { .tap }),
            notifier: HomebrewUpdateNotifier(dependencies: .live))
    }

    static func runIfRequested() -> Bool {
        guard self.isRequested else { return false }
        setenv("CODEXBAR_DISABLE_KEYCHAIN_ACCESS", "1", 1)
        setenv("CODEXBAR_TEST_CODEX_FILE_ISOLATION", "1", 1)
        setenv("CODEXBAR_TEST_SESSION_FILE_ISOLATION", "1", 1)
        // Cache SettingsStore's test policy to skip app-group migration and plugin discovery.
        // Remove this flag before creating the notifier: real notifications must stay enabled.
        setenv("SWIFT_TESTING", "1", 1)
        let fixtureRoot = self.output.appendingPathComponent("fixture", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
            let settingsDefaults = ProofDefaults()
            let settings = SettingsStore(
                userDefaults: settingsDefaults,
                configStore: CodexBarConfigStore(fileURL: fixtureRoot.appendingPathComponent("config.json")),
                tokenAccountStore: FileTokenAccountStore(fileURL: fixtureRoot.appendingPathComponent("tokens.json")),
                antigravityOAuthCredentialsStore: AntigravityOAuthCredentialsStore(
                    fileURL: fixtureRoot.appendingPathComponent("antigravity.json")),
                keychainAccessPolicy: .init(setDisabled: { _ in }, isExplicitlyDisabled: { true }),
                performInitialProviderDetection: false)
            for provider in UsageProvider.allCases {
                guard let metadata = ProviderRegistry.shared.metadata[provider] else { continue }
                settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: false)
            }
            let store = UsageStore(
                fetcher: UsageFetcher(environment: [:]),
                browserDetection: BrowserDetection(
                    homeDirectory: fixtureRoot.path, fileExists: { _ in false }, directoryContents: { _ in [] }),
                settings: settings,
                startupBehavior: .testing,
                environmentBase: [:],
                widgetSnapshotURL: fixtureRoot.appendingPathComponent("widget.json"),
                widgetTimelineReloader: {})
            unsetenv("SWIFT_TESTING")
            let defaults = UserDefaults.standard
            defaults.set("en", forKey: "appLanguage")
            defaults.set("general", forKey: PreferencesSelection.paneDefaultsKey)
            self.launchNumber = defaults.integer(forKey: "proofLaunchNumber") + 1
            defaults.set(self.launchNumber, forKey: "proofLaunchNumber")
            defaults.synchronize()
            self.record("launch", [
                "saved_auto_check": defaults.object(forKey: "autoUpdateEnabled") as? Bool ?? true,
                "saved_submitted_version": defaults.string(forKey: "homebrewUpdateLastSubmittedVersion") ?? "",
                "real_notification_center": !TestProcessSafety.isRunning,
            ])
            let application = NSApplication.shared
            application.setActivationPolicy(.regular)
            let delegate = Delegate(settings: settings, store: store)
            application.delegate = delegate
            withExtendedLifetime(delegate) { application.run() }
        } catch {
            unsetenv("SWIFT_TESTING")
            self.record("fixture_error", ["type": String(describing: type(of: error))])
        }
        return true
    }

    static func record(_ event: String, _ fields: [String: Any] = [:]) {
        var value = fields
        value["event"] = event
        value["launch"] = self.launchNumber
        value["time"] = ISO8601DateFormatter().string(from: Date())
        guard var data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return }
        data.append(10)
        let file = self.output.appendingPathComponent("native-events.jsonl")
        if !FileManager.default.fileExists(atPath: file.path) {
            FileManager.default.createFile(atPath: file.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: file) else { return }
        defer { try? handle.close() }
        try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    @MainActor
    private final class Delegate: NSObject, NSApplicationDelegate {
        private let production = AppDelegate()
        private let settings: SettingsStore
        private let store: UsageStore
        private let selection = PreferencesSelection()
        private var timer: Timer?
        private var previousState = ""
        private var controlWindow: NSWindow?

        init(settings: SettingsStore, store: UsageStore) {
            self.settings = settings
            self.store = store
        }

        func applicationWillFinishLaunching(_ notification: Notification) {
            self.production.applicationWillFinishLaunching(notification)
            HomebrewUpdateAppProof.record("production_will_finish", [
                "production_notification_delegate": UNUserNotificationCenter.current().delegate === AppNotifications
                    .shared,
            ])
        }

        func applicationDidFinishLaunching(_ notification: Notification) {
            self.installMenu()
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: 210),
                styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Native update notification proof"
            window.isReleasedWhenClosed = false
            let stack = NSStackView()
            stack.orientation = .vertical
            stack.spacing = 12
            stack.addArrangedSubview(NSTextField(labelWithString: "Synthetic versions; real macOS notifications"))
            for (title, action) in [
                ("Open update settings", #selector(self.openSettings)),
                ("Check next synthetic version", #selector(self.nextVersion)),
                ("Observe automatic check", #selector(self.automaticCheck)),
            ] {
                stack.addArrangedSubview(NSButton(title: title, target: self, action: action))
            }
            stack.frame = NSRect(x: 20, y: 20, width: 400, height: 170)
            window.contentView?.addSubview(stack)
            self.controlWindow = window
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            self.timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in await self?.snapshot() }
            }
            // Deliberately leave settings unconfigured briefly. Cold-launch notification clicks
            // must survive through the production pendingUpdateSettingsOpen path.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                let managed = ManagedCodexAccountCoordinator()
                let promotion = CodexAccountPromotionCoordinator(
                    settingsStore: self.settings, usageStore: self.store, managedAccountCoordinator: managed)
                self.production.configure(.init(
                    store: self.store,
                    settings: self.settings,
                    account: AccountInfo(email: nil, plan: nil),
                    selection: self.selection,
                    managedCodexAccountCoordinator: managed,
                    codexAccountPromotionCoordinator: promotion))
                HomebrewUpdateAppProof.record("production_settings_configured")
                // Provider/status-item startup is outside this isolated notification proof.
                await self.snapshot()
            }
        }

        func applicationWillTerminate(_ notification: Notification) {
            self.timer?.invalidate()
            UserDefaults.standard.synchronize()
            HomebrewUpdateAppProof.record("quit")
            self.production.applicationWillTerminate(notification)
        }

        private func installMenu() {
            let menu = NSMenu()
            let item = NSMenuItem()
            let actions = NSMenu()
            for (title, action, key) in [
                ("Open update settings", #selector(self.openSettings), "u"),
                ("Check next synthetic version", #selector(self.nextVersion), "n"),
                ("Observe automatic check", #selector(self.automaticCheck), "r"),
                ("Quit update proof", #selector(NSApplication.terminate(_:)), "q"),
            ] {
                let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
                entry.target = action == #selector(NSApplication.terminate(_:)) ? NSApp : self
                actions.addItem(entry)
            }
            item.submenu = actions
            menu.addItem(item)
            NSApp.mainMenu = menu
        }

        @objc private func openSettings() {
            self.production.openSettings(pane: .about)
        }

        @objc private func nextVersion() {
            let defaults = UserDefaults.standard
            let revision = defaults.integer(forKey: "proofVersionRevision") + 2
            defaults.set(revision - 1, forKey: "proofVersionRevision")
            defaults.set("99.0.\(revision)", forKey: "proofVersion")
            self.automaticCheck()
        }

        @objc private func automaticCheck() {
            Task { @MainActor in
                guard let updater = self.production.updaterController as? HomebrewUpdaterController else { return }
                let before = HomebrewUpdateAppProof.fetchCount
                await updater.performCheck(source: .automatic)
                HomebrewUpdateAppProof.record("automatic_check_requested", [
                    "fetches_before": before, "fetches_after": HomebrewUpdateAppProof.fetchCount,
                    "enabled": updater.automaticallyChecksForUpdates,
                ])
                await self.snapshot()
            }
        }

        private func snapshot() async {
            let center = UNUserNotificationCenter.current()
            let delivered = await center.deliveredNotifications()
            let pending = await center.pendingNotificationRequests()
            let authorization = await center.notificationSettings()
            let defaults = UserDefaults.standard
            let visible = NSApp.windows.contains {
                $0.identifier?.rawValue == SettingsWindowIdentity.identifier && $0.isVisible
            }
            let state: [String: Any] = [
                "authorization": authorization.authorizationStatus.rawValue,
                "delivered_ids": delivered.map(\.request.identifier).sorted(),
                "pending_ids": pending.map(\.identifier).sorted(),
                "saved_submitted_version": defaults.string(forKey: "homebrewUpdateLastSubmittedVersion") ?? "",
                "saved_auto_check": defaults.object(forKey: "autoUpdateEnabled") as? Bool ?? true,
                "controller_auto_check": self.production.updaterController.automaticallyChecksForUpdates,
                "fetch_count": HomebrewUpdateAppProof.fetchCount,
                "settings_visible": visible,
                "selected_pane": self.selection.pane.persistenceToken,
                "silent": delivered.allSatisfy { $0.request.content.sound == nil },
                "production_notification_delegate": center.delegate === AppNotifications.shared,
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]),
                  let value = String(data: data, encoding: .utf8), value != self.previousState else { return }
            self.previousState = value
            HomebrewUpdateAppProof.record("native_snapshot", state)
        }
    }

    private final class ProofDefaults: UserDefaults, @unchecked Sendable {
        private var values: [String: Any] = [
            "debugDisableKeychainAccess": true, "appLanguage": "en", "openAIWebAccessEnabled": false,
        ]
        override func object(forKey key: String) -> Any? { self.values[key] }
        override func set(_ value: Any?, forKey key: String) { self.values[key] = value }
        override func removeObject(forKey key: String) { self.values.removeValue(forKey: key) }
        override func dictionaryRepresentation() -> [String: Any] { self.values }
    }
}
#endif
