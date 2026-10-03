#if DEBUG
import AppKit
import CodexBarCore
import ServiceManagement
import SwiftUI
@preconcurrency import UserNotifications

/// Runs the shipped preferences and notification path without starting provider probes.
/// Launch the packaged debug app with --localization-proof -appLanguage <language>.
@MainActor
enum LocalizationNativeProof {
    static func runIfRequested() -> Bool {
        guard CommandLine.arguments.contains("--localization-proof") else { return false }
        KeychainAccessGate.isDisabled = true
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = Delegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
        return true
    }

    @MainActor
    private final class Delegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
        private var window: NSWindow?
        private var shortcutWindow: NSWindow?
        private var store: UsageStore?
        private let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-localization-runtime-proof", isDirectory: true)

        func applicationDidFinishLaunching(_ notification: Notification) {
            do {
                try FileManager.default.createDirectory(at: self.output, withIntermediateDirectories: true)
                // Keep configuration and legacy credential stores inside this fixture directory.
                let configStore = CodexBarConfigStore(fileURL: self.output.appendingPathComponent("config.json"))
                var config = CodexBarConfig.makeDefault()
                for index in config.providers.indices {
                    config.providers[index].enabled = false
                }
                try configStore.save(config)
                let defaults = InMemoryUserDefaults(values: [
                    "debugDisableKeychainAccess": true,
                    "launchAtLogin": false,
                    "codexbar.legacySecretsMigrationCompleted": true,
                ])
                let loginItemStatusBefore = SMAppService.mainApp.status
                let settings = SettingsStore(
                    userDefaults: defaults,
                    configStore: configStore,
                    tokenAccountStore: FileTokenAccountStore(
                        fileURL: self.output.appendingPathComponent("accounts.json")),
                    antigravityOAuthCredentialsStore: AntigravityOAuthCredentialsStore(
                        fileURL: self.output.appendingPathComponent("antigravity.json")),
                    startupBehavior: .isolated,
                    performInitialProviderDetection: false)
                settings.credentialExpiryNotificationsEnabled = true
                // Provider-specific by design: this fixture exercises Codex's localized credential alert.
                let provider = UsageProvider.codex
                settings.setProviderEnabled(
                    provider: provider,
                    metadata: ProviderDescriptorRegistry.descriptor(for: provider).metadata,
                    enabled: true)
                self.store = UsageStore(
                    fetcher: UsageFetcher(),
                    browserDetection: BrowserDetection(),
                    settings: settings,
                    startupBehavior: .testing)
                UNUserNotificationCenter.current().delegate = self
                let content = VStack(spacing: 0) {
                    NotificationsPane(settings: settings)
                    HStack {
                        Button("Send credential-expiry fixture") { self.sendNotification() }
                        Button("Show shortcut editor") { self.showShortcuts(settings) }
                        Button("Record delivered notification") { self.recordDelivery() }
                    }.padding()
                }
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 780, height: 660),
                    styleMask: [.titled, .closable, .resizable],
                    backing: .buffered,
                    defer: false)
                window.title = "CodexBar · \(L("section_alerts")) · isolated runtime proof"
                window.contentView = NSHostingView(rootView: content)
                window.center()
                window.makeKeyAndOrderFront(nil)
                self.window = window
                NSApplication.shared.activate(ignoringOtherApps: true)
                self.writeReceipt([
                    "event": "app-started",
                    "language": codexBarLocalizationSignature(),
                    "bundle": Bundle.main.bundleURL.path,
                    "settingsTitle": L("credential_expiry_notifications_title"),
                    "settingsSubtitle": L("credential_expiry_notifications_subtitle"),
                    "taskLocalOverride": String(CodexBarLocalizationOverride.appLanguage != nil),
                    "settingsStartupMode": "isolated",
                    "loginItemStatusBefore": String(loginItemStatusBefore.rawValue),
                    "loginItemStatusAfter": String(SMAppService.mainApp.status.rawValue),
                ], filename: "app-\(codexBarLocalizationSignature()).json")
            } catch {
                FileHandle.standardError.write(Data("localization-proof: \(error)\n".utf8))
                NSApplication.shared.terminate(nil)
            }
        }

        private func showShortcuts(_ settings: SettingsStore) {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 700, height: 580),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false)
            window.title = L("Provider Switcher Shortcuts")
            window.contentView = NSHostingView(rootView: ProviderSwitcherShortcutEditor(settings: settings))
            window.center()
            window.makeKeyAndOrderFront(nil)
            self.shortcutWindow = window
        }

        private func sendNotification() {
            // Provider-specific by design: the enabled synthetic Codex account matches the alert fixture.
            self.store?.handleCredentialOutcome(
                provider: .codex,
                account: "localization-proof-fixture",
                result: .failure(ProviderFetchClassifiedError(
                    kind: .authenticationExpired,
                    message: "Synthetic expired credential")))
        }

        private func recordDelivery() {
            Task { @MainActor in
                let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
                for notification in delivered where notification.request.identifier.hasPrefix("codexbar-credential-") {
                    self.writeReceipt([
                        "event": "macOS-delivered-credential-notification",
                        "language": codexBarLocalizationSignature(),
                        "title": notification.request.content.title,
                        "body": notification.request.content.body,
                        "bundle": Bundle.main.bundleURL.path,
                    ], filename: "notification-\(codexBarLocalizationSignature()).json")
                }
            }
        }

        private func writeReceipt(_ values: [String: String], filename: String) {
            do {
                let data = try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: self.output.appendingPathComponent(filename), options: .atomic)
                FileHandle.standardOutput.write(data + Data("\n".utf8))
            } catch {
                FileHandle.standardError.write(Data("localization-proof receipt: \(error)\n".utf8))
            }
        }

        nonisolated func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            willPresent notification: UNNotification,
            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void)
        {
            completionHandler([.banner, .list])
        }
    }
}
#endif
