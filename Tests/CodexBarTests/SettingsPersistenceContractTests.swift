import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct SettingsPersistenceContractTests {
    @Test
    func `Codex reset credit reminders default off persist and round trip through portable preferences`() throws {
        let defaults = InMemoryUserDefaults()
        let settings = testSettingsStore(suiteName: #function, userDefaults: defaults)
        #expect(!settings.codexResetCreditExpiryNotificationsEnabled)
        #expect(defaults.object(forKey: "codexResetCreditExpiryNotificationsEnabled") == nil)
        defaults.set(true, forKey: "providerDetectionCompleted")
        #expect(!testSettingsStore(suiteName: #function, userDefaults: defaults)
            .codexResetCreditExpiryNotificationsEnabled)
        settings.codexResetCreditExpiryNotificationsEnabled = true
        let reloaded = testSettingsStore(suiteName: #function, userDefaults: defaults)
        #expect(reloaded.codexResetCreditExpiryNotificationsEnabled)
        let target = testSettingsStore(suiteName: #function, userDefaults: InMemoryUserDefaults())
        try target.importPreferences(settings.exportPreferences())
        #expect(target.codexResetCreditExpiryNotificationsEnabled)
        settings.codexResetCreditExpiryNotificationsEnabled = false
        #expect(!testSettingsStore(suiteName: #function, userDefaults: defaults)
            .codexResetCreditExpiryNotificationsEnabled)
        try target.importPreferences(settings.exportPreferences())
        #expect(!target.codexResetCreditExpiryNotificationsEnabled)
    }

    @Test(arguments: [true, false])
    func `Codex countdown opt in preserves the legacy summary choice and receipts`(legacyEnabled: Bool) {
        let receipts = [String(repeating: "a", count: 64)]
        let defaults = InMemoryUserDefaults(values: [
            "providerDetectionCompleted": true,
            "showOptionalCreditsAndExtraUsage": legacyEnabled,
            "codexResetCreditExpirySummaryFingerprints": receipts,
        ])
        let settings = testSettingsStore(suiteName: #function, userDefaults: defaults)
        #expect(!settings.codexResetCreditExpiryNotificationsEnabled)
        #expect(defaults.object(forKey: "codexResetCreditExpiryNotificationsEnabled") == nil)
        #expect(settings.showOptionalCreditsAndExtraUsage == legacyEnabled)
        #expect(defaults.stringArray(forKey: "codexResetCreditExpirySummaryFingerprints") == receipts)
        settings.codexResetCreditExpiryNotificationsEnabled = false
        #expect(!testSettingsStore(suiteName: #function, userDefaults: defaults)
            .codexResetCreditExpiryNotificationsEnabled)
    }

    @Test
    func `existing config retains summary visibility without enabling countdowns`() {
        let defaults = InMemoryUserDefaults()
        let settings = testSettingsStore(
            suiteName: #function,
            userDefaults: defaults,
            config: CodexBarConfig.makeDefault())
        #expect(settings.showOptionalCreditsAndExtraUsage)
        #expect(!settings.codexResetCreditExpiryNotificationsEnabled)
        #expect(defaults.object(forKey: "codexResetCreditExpiryNotificationsEnabled") == nil)
    }

    @Test
    func `older clients sorting changes remain authoritative on restart`() {
        let defaults = InMemoryUserDefaults()
        defaults.set("custom", forKey: "providerListSortMode")
        defaults.set(true, forKey: "providersSortedAlphabetically")
        #expect(testSettingsStore(suiteName: #function, userDefaults: defaults).providersSortedAlphabetically)
        defaults.set("alphabetical", forKey: "providerListSortMode")
        defaults.set(false, forKey: "providersSortedAlphabetically")
        #expect(!testSettingsStore(suiteName: #function, userDefaults: defaults).providersSortedAlphabetically)
    }

    @Test
    func `portable export preserves older clients sorting changes`() throws {
        for (raw, alphabetical) in [("custom", true), ("alphabetical", false)] {
            let defaults = InMemoryUserDefaults()
            defaults.set(raw, forKey: "providerListSortMode")
            defaults.set(alphabetical, forKey: "providersSortedAlphabetically")
            let exported = try PreferencesDocument(data: PreferencesDocument(defaults: defaults).encoded())
            #expect(try exported.value("providersSortedAlphabetically", as: Bool.self) == alphabetical)
            #expect(try exported.value("providerListSortMode", as: String.self) == nil)
        }
    }

    @Test
    func `menu hover highlighting defaults on and persists both choices`() {
        let defaults = InMemoryUserDefaults()
        let settings = testSettingsStore(suiteName: #function, userDefaults: defaults)
        #expect(settings.highlightMenuCardsOnHover)
        settings.highlightMenuCardsOnHover = false
        let reloaded = testSettingsStore(suiteName: #function, userDefaults: defaults)
        #expect(!reloaded.highlightMenuCardsOnHover)
        reloaded.highlightMenuCardsOnHover = true
        #expect(testSettingsStore(suiteName: #function, userDefaults: defaults).highlightMenuCardsOnHover)
    }

    @Test
    func `optional and raw preferences round trip without boxed nil values`() {
        let defaults = InMemoryUserDefaults()
        let settings = testSettingsStore(suiteName: #function, userDefaults: defaults)
        settings.weeklyProgressWorkDays = 4
        settings.mergeIconStackedTopProviderRaw = "claude"
        settings.menuBarDisplayMode = .pace
        settings.iCloudSyncDeviceID = "synthetic-device"
        settings.iCloudSyncSnapshotsEnabled = false

        let reloaded = testSettingsStore(suiteName: #function, userDefaults: defaults)
        #expect(reloaded.weeklyProgressWorkDays == 4)
        #expect(reloaded.mergeIconStackedTopProviderRaw == "claude")
        #expect(reloaded.menuBarDisplayMode == .pace)
        #expect(reloaded.iCloudSyncDeviceID == "synthetic-device")
        #expect(!reloaded.iCloudSyncSnapshotsEnabled)
        #expect(defaults.string(forKey: "menuBarDisplayMode") == MenuBarDisplayMode.pace.rawValue)
        #expect(defaults.object(forKey: "menuBarDisplayModeRaw") == nil)

        reloaded.weeklyProgressWorkDays = nil
        reloaded.mergeIconStackedTopProviderRaw = nil
        #expect(defaults.object(forKey: "weeklyProgressWorkDays") == nil)
        #expect(defaults.object(forKey: "mergeIconStackedTopProvider") == nil)
        let cleared = testSettingsStore(suiteName: #function, userDefaults: defaults)
        #expect(cleared.weeklyProgressWorkDays == nil)
        #expect(cleared.mergeIconStackedTopProviderRaw == nil)
    }

    @Test
    func `normalized cost assignments preserve revision and persistence semantics`() {
        let defaults = InMemoryUserDefaults()
        let settings = testSettingsStore(suiteName: #function, userDefaults: defaults)
        let revision = settings.costUsageSettingsRevision
        settings.costUsageBucketTimeZoneIdentifier = " UTC "
        #expect(settings.costUsageSettingsRevision == revision + 1)
        #expect(defaults.string(forKey: "tokenCostUsageBucketTimeZone") == "UTC")
        settings.costUsageBucketTimeZoneIdentifier = "UTC"
        #expect(settings.costUsageSettingsRevision == revision + 1)
        settings.spendDashboardHiddenSourceIDs = ["b", "", "a", "b"]
        #expect(settings.spendDashboardHiddenSourceIDs == ["a", "b"])
        #expect(settings.costUsageSettingsRevision == revision + 2)
        settings.spendDashboardHiddenSourceIDs = ["b", "a"]
        #expect(settings.costUsageSettingsRevision == revision + 2)

        settings.hideNativeCodexCostWhenOpenCodexPresent = true
        #expect(settings.costUsageSettingsRevision == revision + 3)
        defaults.removeObject(forKey: "hideNativeCodexCostWhenOpenCodexPresent")
        settings.hideNativeCodexCostWhenOpenCodexPresent = true
        #expect(settings.costUsageSettingsRevision == revision + 3)
        #expect(defaults.bool(forKey: "hideNativeCodexCostWhenOpenCodexPresent"))

        let backgroundRevision = settings.backgroundWorkSettingsRevision
        settings.statusChecksEnabled = settings.statusChecksEnabled
        #expect(settings.backgroundWorkSettingsRevision == backgroundRevision + 1)
        settings.predictivePaceWarningNotificationsEnabled = settings.predictivePaceWarningNotificationsEnabled
        #expect(settings.backgroundWorkSettingsRevision == backgroundRevision + 1)
    }

    @Test
    func `default loading preserves false values and repairs malformed test defaults`() {
        let defaults = InMemoryUserDefaults(values: [
            "quotaWarningMarkersVisible": false,
            "paceVisible": "invalid",
            "providerStorageFootprintsEnabled": "invalid",
            "quotaWarningSessionEnabled": false,
            "quotaWarningWeeklyEnabled": "invalid",
            "quotaWarningOnScreenAlertEnabled": true,
        ])
        let settings = testSettingsStore(suiteName: #function, userDefaults: defaults)
        #expect(!settings.quotaWarningMarkersVisible)
        #expect(settings.paceVisible)
        #expect(!settings.providerStorageFootprintsEnabled)
        #expect(!settings.quotaWarningWindowEnabled(.session))
        #expect(settings.quotaWarningWindowEnabled(.weekly))
        #expect(settings.quotaWarningOnScreenAlertEnabled)
        #expect(defaults.object(forKey: "paceVisible") as? Bool == true)
        #expect(defaults.object(forKey: "providerStorageFootprintsEnabled") as? Bool == false)
        #expect(defaults.object(forKey: "quotaWarningWeeklyEnabled") as? Bool == true)
    }
}
