import Foundation
import Testing
@preconcurrency import UserNotifications
@testable import CodexBar

@MainActor
struct AppNotificationsTests {
    private final class Recorder: @unchecked Sendable {
        struct ShortcutRun: Equatable {
            let name: String
            let provider: String?
        }

        private let lock = NSLock()
        private var requests: [UNNotificationRequest] = []
        private var hooks: [URL] = []
        private var openedURLs: [URL] = []
        private var shortcuts: [ShortcutRun] = []
        private var sounds: [(sound: NotificationSoundOption, volume: Double)] = []
        private var deliveryEvents: [String] = []

        func record(request: UNNotificationRequest) {
            self.lock.withLock {
                self.requests.append(request)
                self.deliveryEvents.append("request")
            }
        }

        func record(hook: URL) {
            self.lock.withLock {
                self.hooks.append(hook)
                self.deliveryEvents.append("hook")
            }
        }

        func record(openedURL: URL) {
            self.lock.withLock {
                self.openedURLs.append(openedURL)
                self.deliveryEvents.append("openURL")
            }
        }

        func record(shortcut: String, provider: String?) {
            self.lock.withLock {
                self.shortcuts.append(ShortcutRun(name: shortcut, provider: provider))
                self.deliveryEvents.append("shortcut")
            }
        }

        func record(sound: NotificationSoundOption, volume: Double) {
            self.lock.withLock {
                self.sounds.append((sound: sound, volume: volume))
                self.deliveryEvents.append("sound")
            }
        }

        func requestCount() -> Int {
            self.lock.withLock {
                self.requests.count
            }
        }

        func hookURLs() -> [URL] {
            self.lock.withLock {
                self.hooks
            }
        }

        func openedURLsSnapshot() -> [URL] {
            self.lock.withLock {
                self.openedURLs
            }
        }

        func shortcutsSnapshot() -> [ShortcutRun] {
            self.lock.withLock {
                self.shortcuts
            }
        }

        func soundsSnapshot() -> [(sound: NotificationSoundOption, volume: Double)] {
            self.lock.withLock {
                self.sounds
            }
        }

        func deliveryEventsSnapshot() -> [String] {
            self.lock.withLock {
                self.deliveryEvents
            }
        }
    }

    @Test
    func `disabled notification skips all delivery paths`() async {
        let recorder = Recorder()
        let notifications = Self.makeNotifications(recorder: recorder, authorizationStatus: .authorized)

        await Self.post(
            notifications,
            event: .providerLogin,
            notificationsEnabled: true,
            notificationVolume: 0.8,
            settings: NotificationDeliverySettings(
                enabled: false,
                sound: .hero,
                hookCallURL: "https://example.com/hook",
                shortcutName: "Codex Login"))

        #expect(recorder.requestCount() == 0)
        #expect(recorder.hookURLs().isEmpty)
        #expect(recorder.openedURLsSnapshot().isEmpty)
        #expect(recorder.shortcutsSnapshot().isEmpty)
        #expect(recorder.soundsSnapshot().isEmpty)
    }

    @Test
    func `enabled notification delivers hook and shortcut command even when local notifications are denied`() async {
        let recorder = Recorder()
        let notifications = Self.makeNotifications(recorder: recorder, authorizationStatus: .denied)

        await Self.post(
            notifications,
            event: .providerLogin,
            notificationsEnabled: true,
            notificationVolume: 0.8,
            settings: NotificationDeliverySettings(
                enabled: true,
                sound: .hero,
                hookCallURL: "https://example.com/hook",
                shortcutName: "Provider Login"))

        #expect(recorder.requestCount() == 0)
        #expect(recorder.hookURLs().map(\.absoluteString) == ["https://example.com/hook"])
        #expect(recorder.openedURLsSnapshot().isEmpty)
        #expect(recorder.shortcutsSnapshot().map(\.name) == ["Provider Login"])
        #expect(recorder.soundsSnapshot().isEmpty)
    }

    @Test
    func `custom scheme hook uses url opener and still posts local notification`() async {
        let recorder = Recorder()
        let notifications = Self.makeNotifications(recorder: recorder, authorizationStatus: .authorized)

        await Self.post(
            notifications,
            event: .sessionQuotaDepleted,
            notificationsEnabled: true,
            notificationVolume: 0.35,
            settings: NotificationDeliverySettings(
                enabled: true,
                sound: .submarine,
                hookCallURL: "raycast://extensions/test/run",
                shortcutName: "Quota Alert"))

        #expect(recorder.requestCount() == 1)
        #expect(recorder.hookURLs().isEmpty)
        #expect(recorder.openedURLsSnapshot().map(\.absoluteString) == [
            "raycast://extensions/test/run",
        ])
        #expect(recorder.shortcutsSnapshot().map(\.name) == ["Quota Alert"])
        #expect(recorder.soundsSnapshot().count == 1)
        #expect(recorder.soundsSnapshot().first?.sound == .submarine)
        #expect(recorder.soundsSnapshot().first?.volume == 0.35)
    }

    @Test
    func `local notification posts before external actions`() async {
        let recorder = Recorder()
        let notifications = Self.makeNotifications(recorder: recorder, authorizationStatus: .authorized)

        await Self.post(
            notifications,
            event: .providerLogin,
            notificationsEnabled: true,
            notificationVolume: 0.8,
            settings: NotificationDeliverySettings(
                enabled: true,
                sound: .none,
                hookCallURL: "https://example.com/hook",
                shortcutName: "Provider Login"))

        #expect(recorder.deliveryEventsSnapshot() == ["request", "hook", "shortcut"])
    }

    @Test
    func `global notifications toggle disables all delivery paths`() async {
        let recorder = Recorder()
        let notifications = Self.makeNotifications(recorder: recorder, authorizationStatus: .authorized)

        await Self.post(
            notifications,
            event: .sessionQuotaRestored,
            notificationsEnabled: false,
            notificationVolume: 0.5,
            settings: NotificationDeliverySettings(
                enabled: true,
                sound: .glass,
                hookCallURL: "https://example.com/hook",
                shortcutName: "Quota Restored"))

        #expect(recorder.requestCount() == 0)
        #expect(recorder.hookURLs().isEmpty)
        #expect(recorder.openedURLsSnapshot().isEmpty)
        #expect(recorder.shortcutsSnapshot().isEmpty)
        #expect(recorder.soundsSnapshot().isEmpty)
    }

    @Test
    func `missing shortcuts app skips shortcut delivery quietly`() async {
        let recorder = Recorder()
        let notifications = Self.makeNotifications(
            recorder: recorder,
            authorizationStatus: .denied,
            shortcutAvailable: false)

        await Self.post(
            notifications,
            event: .providerLogin,
            notificationsEnabled: true,
            notificationVolume: 0.8,
            settings: NotificationDeliverySettings(
                enabled: true,
                sound: .hero,
                hookCallURL: "",
                shortcutName: "Provider Login"))

        #expect(recorder.requestCount() == 0)
        #expect(recorder.hookURLs().isEmpty)
        #expect(recorder.openedURLsSnapshot().isEmpty)
        #expect(recorder.shortcutsSnapshot().isEmpty)
        #expect(recorder.soundsSnapshot().isEmpty)
    }

    @Test
    func `missing shortcut is handled by command runner without opening Shortcuts UI`() async {
        let recorder = Recorder()
        let notifications = Self.makeNotifications(
            recorder: recorder,
            authorizationStatus: .denied,
            shortcutResult: .init(succeeded: false, output: "Could not find the shortcut."))

        await Self.post(
            notifications,
            event: .sessionQuotaDepleted,
            notificationsEnabled: true,
            notificationVolume: 0.8,
            settings: NotificationDeliverySettings(
                enabled: true,
                sound: .none,
                hookCallURL: "",
                shortcutName: "CodexBar Session Quota Depleted"))

        #expect(recorder.requestCount() == 0)
        #expect(recorder.openedURLsSnapshot().isEmpty)
        #expect(recorder.shortcutsSnapshot().map(\.name) == ["CodexBar Session Quota Depleted"])
        #expect(recorder.soundsSnapshot().isEmpty)
    }

    @Test
    func `hook URL expands provider placeholder`() async {
        let recorder = Recorder()
        let notifications = Self.makeNotifications(recorder: recorder, authorizationStatus: .denied)

        await Self.post(
            notifications,
            event: .sessionQuotaRestored,
            provider: "OpenCode Go",
            notificationsEnabled: true,
            notificationVolume: 0.8,
            settings: NotificationDeliverySettings(
                enabled: true,
                sound: .none,
                hookCallURL: "https://example.com/hooks/{provider}?provider={provider}",
                shortcutName: ""))

        #expect(recorder.requestCount() == 0)
        #expect(recorder.hookURLs().map(\.absoluteString) == [
            "https://example.com/hooks/OpenCode%20Go?provider=OpenCode%20Go",
        ])
        #expect(recorder.shortcutsSnapshot().isEmpty)
    }

    @Test
    func `shortcut runner receives provider value`() async {
        let recorder = Recorder()
        let notifications = Self.makeNotifications(recorder: recorder, authorizationStatus: .denied)

        await Self.post(
            notifications,
            event: .providerLogin,
            provider: "Codex",
            notificationsEnabled: true,
            notificationVolume: 0.8,
            settings: NotificationDeliverySettings(
                enabled: true,
                sound: .none,
                hookCallURL: "",
                shortcutName: "Provider Login"))

        #expect(recorder.requestCount() == 0)
        #expect(recorder.shortcutsSnapshot() == [
            Recorder.ShortcutRun(name: "Provider Login", provider: "Codex"),
        ])
    }

    private static func makeNotifications(
        recorder: Recorder,
        authorizationStatus: UNAuthorizationStatus,
        shortcutAvailable: Bool = true,
        shortcutResult: AppNotifications.ShortcutRunResult = .init(succeeded: true, output: ""))
        -> AppNotifications
    {
        AppNotifications(
            authorizationStatusProvider: { authorizationStatus },
            authorizationRequester: { authorizationStatus == .authorized || authorizationStatus == .provisional },
            requestPoster: { request in recorder.record(request: request) },
            hookCaller: { url in recorder.record(hook: url) },
            urlOpener: { url in
                recorder.record(openedURL: url)
                return true
            },
            shortcutAvailabilityChecker: { shortcutAvailable },
            shortcutRunner: { shortcut, provider in
                recorder.record(shortcut: shortcut, provider: provider)
                return shortcutResult
            },
            soundPlayer: { sound, volume in
                recorder.record(sound: sound, volume: volume)
                return true
            },
            allowsPostingWhenRunningUnderTests: true)
    }

    private static func post(
        _ notifications: AppNotifications,
        event: AppNotificationEvent,
        provider: String? = nil,
        notificationsEnabled: Bool,
        notificationVolume: Double,
        settings: NotificationDeliverySettings) async
    {
        let task = notifications.post(
            idPrefix: "test-\(event.rawValue)",
            title: event.settingsTitle,
            body: event.settingsSubtitle,
            event: event,
            provider: provider,
            notificationsEnabled: notificationsEnabled,
            notificationVolume: notificationVolume,
            settings: settings)
        if let task {
            await task.value
        }
    }
}
