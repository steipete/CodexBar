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

    /// Projects canonical hosts, then spawns an app SSH spend fetch in that transaction, so removal prevents it.
    var spendHostLaunch: @MainActor @Sendable (String, @Sendable () throws -> Void) throws -> Void {
        { [weak self] host, launch in
            guard let self, let lockURL = self.hostPreferencesLockURL else { throw CancellationError() }
            let launched = try? HostPreferences.update(in: self.userDefaults, lockURL: lockURL) { state in
                self.projectHostPreferences(state)
                guard state.costUsageHosts.contains(host), !Task.isCancelled else { throw CancellationError() }
                return Result { try launch() }
            }
            guard let launched else { throw CancellationError() }
            try launched.result.get()
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
