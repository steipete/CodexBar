import Foundation
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct SettingsStoreCodexLocalProjectUsageTests {
    @Test
    func `absent preference inherits local cost usage without materializing a value`() throws {
        let (settings, defaults, suite) = try self.makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(settings.codexLocalProjectUsageEnabledOverride == nil)
        #expect(defaults.object(forKey: "codexLocalProjectUsageEnabled") == nil)
        #expect(!settings.codexLocalProjectUsageEnabled)

        settings.costUsageEnabled = true
        #expect(settings.codexLocalProjectUsageEnabled)
        #expect(settings.codexLocalProjectUsageEnabledOverride == nil)
        #expect(defaults.object(forKey: "codexLocalProjectUsageEnabled") == nil)

        settings.costUsageEnabled = false
        #expect(!settings.codexLocalProjectUsageEnabled)
        #expect(defaults.object(forKey: "codexLocalProjectUsageEnabled") == nil)
    }

    @Test
    func `explicit preference overrides local cost usage`() throws {
        let (settings, defaults, suite) = try self.makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }

        settings.codexLocalProjectUsageEnabled = true
        settings.costUsageEnabled = false
        #expect(settings.codexLocalProjectUsageEnabled)
        #expect(settings.codexLocalProjectUsageEnabledOverride == true)
        #expect(defaults.object(forKey: "codexLocalProjectUsageEnabled") as? Bool == true)

        settings.codexLocalProjectUsageEnabled = false
        settings.costUsageEnabled = true
        #expect(!settings.codexLocalProjectUsageEnabled)
        #expect(settings.codexLocalProjectUsageEnabledOverride == false)
        #expect(defaults.object(forKey: "codexLocalProjectUsageEnabled") as? Bool == false)
    }

    @Test
    func `clearing preference restores inheritance across store reloads`() throws {
        let (settings, defaults, suite) = try self.makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }
        settings.costUsageEnabled = true
        settings.codexLocalProjectUsageEnabled = false

        settings.clearCodexLocalProjectUsageEnabledOverride()
        #expect(settings.codexLocalProjectUsageEnabled)
        #expect(settings.codexLocalProjectUsageEnabledOverride == nil)
        #expect(defaults.object(forKey: "codexLocalProjectUsageEnabled") == nil)

        let reloaded = self.makeSettings(userDefaults: defaults, suite: suite)
        #expect(reloaded.codexLocalProjectUsageEnabled)
        #expect(reloaded.codexLocalProjectUsageEnabledOverride == nil)
        #expect(defaults.object(forKey: "codexLocalProjectUsageEnabled") == nil)
    }

    @Test
    func `explicit override only bumps background revision when effective enablement changes`() throws {
        let (settings, defaults, suite) = try self.makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }
        let initialRevision = settings.backgroundWorkSettingsRevision

        settings.codexLocalProjectUsageEnabled = false
        #expect(settings.backgroundWorkSettingsRevision == initialRevision)
        #expect(settings.codexLocalProjectUsageEnabledOverride == false)

        settings.clearCodexLocalProjectUsageEnabledOverride()
        #expect(settings.backgroundWorkSettingsRevision == initialRevision)
        #expect(settings.codexLocalProjectUsageEnabledOverride == nil)

        settings.codexLocalProjectUsageEnabled = true
        #expect(settings.backgroundWorkSettingsRevision == initialRevision + 1)
        #expect(settings.codexLocalProjectUsageEnabledOverride == true)
    }

    @Test
    func `clearing override only bumps background revision when inheritance changes enablement`() throws {
        let (settings, defaults, suite) = try self.makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }

        settings.codexLocalProjectUsageEnabled = false
        let unchangedRevision = settings.backgroundWorkSettingsRevision
        settings.clearCodexLocalProjectUsageEnabledOverride()
        #expect(settings.backgroundWorkSettingsRevision == unchangedRevision)

        settings.codexLocalProjectUsageEnabled = true
        let changedRevision = settings.backgroundWorkSettingsRevision
        settings.clearCodexLocalProjectUsageEnabledOverride()
        #expect(settings.backgroundWorkSettingsRevision == changedRevision + 1)
        #expect(!settings.codexLocalProjectUsageEnabled)
        #expect(settings.codexLocalProjectUsageEnabledOverride == nil)
    }

    @Test
    func `display preferences do not bump background revision`() throws {
        let (settings, defaults, suite) = try self.makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }
        let revision = settings.backgroundWorkSettingsRevision

        settings.codexLocalProjectUsageShowsEstimatedCost.toggle()
        settings.codexLocalProjectUsageIncludesCachedInput.toggle()

        #expect(settings.backgroundWorkSettingsRevision == revision)
    }

    private func makeSettings() throws -> (SettingsStore, UserDefaults, String) {
        let suite = "SettingsStoreCodexLocalProjectUsageTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return (self.makeSettings(userDefaults: defaults, suite: suite), defaults, suite)
    }

    private func makeSettings(userDefaults: UserDefaults, suite: String) -> SettingsStore {
        SettingsStore(
            userDefaults: userDefaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
    }
}
