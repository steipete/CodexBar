import Testing
@testable import CodexBar

@MainActor
struct ProviderRefreshCoordinatorTests {
    @Test
    func `replacement cancels and orders predecessor while advancing current generation`() async {
        let coordinator = ProviderRefreshCoordinator<String>()
        let first = coordinator.beginReplacingRequest(for: "codex")
        let firstTask = Task {
            while !Task.isCancelled {
                await Task.yield()
            }
        }
        first.state.install(task: firstTask)

        let second = coordinator.beginReplacingRequest(for: "codex")

        #expect(firstTask.isCancelled)
        #expect(second.predecessorStates.count == 1)
        #expect(second.predecessorStates[0] === first.state)
        #expect(!coordinator.isCurrent(first.generation, for: "codex"))
        #expect(coordinator.isCurrent(second.generation, for: "codex"))
        await firstTask.value
    }

    @Test
    func `invalidation cancels work without dropping waiter completion`() async {
        let coordinator = ProviderRefreshCoordinator<String>()
        let request = coordinator.beginReplacingRequest(for: "codex")
        let gate = ProviderRefreshCoordinatorGate()
        let task = Task {
            await gate.wait()
        }
        request.state.install(task: task)
        let waiter = Task {
            await coordinator.wait(for: "codex", state: request.state)
        }
        await Task.yield()

        coordinator.invalidateRequests(for: "codex")

        #expect(task.isCancelled)
        #expect(!coordinator.isCurrent(request.generation, for: "codex"))
        #expect(coordinator.coalescingState(for: "codex") == nil)

        await gate.resume()
        await task.value
        coordinator.complete(request.state, for: "codex", retryRequired: false)
        #expect(await waiter.value == .completed)
    }

    @Test
    func `coalescing returns latest request independently per key`() {
        let coordinator = ProviderRefreshCoordinator<String>()
        let firstCodex = coordinator.beginReplacingRequest(for: "codex")
        let claude = coordinator.beginReplacingRequest(for: "claude")
        let latestCodex = coordinator.beginReplacingRequest(for: "codex")

        #expect(coordinator.coalescingState(for: "codex") === latestCodex.state)
        #expect(coordinator.coalescingState(for: "claude") === claude.state)
        #expect(coordinator.coalescingState(for: "codex") !== firstCodex.state)
    }

    @Test
    func `canceling one of two waiters keeps shared task alive`() async {
        let coordinator = ProviderRefreshCoordinator<String>()
        let request = coordinator.beginReplacingRequest(for: "codex")
        let gate = ProviderRefreshCoordinatorGate()
        let task = Task {
            await gate.wait()
        }
        request.state.install(task: task)

        let owner = Task {
            await coordinator.wait(for: "codex", state: request.state)
        }
        let shared = Task {
            await coordinator.wait(for: "codex", state: request.state)
        }
        await Task.yield()
        owner.cancel()
        await Task.yield()

        #expect(!task.isCancelled)

        await gate.resume()
        coordinator.complete(request.state, for: "codex", retryRequired: false)
        _ = await owner.value
        _ = await shared.value
    }

    @Test
    func `wait result exposes retry without leaking task state`() async {
        let coordinator = ProviderRefreshCoordinator<String>()
        let request = coordinator.beginReplacingRequest(for: "codex")
        let task = Task {}
        request.state.install(task: task)
        coordinator.complete(request.state, for: "codex", retryRequired: true)

        let result = await coordinator.wait(for: "codex", state: request.state)

        #expect(result == .retryRequired)
    }

    @Test
    func `completed request is not offered for coalescing before deferred removal`() {
        let coordinator = ProviderRefreshCoordinator<String>()
        let request = coordinator.beginReplacingRequest(for: "codex")
        let task = Task {}
        request.state.install(task: task)

        coordinator.complete(request.state, for: "codex", retryRequired: false)

        #expect(coordinator.coalescingState(for: "codex") == nil)
    }

    @Test
    func `completion removal and activity counts are key scoped`() async {
        let coordinator = ProviderRefreshCoordinator<String>()
        let codex = coordinator.beginReplacingRequest(for: "codex")
        let claude = coordinator.beginReplacingRequest(for: "claude")
        let codexTask = Task {}
        let claudeTask = Task {}
        codex.state.install(task: codexTask)
        claude.state.install(task: claudeTask)

        #expect(coordinator.beginActivity(for: "codex"))
        #expect(!coordinator.beginActivity(for: "codex"))
        #expect(coordinator.beginActivity(for: "claude"))
        #expect(!coordinator.endActivity(for: "codex"))
        #expect(coordinator.endActivity(for: "codex"))
        #expect(coordinator.endActivity(for: "claude"))

        coordinator.complete(codex.state, for: "codex", retryRequired: true)
        coordinator.complete(claude.state, for: "claude", retryRequired: false)
        await codexTask.value
        await claudeTask.value
        await Task.yield()
        await Task.yield()

        #expect(coordinator.coalescingState(for: "codex") == nil)
        #expect(coordinator.coalescingState(for: "claude") == nil)
    }
}

private actor ProviderRefreshCoordinatorGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resume() {
        self.continuation?.resume()
        self.continuation = nil
    }
}
