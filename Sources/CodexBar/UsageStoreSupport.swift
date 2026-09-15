import CodexBarCore
import Foundation

extension ProviderStatusIndicator {
    var label: String {
        switch self {
        case .none: L("status_operational")
        case .minor: L("status_partial_outage")
        case .major: L("status_major_outage")
        case .critical: L("status_critical_issue")
        case .maintenance: L("status_maintenance")
        case .unknown: L("status_unknown")
        }
    }
}

struct ProviderRefreshPublicationContext {
    let generation: UInt64
    let enablementRevision: UInt64
    var configRevision: UInt64
    let tokenCostScopeSignature: String?
    let allowDisabled: Bool
}

extension ProviderStatusComponent {
    var statusLabel: String {
        Self.label(forStatuspageStatus: self.status)
    }

    static func label(forStatuspageStatus status: String) -> String {
        switch status {
        case "operational": L("status_operational")
        case "degraded_performance": L("status_degraded")
        case "partial_outage": L("status_partial_outage")
        case "major_outage", "full_outage": L("status_major_outage")
        case "under_maintenance": L("status_maintenance")
        default: L("status_unknown")
        }
    }
}

/// Tracks consecutive failures so we can ignore a single flake when we previously had fresh data.
struct ConsecutiveFailureGate {
    private(set) var streak: Int = 0

    mutating func recordSuccess() {
        self.streak = 0
    }

    mutating func reset() {
        self.streak = 0
    }

    /// Returns true when the caller should surface the error to the UI.
    mutating func shouldSurfaceError(onFailureWithPriorData hadPriorData: Bool) -> Bool {
        self.streak += 1
        if hadPriorData, self.streak == 1 {
            return false
        }
        return true
    }
}

#if DEBUG
extension UsageStore {
    func _setSnapshotForTesting(_ snapshot: UsageSnapshot?, provider: UsageProvider) {
        self.snapshots[provider.instanceID] = snapshot?.scoped(to: provider)
    }

    func _setTokenSnapshotForTesting(_ snapshot: CostUsageTokenSnapshot?, provider: UsageProvider) {
        if let snapshot {
            self.publishTokenSnapshot(snapshot, for: provider)
            if Self.usesSpendDashboardIndependentTokenSnapshot(provider) {
                self._setSpendDashboardTokenSnapshotForTesting(snapshot, for: provider)
            }
        } else {
            self.clearTokenSnapshot(for: provider)
            if Self.usesSpendDashboardIndependentTokenSnapshot(provider) {
                self.clearSpendDashboardTokenSnapshot(for: provider)
            }
        }
    }

    func _setTokenErrorForTesting(_ error: String?, provider: UsageProvider) {
        self.tokenErrors[provider.instanceID] = error
    }

    func _setErrorForTesting(_ error: String?, provider: UsageProvider) {
        self.errors[provider.instanceID] = error
    }

    func _setKnownLimitsAvailabilityForTesting(
        _ availability: UsageLimitsAvailability?,
        provider: UsageProvider)
    {
        self.knownLimitsAvailabilityByProvider[provider.instanceID] = availability
    }

    func _setCodexHistoricalDatasetForTesting(_ dataset: CodexHistoricalDataset?, accountKey: String? = nil) {
        self.codexHistoricalDataset = dataset
        self.codexHistoricalDatasetAccountKey = accountKey
        self.historicalPaceRevision += 1
    }

    /// Cancels the one-shot persisted plan-utilization load and treats the
    /// in-memory dictionary as "loaded" so callers can assign state directly
    /// without racing the background decode. Used by test helpers that
    /// intentionally seed history from scratch.
    func _cancelPlanUtilizationHistoryLoadForTesting() {
        self.planUtilizationHistoryLoadTask?.cancel()
        self.planUtilizationHistoryLoadTask = nil
        self.planUtilizationHistoryLoaded = true
    }

    /// Awaits the background plan-utilization load task to completion. Used
    /// by tests that write history files to disk before constructing
    /// `UsageStore` and then expect the dictionary to be populated by the
    /// time assertions run.
    func _waitForPlanUtilizationHistoryLoadForTesting() async {
        await self.planUtilizationHistoryLoadTask?.value
    }
}
#endif
