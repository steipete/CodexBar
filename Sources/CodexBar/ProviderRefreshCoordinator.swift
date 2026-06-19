import Foundation

@MainActor
final class ProviderRefreshCoordinator<Key: Hashable> {
    enum WaitResult: Equatable {
        case completed
        case retryRequired
        case cancelled
    }

    struct Request {
        let generation: UInt64
        let state: ProviderRefreshTaskState
        let predecessorStates: [ProviderRefreshTaskState]
    }

    private var states: [Key: [ProviderRefreshTaskState]] = [:]
    private var latestGenerations: [Key: UInt64] = [:]
    private var activeCounts: [Key: Int] = [:]
    private var nextGeneration: UInt64 = 0
    private var nextWaiterID: UInt64 = 0

    func coalescingState(for key: Key) -> ProviderRefreshTaskState? {
        guard let latestGeneration = self.latestGenerations[key] else { return nil }
        return self.states[key]?.last { $0.generation == latestGeneration }
    }

    func beginReplacingRequest(for key: Key) -> Request {
        self.nextGeneration &+= 1
        let generation = self.nextGeneration
        let predecessorStates = self.states[key] ?? []
        for predecessorState in predecessorStates {
            predecessorState.cancelTask()
        }
        self.latestGenerations[key] = generation
        let state = ProviderRefreshTaskState(generation: generation)
        self.states[key, default: []].append(state)
        return Request(
            generation: generation,
            state: state,
            predecessorStates: predecessorStates)
    }

    func wait(for key: Key, state: ProviderRefreshTaskState) async -> WaitResult {
        self.nextWaiterID &+= 1
        let waiterID = self.nextWaiterID
        guard let task = state.addWaiter(waiterID) else { return .completed }
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            state.cancelWaiter(waiterID)
        }
        state.finishWaiter(waiterID)
        let result: WaitResult = if Task.isCancelled {
            .cancelled
        } else if state.shouldRetry {
            .retryRequired
        } else {
            .completed
        }
        if state.canRemove {
            self.scheduleRemoval(for: key, state: state)
        }
        return result
    }

    func complete(_ state: ProviderRefreshTaskState, for key: Key, retryRequired: Bool) {
        state.markCompleted(retryRequired: retryRequired)
        self.scheduleRemoval(for: key, state: state)
    }

    func remove(_ state: ProviderRefreshTaskState, for key: Key) {
        guard var keyStates = self.states[key] else { return }
        keyStates.removeAll { $0 === state }
        if keyStates.isEmpty {
            self.states.removeValue(forKey: key)
        } else {
            self.states[key] = keyStates
        }
    }

    func isCurrent(_ generation: UInt64, for key: Key) -> Bool {
        self.latestGenerations[key] == generation
    }

    @discardableResult
    func beginActivity(for key: Key) -> Bool {
        self.activeCounts[key, default: 0] += 1
        return self.activeCounts[key] == 1
    }

    @discardableResult
    func endActivity(for key: Key) -> Bool {
        let remaining = max(0, self.activeCounts[key, default: 1] - 1)
        if remaining == 0 {
            self.activeCounts.removeValue(forKey: key)
            return true
        }
        self.activeCounts[key] = remaining
        return false
    }

    private func scheduleRemoval(for key: Key, state: ProviderRefreshTaskState) {
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self,
                  self.states[key]?.contains(where: { $0 === state }) == true,
                  state.canRemove
            else {
                return
            }
            self.remove(state, for: key)
        }
    }
}

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

    fileprivate var shouldRetry: Bool {
        self.lock.withLock { self.retryRequired }
    }

    var canRemove: Bool {
        self.lock.withLock { self.completed && self.waiterIDs.isEmpty }
    }
}
