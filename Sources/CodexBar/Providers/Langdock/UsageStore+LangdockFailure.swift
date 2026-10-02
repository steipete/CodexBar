import CodexBarCore
import Foundation

extension UsageStore {
    func langdockLastKnownUsageCapturedAt(for provider: UsageProvider, snapshot: UsageSnapshot?) -> Date? {
        guard provider == .langdock, self.userFacingError(for: provider) != nil else { return nil }
        return snapshot?.updatedAt
    }

    func profileScopedSnapshot(for instanceID: ProviderInstanceID) -> UsageSnapshot? {
        let snapshot = self.snapshots[instanceID]
        guard instanceID == .langdock else { return snapshot }
        let settings = LangdockProviderSettings(
            edgeProfileID: self.settings.providerConfig(for: .langdock)?.langdockEdgeProfileID)
        guard let snapshot,
              let profileID = settings.edgeProfileID,
              snapshot.identity?.accountID == profileID,
              snapshot.langdockSessionOwner?.profileID == profileID
        else { return nil }
        return snapshot
    }

    func shouldSurfaceProviderRefreshFailure(
        provider: UsageProvider,
        state: (hadPriorData: Bool, preservesPriorData: Bool, restoredClaudeHistory: Bool)) -> Bool
    {
        if provider == .langdock {
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
        // Langdock explicitly reports an unknown reset by omitting it. Do not revive an older date.
        provider == .langdock ? self : self.backfillingResetTimes(from: cached)
    }
}

enum LangdockFailurePolicy {
    static func hasMatchingOwner(after error: Error, priorSnapshot: UsageSnapshot?) -> Bool {
        guard let failure = error as? LangdockFetchError else {
            return !(error is LangdockUsageError) && priorSnapshot?.identity?.providerID != .langdock &&
                priorSnapshot?.langdockSessionOwner == nil
        }
        guard let owner = failure.owner else { return false }
        return priorSnapshot?.langdockSessionOwner == owner
    }

    static func isTransient(_ error: Error) -> Bool {
        let underlying = (error as? LangdockFetchError)?.underlyingError ?? error
        guard let error = underlying as? LangdockUsageError else { return false }
        return switch error {
        case let .httpStatus(status): status == 429 || (500...599).contains(status)
        case let .rejected(code): ["TOO_MANY_REQUESTS", "INTERNAL_SERVER_ERROR", "TIMEOUT"].contains(code)
        case .profileUnreadable, .browserAccessPaused: true
        default: false
        }
    }
}
