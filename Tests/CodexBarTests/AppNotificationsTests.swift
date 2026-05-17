import Foundation
import Testing
@preconcurrency import UserNotifications
@testable import CodexBar

@MainActor
struct AppNotificationsTests {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [UNNotificationRequest] = []
        private var sounds: [(sound: NotificationSoundOption, volume: Double)] = []

        func record(request: UNNotificationRequest) {
            self.lock.withLock {
                self.requests.append(request)
            }
        }

        func record(sound: NotificationSoundOption, volume: Double) {
            self.lock.withLock {
                self.sounds.append((sound: sound, volume: volume))
            }
        }

        func requestCount() -> Int {
            self.lock.withLock {
                self.requests.count
            }
        }

        func soundsSnapshot() -> [(sound: NotificationSoundOption, volume: Double)] {
            self.lock.withLock {
                self.sounds
            }
        }
    }

    @Test
    func `disabled notification skips local delivery`() async {
        let recorder = Recorder()
        let notifications = Self.makeNotifications(recorder: recorder, authorizationStatus: .authorized)

        await Self.post(
            notifications,
            event: .providerLogin,
            notificationsEnabled: true,
            notificationVolume: 0.8,
            settings: NotificationDeliverySettings(
                enabled: false,
                sound: .hero))

        #expect(recorder.requestCount() == 0)
        #expect(recorder.soundsSnapshot().isEmpty)
    }

    @Test
    func `global notifications toggle disables local delivery`() async {
        let recorder = Recorder()
        let notifications = Self.makeNotifications(recorder: recorder, authorizationStatus: .authorized)

        await Self.post(
            notifications,
            event: .sessionQuotaRestored,
            notificationsEnabled: false,
            notificationVolume: 0.5,
            settings: NotificationDeliverySettings(
                enabled: true,
                sound: .glass))

        #expect(recorder.requestCount() == 0)
        #expect(recorder.soundsSnapshot().isEmpty)
    }

    @Test
    func `denied authorization skips local delivery`() async {
        let recorder = Recorder()
        let notifications = Self.makeNotifications(recorder: recorder, authorizationStatus: .denied)

        await Self.post(
            notifications,
            event: .providerLogin,
            notificationsEnabled: true,
            notificationVolume: 0.8,
            settings: NotificationDeliverySettings(
                enabled: true,
                sound: .hero))

        #expect(recorder.requestCount() == 0)
        #expect(recorder.soundsSnapshot().isEmpty)
    }

    @Test
    func `authorized notification posts request and custom sound`() async {
        let recorder = Recorder()
        let notifications = Self.makeNotifications(recorder: recorder, authorizationStatus: .authorized)

        await Self.post(
            notifications,
            event: .sessionQuotaDepleted,
            notificationsEnabled: true,
            notificationVolume: 0.35,
            settings: NotificationDeliverySettings(
                enabled: true,
                sound: .submarine))

        #expect(recorder.requestCount() == 1)
        #expect(recorder.soundsSnapshot().count == 1)
        #expect(recorder.soundsSnapshot().first?.sound == .submarine)
        #expect(recorder.soundsSnapshot().first?.volume == 0.35)
    }

    @Test
    func `system default sound does not use custom sound player`() async {
        let recorder = Recorder()
        let notifications = Self.makeNotifications(recorder: recorder, authorizationStatus: .authorized)

        await Self.post(
            notifications,
            event: .providerLogin,
            notificationsEnabled: true,
            notificationVolume: 0.8,
            settings: .localDefault)

        #expect(recorder.requestCount() == 1)
        #expect(recorder.soundsSnapshot().isEmpty)
    }

    private static func makeNotifications(
        recorder: Recorder,
        authorizationStatus: UNAuthorizationStatus)
        -> AppNotifications
    {
        AppNotifications(
            authorizationStatusProvider: { authorizationStatus },
            authorizationRequester: { authorizationStatus == .authorized || authorizationStatus == .provisional },
            requestPoster: { request in recorder.record(request: request) },
            soundPlayer: { sound, volume in
                recorder.record(sound: sound, volume: volume)
                return true
            },
            allowsPostingWhenRunningUnderTests: true)
    }

    private static func post(
        _ notifications: AppNotifications,
        event: AppNotificationEvent,
        notificationsEnabled: Bool,
        notificationVolume: Double,
        settings: NotificationDeliverySettings) async
    {
        let task = notifications.post(
            idPrefix: "test-\(event.rawValue)",
            title: event.rawValue,
            body: event.rawValue,
            event: event,
            notificationsEnabled: notificationsEnabled,
            notificationVolume: notificationVolume,
            settings: settings)
        await task?.value
    }
}
