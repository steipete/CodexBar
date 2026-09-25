import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct UnifiedIconSourceSettingsTests {
    private var keychainPolicy: SettingsStoreKeychainAccessPolicy {
        SettingsStoreKeychainAccessPolicy(setDisabled: { _ in }, isExplicitlyDisabled: { true })
    }

    @Test
    func `fresh settings default to current selection`() {
        let defaults = InMemoryUserDefaults()
        let settings = testSettingsStore(
            suiteName: "UnifiedIconSourceSettingsTests-fresh",
            userDefaults: defaults,
            keychainAccessPolicy: self.keychainPolicy)
        defer { settings.configFileWatcher?.stop() }

        #expect(settings.unifiedIconSource == .currentSelection)
        #expect(defaults.object(forKey: "unifiedIconSource") == nil)
    }

    @Test(arguments: [false, true])
    func `legacy highest usage choice migrates without altering menu selection`(highestUsage: Bool) {
        let defaults = InMemoryUserDefaults()
        defaults.set(highestUsage, forKey: "menuBarShowsHighestUsage")
        defaults.set(ProviderInstanceID.copilot.rawValue, forKey: "selectedMenuProvider")
        defaults.set(true, forKey: "mergedMenuLastSelectedWasOverview")
        let settings = testSettingsStore(
            suiteName: "UnifiedIconSourceSettingsTests-upgrade",
            userDefaults: defaults,
            keychainAccessPolicy: self.keychainPolicy)
        defer { settings.configFileWatcher?.stop() }

        #expect(settings.unifiedIconSource == (highestUsage ? .highestUsage : .currentSelection))
        #expect(defaults.object(forKey: "unifiedIconSource") == nil)
        #expect(settings.selectedMenuProvider == .copilot)
        #expect(settings.mergedMenuLastSelectedWasOverview)

        settings.addTokenAccount(provider: .copilot, label: "Selected", token: "test-token")
        let selectedAccountID = settings.selectedTokenAccount(for: .copilot)?.id
        #expect(selectedAccountID != nil)
        settings.unifiedIconSource = .frontmostApp
        #expect(defaults.string(forKey: "unifiedIconSource") == UnifiedIconSource.frontmostApp.rawValue)
        #expect(settings.selectedMenuProvider == .copilot)
        #expect(settings.mergedMenuLastSelectedWasOverview)
        #expect(settings.selectedTokenAccount(for: .copilot)?.id == selectedAccountID)
        #expect(!defaults.bool(forKey: "menuBarShowsHighestUsage"))
    }

    @Test
    func `new source wins over legacy preference on reload`() {
        let defaults = InMemoryUserDefaults()
        defaults.set(true, forKey: "menuBarShowsHighestUsage")
        defaults.set(UnifiedIconSource.frontmostApp.rawValue, forKey: "unifiedIconSource")
        let settings = testSettingsStore(
            suiteName: "UnifiedIconSourceSettingsTests-precedence",
            userDefaults: defaults,
            keychainAccessPolicy: self.keychainPolicy)
        defer { settings.configFileWatcher?.stop() }

        #expect(settings.unifiedIconSource == .frontmostApp)
    }

    @Test
    func `legacy synced preferences decode and retain their highest usage choice`() throws {
        let settings = testSettingsStore(
            suiteName: "UnifiedIconSourceSettingsTests-sync",
            userDefaults: InMemoryUserDefaults(),
            keychainAccessPolicy: self.keychainPolicy)
        defer { settings.configFileWatcher?.stop() }
        settings.selectedMenuProvider = .claude
        settings.mergedMenuLastSelectedWasOverview = true
        var preferences = settings.syncedPreferences
        preferences.menuBarShowsHighestUsage = true
        let payload = PreferencesSyncPayload(preferences: preferences)
        let encoded = try CanonicalSyncJSON.encode(payload)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var preferenceValues = try #require(object["preferences"] as? [String: Any])
        preferenceValues.removeValue(forKey: "unifiedIconSourceRaw")
        object["preferences"] = preferenceValues
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let legacy = try CanonicalSyncJSON.decode(PreferencesSyncPayload.self, from: legacyData)
        #expect(legacy.preferences.unifiedIconSourceRaw == nil)
        settings.applySyncedPreferences(legacy.preferences)
        #expect(settings.unifiedIconSource == .highestUsage)
        #expect(settings.selectedMenuProvider == .claude)
        #expect(settings.mergedMenuLastSelectedWasOverview)

        var current = settings.syncedPreferences
        current.unifiedIconSourceRaw = UnifiedIconSource.frontmostApp.rawValue
        current.menuBarShowsHighestUsage = true
        settings.applySyncedPreferences(current)
        #expect(settings.unifiedIconSource == .frontmostApp)
    }
}
