import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct SettingsPersistenceContractTests {
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

@MainActor
struct ProviderStorageScanUpgradeTests {
    @Test
    func `fresh install keeps storage scanning off`() {
        let defaults = InMemoryUserDefaults(values: [:])
        let settings = testSettingsStore(suiteName: #function, userDefaults: defaults)
        #expect(!settings.providerStorageScanEnabled)
        #expect(!settings.providerStorageFootprintsEnabled)
        #expect(defaults.object(forKey: "providerStorageScanEnabled") as? Bool == false)
    }

    @Test
    func `upgraded install that never opted in keeps scanning off`() {
        let defaults = InMemoryUserDefaults(values: ["providerDetectionCompleted": true])
        let settings = testSettingsStore(suiteName: #function, userDefaults: defaults)
        #expect(!settings.providerStorageScanEnabled)
        #expect(defaults.object(forKey: "providerStorageScanEnabled") as? Bool == false)
    }

    @Test
    func `upgraded install that opted in keeps scanning and the menu row`() {
        let defaults = InMemoryUserDefaults(values: [
            "providerDetectionCompleted": true,
            "providerStorageFootprintsEnabled": true,
        ])
        let settings = testSettingsStore(suiteName: #function, userDefaults: defaults)
        #expect(settings.providerStorageScanEnabled)
        #expect(settings.providerStorageFootprintsEnabled)
    }

    @Test
    func `stored scan choice wins over the upgrade fallback`() {
        let defaults = InMemoryUserDefaults(values: [
            "providerDetectionCompleted": true,
            "providerStorageScanEnabled": true,
        ])
        let settings = testSettingsStore(suiteName: #function, userDefaults: defaults)
        #expect(settings.providerStorageScanEnabled)
    }
}
