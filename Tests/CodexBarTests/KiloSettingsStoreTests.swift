import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct KiloSettingsStoreTests {
    private func makeSettings() throws -> SettingsStore {
        let suite = "KiloSettingsStoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
    }

    @Test
    func `defaults to empty known organizations and empty enabled ids`() throws {
        let settings = try self.makeSettings()
        #expect(settings.kiloKnownOrganizations.isEmpty)
        #expect(settings.kiloEnabledOrganizationIDs.isEmpty)
    }

    @Test
    func `setting known organizations persists them`() throws {
        let settings = try self.makeSettings()
        let orgs = [
            KiloOrganization(id: "org_1", name: "Alpha", role: "owner"),
            KiloOrganization(id: "org_2", name: "Beta", role: "member"),
        ]
        settings.kiloKnownOrganizations = orgs
        #expect(settings.kiloKnownOrganizations == orgs)
    }

    @Test
    func `setting enabled org ids persists them`() throws {
        let settings = try self.makeSettings()
        settings.kiloEnabledOrganizationIDs = ["org_1", "org_2"]
        #expect(settings.kiloEnabledOrganizationIDs == ["org_1", "org_2"])
    }

    @Test
    func `setKiloKnownOrganizations prunes stale enabled ids`() throws {
        let settings = try self.makeSettings()
        settings.kiloKnownOrganizations = [
            KiloOrganization(id: "org_1", name: "Alpha", role: nil),
            KiloOrganization(id: "org_2", name: "Beta", role: nil),
        ]
        settings.kiloEnabledOrganizationIDs = ["org_1", "org_2"]
        settings.setKiloKnownOrganizationsPruningEnabled(
            [KiloOrganization(id: "org_2", name: "Beta", role: nil)])
        #expect(settings.kiloKnownOrganizations.map(\.id) == ["org_2"])
        #expect(settings.kiloEnabledOrganizationIDs == ["org_2"])
    }
}
