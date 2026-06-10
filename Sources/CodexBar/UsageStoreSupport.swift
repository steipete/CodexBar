import CodexBarCore
import Foundation

final class ProviderRefreshTaskState: @unchecked Sendable {
    let generation: UInt64

    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var waiterIDs: Set<UInt64> = []
    private var completed = false
    private var retryRequired = false

    init(generation: UInt64) {
        self.generation = generation
    }

    func install(task: Task<Void, Never>) {
        self.lock.withLock {
            self.task = task
        }
    }

    func addWaiter(_ waiterID: UInt64) -> Task<Void, Never>? {
        self.lock.withLock {
            self.waiterIDs.insert(waiterID)
            return self.task
        }
    }

    func cancelWaiter(_ waiterID: UInt64) {
        let taskToCancel = self.lock.withLock {
            guard self.waiterIDs.remove(waiterID) != nil else { return nil as Task<Void, Never>? }
            return self.waiterIDs.isEmpty && !self.completed ? self.task : nil
        }
        taskToCancel?.cancel()
    }

    func finishWaiter(_ waiterID: UInt64) {
        _ = self.lock.withLock {
            self.waiterIDs.remove(waiterID)
        }
    }

    func markCompleted(retryRequired: Bool) {
        self.lock.withLock {
            self.completed = true
            self.retryRequired = retryRequired
        }
    }

    func cancelTask() {
        let task = self.lock.withLock {
            self.completed ? nil : self.task
        }
        task?.cancel()
    }

    func waitForTaskCompletion() async {
        let task = self.lock.withLock { self.task }
        await task?.value
    }

    var isCompleted: Bool {
        self.lock.withLock { self.completed }
    }

    var shouldRetry: Bool {
        self.lock.withLock { self.retryRequired }
    }

    var canRemove: Bool {
        self.lock.withLock { self.completed && self.waiterIDs.isEmpty }
    }
}

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
