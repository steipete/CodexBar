import CodexBarCore
import Foundation

extension UsageStore {
    func browserSessionLastKnownUsageCapturedAt(for provider: UsageProvider, snapshot: UsageSnapshot?) -> Date? {
        guard Self.requiresBrowserSession(provider), self.userFacingError(for: provider) != nil else { return nil }
        return snapshot?.updatedAt
    }

    nonisolated static func requiresBrowserSession(_ provider: UsageProvider) -> Bool {
        ProviderDescriptorRegistry.descriptor(for: provider).settingsSection.selectedProfileBrowsers != nil
    }

    func profileScopedSnapshot(for instanceID: ProviderInstanceID) -> UsageSnapshot? {
        let snapshot = self.snapshots[instanceID]
        guard let provider = instanceID.firstPartyProvider,
              let browsers = ProviderDescriptorRegistry.descriptor(for: provider).settingsSection
                  .selectedProfileBrowsers
        else { return snapshot }
        guard let snapshot, let owner = snapshot.browserSessionOwner,
              owner.profile == ProviderBrowserProfile.selected(
                  in: self.settings.providerConfig(for: provider), browsers: browsers)
        else { return nil }
        return snapshot
    }

    func shouldSurfaceProviderRefreshFailure(
        provider: UsageProvider,
        state: (hadPriorData: Bool, preservesPriorData: Bool, restoredClaudeHistory: Bool)) -> Bool
    {
        if Self.requiresBrowserSession(provider) {
            if !state.preservesPriorData {
                self.lastKnownResetSnapshots.removeValue(forKey: provider.instanceID)
                self.lastSourceLabels.removeValue(forKey: provider.instanceID)
            }
            if state.hadPriorData { return true }
        }
        if state.restoredClaudeHistory { return true }
        return self.failureGates[provider.instanceID]?
            .shouldSurfaceError(onFailureWithPriorData: state.hadPriorData) ?? true
    }
}

extension UsageSnapshot {
    func backfillingResetTimesForProvider(_ provider: UsageProvider, from cached: UsageSnapshot?) -> UsageSnapshot {
        // Session-bound snapshots report unknown resets explicitly and cannot inherit another login's dates.
        UsageStore.requiresBrowserSession(provider) ? self : self.backfillingResetTimes(from: cached)
    }
}

enum BrowserSessionFailurePolicy {
    static func hasMatchingOwner(after error: Error, priorSnapshot: UsageSnapshot?) -> Bool {
        if let failure = error as? ProviderBrowserSessionFailure {
            guard let owner = failure.owner else { return false }
            return priorSnapshot?.browserSessionOwner == owner
        }
        let requiresOwner = priorSnapshot?.identity?.providerID?.firstPartyProvider
            .map(UsageStore.requiresBrowserSession)
            ?? false
        return !requiresOwner && priorSnapshot?.browserSessionOwner == nil
    }

    static func isTransient(_ error: Error) -> Bool {
        guard let failure = error as? ProviderBrowserSessionFailure else { return false }
        if failure.underlyingError as? ProviderPluginError == .timedOut { return true }
        guard let classified = failure.underlyingError as? ProviderFetchClassifiedError else { return false }
        return [.rateLimited, .providerUnavailable, .networkFailure].contains(classified.kind)
    }
}
