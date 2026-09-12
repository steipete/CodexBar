import Foundation
import Observation
import Testing
@testable import CodexBar

@MainActor
struct AgentSessionVisibilitySettingsTests {
    private final class ObservationFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var changed = false
        func set() {
            self.lock.withLock { self.changed = true }
        }

        func get() -> Bool {
            self.lock.withLock { self.changed }
        }
    }

    @Test(arguments: [false, true])
    func `missing preference preserves diagnostics for new and existing users`(alreadyEnabled: Bool) {
        let defaults = InMemoryUserDefaults(values: ["agentSessionsEnabled": alreadyEnabled])
        let settings = testSettingsStore(suiteName: "host-visibility-default", userDefaults: defaults)
        #expect(!settings.agentSessionsHideUnreachableHosts)
        #expect(defaults.object(forKey: "agentSessionsHideUnreachableHosts") == nil)
    }

    @Test(arguments: [false, true])
    func `explicit visibility choice survives settings reload`(hidden: Bool) {
        let defaults = InMemoryUserDefaults()
        let settings = testSettingsStore(suiteName: "host-visibility-persist", userDefaults: defaults)
        settings.agentSessionsHideUnreachableHosts = hidden
        let reloaded = testSettingsStore(suiteName: "host-visibility-reload", userDefaults: defaults)
        #expect(reloaded.agentSessionsHideUnreachableHosts == hidden)
        #expect(defaults.object(forKey: "agentSessionsHideUnreachableHosts") as? Bool == hidden)
    }

    @Test
    func `visibility changes invalidate menu observation without changing refresh cadence`() {
        let settings = testSettingsStore(suiteName: "host-visibility-observation", userDefaults: InMemoryUserDefaults())
        let revision = settings.backgroundWorkSettingsRevision
        let changed = ObservationFlag()
        withObservationTracking {
            _ = settings.menuObservationToken
        } onChange: {
            changed.set()
        }
        settings.agentSessionsHideUnreachableHosts = true
        #expect(changed.get())
        #expect(settings.backgroundWorkSettingsRevision == revision)
    }
}
