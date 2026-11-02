import CodexBarCore
import Foundation

extension SettingsStore {
    func setCostUsageHost(_ host: String, enabled: Bool) {
        self.updateHostPreferences { $0.setCostUsage(host, enabled: enabled) }
    }

    @discardableResult
    func editManualHosts(baseline: String, draft: String) -> String? {
        guard baseline != draft else { return self.agentSessionsManualHosts }
        guard self.updateHostPreferences({ $0 = HostPreferences.editing($0, baseline: baseline, draft: draft) })
        else { return nil }
        return self.agentSessionsManualHosts
    }

    /// Notification, startup and each manual collection re-read the sole canonical host values.
    @discardableResult
    func refreshHostPreferences() -> Bool {
        self.updateHostPreferences { _ in }
    }

    /// Each app SSH spend fetch re-reads canonical consent first; a failed read or released store denies it.
    var spendHostConsent: @MainActor @Sendable (String) -> Bool {
        { [weak self] host in
            guard let self, self.refreshHostPreferences() else { return false }
            return self.costUsageHosts.contains(host)
        }
    }

    /// Spawns an app SSH spend fetch inside the canonical host transaction, so a committed removal prevents it.
    var spendHostLaunch: @MainActor @Sendable (String, @Sendable () throws -> Void) throws -> Void {
        { [weak self] host, launch in
            var launched = false
            do {
                guard let self, let lockURL = self.hostPreferencesLockURL else { throw CancellationError() }
                _ = try HostPreferences.update(in: self.userDefaults, lockURL: lockURL) { state in
                    guard state.costUsageHosts.contains(host), !Task.isCancelled else { throw CancellationError() }
                    launched = true
                    try launch()
                }
            } catch _ where !launched { throw CancellationError() }
        }
    }

    @discardableResult
    func updateHostPreferences(_ operation: (inout HostPreferences.State) -> Void) -> Bool {
        do {
            let state = try HostPreferences.update(
                in: self.userDefaults, lockURL: self.hostPreferencesLockURL, operation: operation).state
            self.projectHostPreferences(state)
            return true
        } catch {
            CodexBarLog.logger(LogCategories.settings).error("Could not update SSH hosts: \(error)")
            return false
        }
    }

    private func projectHostPreferences(_ state: HostPreferences.State) {
        // Publish both fields together only after success; never recurse through public setters.
        var next = self.defaultsState
        next.agentSessionsManualHosts = state.manualTokens.joined(separator: ",")
        next.costUsageHosts = state.costUsageHosts
        self.defaultsState = next
    }
}
