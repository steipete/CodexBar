import CodexBarCore

actor PlanUtilizationHistoryPersistenceCoordinator {
    private let store: PlanUtilizationHistoryStore
    private var pendingSnapshot: [UsageProvider: PlanUtilizationHistoryBuckets]?
    private var isPersisting: Bool = false

    init(store: PlanUtilizationHistoryStore) {
        self.store = store
    }

    func enqueue(_ snapshot: [UsageProvider: PlanUtilizationHistoryBuckets]) {
        self.pendingSnapshot = snapshot
        guard !self.isPersisting else { return }
        self.isPersisting = true

        Task(priority: .utility) {
            await self.persistLoop()
        }
    }

    private func persistLoop() async {
        while let nextSnapshot = self.pendingSnapshot {
            self.pendingSnapshot = nil
            await self.saveAsync(nextSnapshot)
        }

        self.isPersisting = false
    }

    private func saveAsync(_ snapshot: [UsageProvider: PlanUtilizationHistoryBuckets]) async {
        let store = self.store
        await Task.detached(priority: .utility) {
            store.save(snapshot)
        }.value
    }

    #if DEBUG
    func waitForIdleForTesting() async {
        while self.isPersisting || self.pendingSnapshot != nil {
            await Task.yield()
        }
    }
    #endif
}
