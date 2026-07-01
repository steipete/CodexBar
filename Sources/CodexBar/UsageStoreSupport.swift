import CodexBarCore
import Foundation

enum ProviderStatusIndicator: String {
    case none
    case minor
    case major
    case critical
    case maintenance
    case unknown

    var hasIssue: Bool {
        switch self {
        case .none: false
        default: true
        }
    }

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

struct ProviderStatus {
    let indicator: ProviderStatusIndicator
    let description: String?
    let updatedAt: Date?
}

/// A single component/service row on a statuspage.io-style status page
/// (e.g. "Codex API", "CLI", "FedRAMP") with its current state. A row with non-empty
/// `children` is a component group and renders as an expandable dropdown.
struct ProviderStatusComponent: Identifiable, Equatable {
    let id: String
    let name: String
    let indicator: ProviderStatusIndicator
    /// Raw provider status. The display label is localized when the row renders so changing
    /// the app language does not require another network refresh.
    let status: String
    /// Child rows for a component group; empty for leaf components.
    var children: [ProviderStatusComponent] = []

    var isGroup: Bool {
        !self.children.isEmpty
    }

    var statusLabel: String {
        Self.label(forStatuspageStatus: self.status)
    }

    /// Maps a statuspage.io component `status` string to our indicator + display label.
    static func indicator(forStatuspageStatus status: String) -> ProviderStatusIndicator {
        switch status {
        case "operational": .none
        case "degraded_performance": .minor
        case "partial_outage": .major
        case "major_outage", "full_outage": .critical
        case "under_maintenance": .maintenance
        default: .unknown
        }
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
        if hadPriorData, self.streak == 1 { return false }
        return true
    }
}

#if DEBUG
extension UsageStore {
    func _setSnapshotForTesting(_ snapshot: UsageSnapshot?, provider: UsageProvider) {
        self.snapshots[provider] = snapshot?.scoped(to: provider)
    }

    func _setTokenSnapshotForTesting(_ snapshot: CostUsageTokenSnapshot?, provider: UsageProvider) {
        self.tokenSnapshots[provider] = snapshot
    }

    func _setTokenErrorForTesting(_ error: String?, provider: UsageProvider) {
        self.tokenErrors[provider] = error
    }

    func _setErrorForTesting(_ error: String?, provider: UsageProvider) {
        self.errors[provider] = error
    }

    func _setCodexHistoricalDatasetForTesting(_ dataset: CodexHistoricalDataset?, accountKey: String? = nil) {
        self.codexHistoricalDataset = dataset
        self.codexHistoricalDatasetAccountKey = accountKey
        self.historicalPaceRevision += 1
    }
}
#endif
