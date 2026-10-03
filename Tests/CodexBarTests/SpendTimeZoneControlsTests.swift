import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct SpendTimeZoneControlsTests {
    @Test
    func `opening controls preserves the pinned zone and includes stored aliases`() {
        let defaults = InMemoryUserDefaults(values: [
            "tokenCostUsageEnabled": true,
            "tokenCostUsageBucketTimeZone": "US/Eastern",
        ])
        let settings = testSettingsStore(suiteName: #function, userDefaults: defaults)
        let controls = SpendTimeZoneControls(settings: settings)
        let revision = settings.costUsageSettingsRevision

        #expect(controls.selectedIdentifier == "US/Eastern")
        #expect(controls.timeZoneIdentifiers.contains("US/Eastern"))
        #expect(controls.timeZoneIdentifiers.contains("Asia/Shanghai"))
        #expect(controls.timeZoneIdentifiers.contains("America/Detroit"))
        #expect(controls.timeZoneIdentifiers.contains("UTC"))
        #expect(Set(controls.timeZoneIdentifiers).count == controls.timeZoneIdentifiers.count)
        #expect(settings.costUsageSettingsRevision == revision)
        #expect(defaults.string(forKey: "tokenCostUsageBucketTimeZone") == "US/Eastern")
    }

    @Test
    func `picker changes persist and update the reporting day without a restart`() throws {
        let defaults = InMemoryUserDefaults(values: [
            "tokenCostUsageEnabled": true,
            "tokenCostUsageBucketTimeZone": "Asia/Shanghai",
        ])
        let settings = testSettingsStore(suiteName: #function, userDefaults: defaults)
        let controls = SpendTimeZoneControls(settings: settings)
        let revision = settings.costUsageSettingsRevision
        let instant = try #require(ISO8601DateFormatter().date(from: "2026-10-01T17:00:00Z"))
        #expect(CostUsageScanner.CostUsageDayRange.dayKey(
            from: instant,
            calendar: settings.costUsageBucketCalendar) == "2026-10-02")

        controls.timeZoneBinding.wrappedValue = "America/Detroit"
        #expect(settings.costUsageSettingsRevision == revision + 1)
        #expect(CostUsageScanner.CostUsageDayRange.dayKey(
            from: instant,
            calendar: settings.costUsageBucketCalendar) == "2026-10-01")
        let reloaded = testSettingsStore(suiteName: #function, userDefaults: defaults)
        #expect(reloaded.costUsageBucketTimeZoneIdentifier == "America/Detroit")
        controls.timeZoneBinding.wrappedValue = "America/Detroit"
        #expect(settings.costUsageSettingsRevision == revision + 1)
    }

    @Test(arguments: ["UTC", "GMT+8"])
    func `picker preserves saved labels that Foundation normalizes`(identifier: String) {
        let defaults = InMemoryUserDefaults(values: ["tokenCostUsageBucketTimeZone": identifier])
        let settings = testSettingsStore(suiteName: #function, userDefaults: defaults)
        let controls = SpendTimeZoneControls(settings: settings)
        #expect(controls.selectedIdentifier == identifier)
        #expect(controls.timeZoneIdentifiers.contains(identifier))

        controls.timeZoneBinding.wrappedValue = "Asia/Shanghai"
        controls.timeZoneBinding.wrappedValue = identifier
        #expect(controls.selectedIdentifier == identifier)
        #expect(defaults.string(forKey: "tokenCostUsageBucketTimeZone") == identifier)
    }

    @Test
    func `current zone button pins the selected zone and retains daylight saving rules`() throws {
        let defaults = InMemoryUserDefaults(values: [
            "tokenCostUsageEnabled": false,
            "tokenCostUsageBucketTimeZone": "Asia/Shanghai",
        ])
        let settings = testSettingsStore(suiteName: #function, userDefaults: defaults)
        let controls = SpendTimeZoneControls(settings: settings)
        let zone = try #require(TimeZone(identifier: "America/Detroit"))
        controls.useCurrentTimeZone(zone)

        #expect(defaults.string(forKey: "tokenCostUsageBucketTimeZone") == "America/Detroit")
        let winter = try #require(ISO8601DateFormatter().date(from: "2026-01-01T12:00:00Z"))
        let summer = try #require(ISO8601DateFormatter().date(from: "2026-07-01T12:00:00Z"))
        #expect(settings.costUsageBucketCalendar.timeZone.secondsFromGMT(for: winter) == -5 * 3600)
        #expect(settings.costUsageBucketCalendar.timeZone.secondsFromGMT(for: summer) == -4 * 3600)
        #expect(!settings.costUsageEnabled)
    }
}
