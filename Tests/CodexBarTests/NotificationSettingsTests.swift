import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite(.serialized)
@MainActor
struct NotificationSettingsTests {
    @Test
    func `defaults session quota notifications to enabled`() throws {
        let key = "sessionQuotaNotificationsEnabled"
        let suite = "NotificationSettingsTests-session-quota-default"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)

        let store = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        #expect(store.sessionQuotaNotificationsEnabled == true)
        #expect(defaults.bool(forKey: key) == true)
        #expect(store.notificationSettings(for: .sessionQuotaDepleted).enabled == true)
        #expect(store.notificationSettings(for: .sessionQuotaRestored).enabled == true)
    }

    @Test
    func `defaults all notification settings to enabled with defaults`() throws {
        let suite = "NotificationSettingsTests-defaults"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)

        let store = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        for event in AppNotificationEvent.allCases {
            let settings = store.notificationSettings(for: event)
            #expect(settings.enabled == true)
            #expect(settings.sound == event.defaultSound)
            #expect(settings.hookCallURL.isEmpty)
            #expect(settings.shortcutName.isEmpty)
            #expect(defaults.object(forKey: event.enabledDefaultsKey) as? Bool == true)
            #expect(defaults.string(forKey: event.soundDefaultsKey) == event.defaultSound.rawValue)
        }
    }

    @Test
    func `defaults global notifications to enabled`() throws {
        let suite = "NotificationSettingsTests-global-default"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)

        let store = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        #expect(store.notificationsEnabled == true)
        #expect(defaults.object(forKey: "notificationsEnabled") as? Bool == true)
        #expect(store.notificationVolume == 1.0)
        #expect(defaults.object(forKey: "notificationVolume") as? Double == 1.0)
    }

    @Test
    func `persists provider login notification integrations across instances`() throws {
        let suite = "NotificationSettingsTests-provider-login"
        let defaultsA = try #require(UserDefaults(suiteName: suite))
        defaultsA.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        let storeA = SettingsStore(
            userDefaults: defaultsA,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        storeA.setNotificationSettings(
            NotificationDeliverySettings(
                enabled: false,
                sound: .ping,
                hookCallURL: " https://example.com/login-hook ",
                shortcutName: " Login Shortcut "),
            for: .providerLogin)

        let defaultsB = try #require(UserDefaults(suiteName: suite))
        let storeB = SettingsStore(
            userDefaults: defaultsB,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        #expect(storeB.notificationSettings(for: .providerLogin) == NotificationDeliverySettings(
            enabled: false,
            sound: .ping,
            hookCallURL: "https://example.com/login-hook",
            shortcutName: "Login Shortcut"))
    }

    @Test
    func `persists global notification volume across instances`() throws {
        let suite = "NotificationSettingsTests-global-volume"
        let defaultsA = try #require(UserDefaults(suiteName: suite))
        defaultsA.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        let storeA = SettingsStore(
            userDefaults: defaultsA,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        storeA.notificationVolume = 0.42

        let defaultsB = try #require(UserDefaults(suiteName: suite))
        let storeB = SettingsStore(
            userDefaults: defaultsB,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        #expect(storeB.notificationVolume == 0.42)
    }

    @Test
    func `session quota notification settings honor legacy enabled key`() throws {
        let suite = "NotificationSettingsTests-session-quota-legacy"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defaults.set(false, forKey: "sessionQuotaNotificationsEnabled")
        let configStore = testConfigStore(suiteName: suite)

        let store = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        #expect(store.notificationSettings(for: .sessionQuotaDepleted).enabled == false)
        #expect(store.notificationSettings(for: .sessionQuotaRestored).enabled == false)
        #expect(defaults.object(forKey: AppNotificationEvent.sessionQuotaDepleted.enabledDefaultsKey) as? Bool == false)
        #expect(defaults.object(forKey: AppNotificationEvent.sessionQuotaRestored.enabledDefaultsKey) as? Bool == false)
    }

    @Test
    func `session quota legacy flag stays true when one split event remains enabled`() throws {
        let suite = "NotificationSettingsTests-session-quota-split-legacy"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)

        let store = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        var depleted = store.notificationSettings(for: .sessionQuotaDepleted)
        depleted.enabled = false
        store.setNotificationSettings(depleted, for: .sessionQuotaDepleted)

        #expect(defaults.object(forKey: "sessionQuotaNotificationsEnabled") as? Bool == true)
        #expect(store.sessionQuotaNotificationsEnabled == true)
    }
}
