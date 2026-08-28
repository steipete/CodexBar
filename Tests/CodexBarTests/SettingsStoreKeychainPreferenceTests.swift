import Foundation
import Testing
@testable import CodexBar

@MainActor
struct SettingsStoreKeychainPreferenceTests {
    @Test(arguments: [nil, false, true] as [Bool?], [nil, false, true] as [Bool?])
    func `local keychain preference wins and shared defaults fill only an absent value`(
        localValue: Bool?, sharedValue: Bool?) throws
    {
        let localSuite = "SettingsStoreKeychainPreferenceTests-local-\(UUID().uuidString)"
        let sharedSuite = "SettingsStoreKeychainPreferenceTests-shared-\(UUID().uuidString)"
        let local = try #require(UserDefaults(suiteName: localSuite))
        let shared = try #require(UserDefaults(suiteName: sharedSuite))
        defer {
            local.removePersistentDomain(forName: localSuite)
            shared.removePersistentDomain(forName: sharedSuite)
        }
        if let localValue {
            local.set(localValue, forKey: "debugDisableKeychainAccess")
        }
        if let sharedValue {
            shared.set(sharedValue, forKey: "debugDisableKeychainAccess")
        }

        let disabled = SettingsStore.loadDebugDisableKeychainAccess(userDefaults: local, sharedDefaults: shared)

        #expect(disabled == (localValue ?? sharedValue ?? false))
        #expect(shared.object(forKey: "debugDisableKeychainAccess") as? Bool == sharedValue)
    }
}
