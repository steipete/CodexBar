import AppKit
import CodexBarCore
import Foundation
@preconcurrency import UserNotifications

@MainActor
final class AppNotifications {
    struct ShortcutRunResult: Sendable {
        let succeeded: Bool
        let output: String
    }

    static let shared = AppNotifications()

    private let authorizationStatusProvider: @Sendable () async -> UNAuthorizationStatus?
    private let authorizationRequester: @Sendable () async -> Bool
    private let requestPoster: @Sendable (UNNotificationRequest) async throws -> Void
    private let hookCaller: @Sendable (URL) async throws -> Void
    private let urlOpener: @MainActor @Sendable (URL) -> Bool
    private let shortcutAvailabilityChecker: @Sendable () -> Bool
    private let shortcutRunner: @Sendable (String, String?) async -> ShortcutRunResult
    private let soundPlayer: @MainActor @Sendable (NotificationSoundOption, Double) -> Bool
    private let allowsPostingWhenRunningUnderTests: Bool
    private let logger = CodexBarLog.logger(LogCategories.notifications)
    private var authorizationTask: Task<Bool, Never>?

    init(
        authorizationStatusProvider: @escaping @Sendable () async -> UNAuthorizationStatus? = {
            let center = UNUserNotificationCenter.current()
            return await withCheckedContinuation { continuation in
                center.getNotificationSettings { settings in
                    continuation.resume(returning: settings.authorizationStatus)
                }
            }
        },
        authorizationRequester: @escaping @Sendable () async -> Bool = {
            let center = UNUserNotificationCenter.current()
            return await withCheckedContinuation { continuation in
                center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                    continuation.resume(returning: granted)
                }
            }
        },
        requestPoster: @escaping @Sendable (UNNotificationRequest) async throws -> Void = { request in
            try await UNUserNotificationCenter.current().add(request)
        },
        hookCaller: @escaping @Sendable (URL) async throws -> Void = { url in
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            let (_, response) = try await URLSession.shared.data(for: request, delegate: nil)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                struct HookCallError: Error, LocalizedError {
                    let statusCode: Int

                    var errorDescription: String? {
                        "HTTP \(self.statusCode)"
                    }
                }
                throw HookCallError(statusCode: http.statusCode)
            }
        },
        urlOpener: @escaping @MainActor @Sendable (URL) -> Bool = { url in
            NSWorkspace.shared.open(url)
        },
        shortcutAvailabilityChecker: @escaping @Sendable () -> Bool = {
            FileManager.default.isExecutableFile(atPath: "/usr/bin/shortcuts")
        },
        shortcutRunner: @escaping @Sendable (String, String?) async -> ShortcutRunResult = { name, provider in
            await AppNotifications.runShortcutCommand(name: name, provider: provider)
        },
        soundPlayer: @escaping @MainActor @Sendable (NotificationSoundOption, Double) -> Bool = { sound, volume in
            NotificationSoundPlayer.play(sound, volume: volume)
        },
        allowsPostingWhenRunningUnderTests: Bool = false)
    {
        self.authorizationStatusProvider = authorizationStatusProvider
        self.authorizationRequester = authorizationRequester
        self.requestPoster = requestPoster
        self.hookCaller = hookCaller
        self.urlOpener = urlOpener
        self.shortcutAvailabilityChecker = shortcutAvailabilityChecker
        self.shortcutRunner = shortcutRunner
        self.soundPlayer = soundPlayer
        self.allowsPostingWhenRunningUnderTests = allowsPostingWhenRunningUnderTests
    }

    func requestAuthorizationOnStartup(notificationsEnabled: Bool = true) {
        guard notificationsEnabled, self.canPostInCurrentEnvironment else { return }
        _ = self.ensureAuthorizationTask()
    }

    @discardableResult
    func post(
        idPrefix: String,
        title: String,
        body: String,
        badge: NSNumber? = nil,
        event: AppNotificationEvent? = nil,
        provider: String? = nil,
        notificationsEnabled: Bool = true,
        notificationVolume: Double = 1.0,
        settings: NotificationDeliverySettings? = nil) -> Task<Void, Never>?
    {
        guard self.canPostInCurrentEnvironment else { return nil }

        return Task { @MainActor in
            let deliverySettings = settings ?? .localDefault
            await self.deliverExternalActions(
                event: event,
                idPrefix: idPrefix,
                provider: provider,
                notificationsEnabled: notificationsEnabled,
                settings: deliverySettings)
            guard notificationsEnabled, deliverySettings.enabled else {
                self.logger.debug(
                    "disabled; skipping notification",
                    metadata: self.metadata(event: event, idPrefix: idPrefix, provider: provider))
                return
            }

            let granted = await self.ensureAuthorized()
            guard granted else {
                self.logger.debug(
                    "not authorized; skipping notification",
                    metadata: self.metadata(event: event, idPrefix: idPrefix, provider: provider))
                return
            }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = deliverySettings.sound == .systemDefault ? .default : nil
            content.badge = badge

            let request = UNNotificationRequest(
                identifier: "codexbar-\(idPrefix)-\(UUID().uuidString)",
                content: content,
                trigger: nil)

            self.logger.info("posting", metadata: self.metadata(event: event, idPrefix: idPrefix, provider: provider))
            do {
                try await self.requestPoster(request)
                self.playSoundIfNeeded(
                    event: event,
                    idPrefix: idPrefix,
                    provider: provider,
                    settings: deliverySettings,
                    notificationVolume: notificationVolume)
            } catch {
                var metadata = self.metadata(event: event, idPrefix: idPrefix, provider: provider)
                metadata["error"] = "\(error)"
                self.logger.error("failed to post", metadata: metadata)
            }
        }
    }

    // MARK: - Private

    private func ensureAuthorizationTask() -> Task<Bool, Never> {
        if let authorizationTask { return authorizationTask }
        let task = Task { @MainActor in
            await self.requestAuthorization()
        }
        self.authorizationTask = task
        return task
    }

    private func ensureAuthorized() async -> Bool {
        await self.ensureAuthorizationTask().value
    }

    private func requestAuthorization() async -> Bool {
        if let existing = await self.authorizationStatusProvider() {
            if existing == .authorized || existing == .provisional {
                return true
            }
            if existing == .denied {
                return false
            }
        }

        return await self.authorizationRequester()
    }

    private var canPostInCurrentEnvironment: Bool {
        self.allowsPostingWhenRunningUnderTests || !Self.isRunningUnderTests
    }

    private func deliverExternalActions(
        event: AppNotificationEvent?,
        idPrefix: String,
        provider: String?,
        notificationsEnabled: Bool,
        settings: NotificationDeliverySettings) async
    {
        let normalized = settings.normalized
        guard notificationsEnabled, normalized.enabled else { return }

        if !normalized.hookCallURL.isEmpty {
            await self.deliverHookCall(
                event: event,
                idPrefix: idPrefix,
                provider: provider,
                hookCallURL: normalized.hookCallURL)
        }
        if !normalized.shortcutName.isEmpty {
            await self.runShortcut(event: event, idPrefix: idPrefix, provider: provider, name: normalized.shortcutName)
        }
    }

    private func deliverHookCall(
        event: AppNotificationEvent?,
        idPrefix: String,
        provider: String?,
        hookCallURL: String) async
    {
        let renderedURL = Self.renderProviderPlaceholder(in: hookCallURL, provider: provider)
        guard let url = URL(string: renderedURL) else {
            var metadata = self.metadata(event: event, idPrefix: idPrefix, provider: provider)
            metadata["url"] = renderedURL
            self.logger.error("invalid hook url", metadata: metadata)
            return
        }

        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "http" || scheme == "https" {
            do {
                try await self.hookCaller(url)
                var metadata = self.metadata(event: event, idPrefix: idPrefix, provider: provider)
                metadata["url"] = renderedURL
                self.logger.info("hook delivered", metadata: metadata)
            } catch {
                var metadata = self.metadata(event: event, idPrefix: idPrefix, provider: provider)
                metadata["url"] = renderedURL
                metadata["error"] = "\(error)"
                self.logger.error("hook delivery failed", metadata: metadata)
            }
            return
        }

        _ = self.urlOpener(url)
        var metadata = self.metadata(event: event, idPrefix: idPrefix, provider: provider)
        metadata["url"] = renderedURL
        self.logger.info("custom scheme hook opened", metadata: metadata)
    }

    private func runShortcut(event: AppNotificationEvent?, idPrefix: String, provider: String?, name: String) async {
        guard self.shortcutAvailabilityChecker() else {
            var metadata = self.metadata(event: event, idPrefix: idPrefix, provider: provider)
            metadata["shortcut"] = name
            self.logger.debug("shortcuts command unavailable; skipping", metadata: metadata)
            return
        }

        let result = await self.shortcutRunner(name, Self.normalizedProvider(provider))
        var metadata = self.metadata(event: event, idPrefix: idPrefix, provider: provider)
        metadata["shortcut"] = name
        if result.succeeded {
            self.logger.info("shortcut ran", metadata: metadata)
        } else {
            metadata["output"] = result.output
            self.logger.debug("shortcut run failed; skipping", metadata: metadata)
        }
    }

    private func playSoundIfNeeded(
        event: AppNotificationEvent?,
        idPrefix: String,
        provider: String?,
        settings: NotificationDeliverySettings,
        notificationVolume: Double)
    {
        guard settings.sound != .none, settings.sound != .systemDefault else { return }
        var metadata = self.metadata(event: event, idPrefix: idPrefix, provider: provider)
        metadata["sound"] = settings.sound.rawValue
        metadata["volume"] = "\(notificationVolume)"

        if self.soundPlayer(settings.sound, notificationVolume) {
            self.logger.info("played sound", metadata: metadata)
        } else {
            self.logger.error("failed to play sound", metadata: metadata)
        }
    }

    private func metadata(event: AppNotificationEvent?, idPrefix: String, provider: String?) -> [String: String] {
        var metadata = [
            "event": event?.rawValue ?? "legacy",
            "prefix": idPrefix,
        ]
        if let provider = Self.normalizedProvider(provider) {
            metadata["provider"] = provider
        }
        return metadata
    }

    private static var isRunningUnderTests: Bool {
        // Swift Testing doesn't always set XCTest env vars, and removing XCTest imports from
        // the test target can make NSClassFromString("XCTestCase") return nil. If we're not
        // running inside an app bundle, treat it as "tests/headless" to avoid crashes when
        // accessing UNUserNotificationCenter.
        if Bundle.main.bundleURL.pathExtension != "app" { return true }
        let env = ProcessInfo.processInfo.environment
        if env["XCTestConfigurationFilePath"] != nil { return true }
        if env["TESTING_LIBRARY_VERSION"] != nil { return true }
        if env["SWIFT_TESTING"] != nil { return true }
        return NSClassFromString("XCTestCase") != nil
    }

    private nonisolated static func renderProviderPlaceholder(in template: String, provider: String?) -> String {
        guard let provider = self.normalizedProvider(provider) else { return template }
        return template.replacingOccurrences(of: "{provider}", with: self.urlEncodedProvider(provider))
    }

    private nonisolated static func normalizedProvider(_ provider: String?) -> String? {
        let trimmed = provider?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private nonisolated static func urlEncodedProvider(_ provider: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return provider.addingPercentEncoding(withAllowedCharacters: allowed) ?? provider
    }

    private nonisolated static func runShortcutCommand(name: String, provider: String?) async -> ShortcutRunResult {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            let inputURL: URL?
            if let provider = self.normalizedProvider(provider) {
                do {
                    let payload = ["provider": provider]
                    let data = try JSONSerialization.data(withJSONObject: payload, options: [])
                    let url = FileManager.default.temporaryDirectory
                        .appendingPathComponent("codexbar-shortcut-\(UUID().uuidString)")
                        .appendingPathExtension("json")
                    try data.write(to: url, options: .atomic)
                    inputURL = url
                    process.arguments = ["run", name, "--input-path", url.path]
                } catch {
                    return ShortcutRunResult(
                        succeeded: false,
                        output: "Failed to prepare shortcut input: \(error)")
                }
            } else {
                inputURL = nil
                process.arguments = ["run", name]
            }
            defer {
                if let inputURL {
                    try? FileManager.default.removeItem(at: inputURL)
                }
            }

            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                return ShortcutRunResult(succeeded: false, output: "\(error)")
            }

            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: outputData + errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            return ShortcutRunResult(succeeded: process.terminationStatus == 0, output: output)
        }.value
    }
}
