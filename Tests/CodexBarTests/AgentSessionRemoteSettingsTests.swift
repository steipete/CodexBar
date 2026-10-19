import Foundation
import Testing
@testable import CodexBar

@MainActor
struct AgentSessionRemoteSettingsTests {
    @Test
    func `new installs remain local only after enabling sessions and reloading`() {
        let defaults = InMemoryUserDefaults()
        let settings = testSettingsStore(suiteName: "remote-new", userDefaults: defaults)
        #expect(!settings.agentSessionsRemoteEnabled)
        settings.agentSessionsEnabled = true
        let reloaded = testSettingsStore(suiteName: "remote-reload", userDefaults: defaults)
        #expect(reloaded.agentSessionsEnabled)
        #expect(!reloaded.agentSessionsRemoteEnabled)
    }

    @Test
    func `existing sessions preserve remote monitoring until explicitly disabled`() {
        let defaults = InMemoryUserDefaults(values: ["agentSessionsEnabled": true])
        let settings = testSettingsStore(suiteName: "remote-upgrade", userDefaults: defaults)
        #expect(settings.agentSessionsRemoteEnabled)
        settings.agentSessionsRemoteEnabled = false
        let reloaded = testSettingsStore(suiteName: "remote-opt-out", userDefaults: defaults)
        #expect(!reloaded.agentSessionsRemoteEnabled)
        #expect(reloaded.agentSessionsEnabled)
    }
}
