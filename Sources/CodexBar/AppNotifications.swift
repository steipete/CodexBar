import CodexBarCore
import Foundation
@preconcurrency import UserNotifications

@MainActor
final class AppNotifications {
    static let shared = AppNotifications()

    private let authorizationStatusProvider: @Sendable () async -> UNAuthorizationStatus?
    private let authorizationRequester: @Sendable () async -> Bool
    private let requestPoster: @Sendable (UNNotificationRequest) async throws -> Void
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
        soundPlayer: @escaping @MainActor @Sendable (NotificationSoundOption, Double) -> Bool = { sound, volume in
            NotificationSoundPlayer.play(sound, volume: volume)
        },
        allowsPostingWhenRunningUnderTests: Bool = false)
    {
        self.authorizationStatusProvider = authorizationStatusProvider
        self.authorizationRequester = authorizationRequester
        self.requestPoster = requestPoster
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
        soundEnabled: Bool = true,
        event: AppNotificationEvent? = nil,
        provider: String? = nil,
        notificationsEnabled: Bool = true,
        notificationVolume: Double = 1.0,
        settings: NotificationDeliverySettings? = nil) -> Task<Void, Never>?
    {
        guard self.canPostInCurrentEnvironment else { return nil }

        return Task { @MainActor in
            let deliverySettings = settings ?? .localDefault
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
            content.sound = soundEnabled && deliverySettings.sound == .systemDefault ? .default : nil
            content.badge = badge

            let request = UNNotificationRequest(
                identifier: "codexbar-\(idPrefix)-\(UUID().uuidString)",
                content: content,
                trigger: nil)

            self.logger.info(
                "posting",
                metadata: self.metadata(event: event, idPrefix: idPrefix, provider: provider))
            do {
                try await self.requestPoster(request)
                self.playSoundIfNeeded(
                    event: event,
                    idPrefix: idPrefix,
                    provider: provider,
                    settings: deliverySettings,
                    soundEnabled: soundEnabled,
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

    private func playSoundIfNeeded(
        event: AppNotificationEvent?,
        idPrefix: String,
        provider: String?,
        settings: NotificationDeliverySettings,
        soundEnabled: Bool,
        notificationVolume: Double)
    {
        guard soundEnabled else { return }
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

    private nonisolated static func normalizedProvider(_ provider: String?) -> String? {
        let trimmed = provider?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
