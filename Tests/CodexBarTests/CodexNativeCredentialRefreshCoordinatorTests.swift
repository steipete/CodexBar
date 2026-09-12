import Foundation
import Testing
@testable import CodexBarCore

struct CodexNativeCredentialRefreshCoordinatorTests {
    @Test
    func `canceling one waiter preserves shared renewal for another`() async throws {
        let coordinator = CodexNativeCredentialRefreshCoordinator()
        let gate = Gate()
        let first = Task { try await coordinator.refresh(home: "home") { await gate.wait() } }
        defer { first.cancel() }
        try await self.waitForCount(1, coordinator: coordinator)
        let second = Task {
            try await coordinator.refresh(home: "home") { Issue.record("Renewal must be coalesced") }
        }
        defer { second.cancel() }
        try await self.waitForCount(2, coordinator: coordinator)
        first.cancel()
        try await self.waitForCount(1, coordinator: coordinator)
        await #expect(throws: CancellationError.self) { try await first.value }
        await gate.release()
        try await second.value
        #expect(await coordinator.waiterCount(home: "home") == 0)
    }

    @Test
    func `last waiter cancellation cancels renewal and allows replacement`() async throws {
        let coordinator = CodexNativeCredentialRefreshCoordinator()
        let canceled = Gate()
        let first = Task {
            try await coordinator.refresh(home: "home") {
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    await canceled.release()
                    throw error
                }
            }
        }
        defer { first.cancel() }
        try await self.waitForCount(1, coordinator: coordinator)
        first.cancel()
        try await self.waitForCount(0, coordinator: coordinator)
        await #expect(throws: CancellationError.self) { try await first.value }
        try await coordinator.refresh(home: "home") {}
        // The underlying operation must observe cancellation, not just lose its waiter.
        let deadline = ContinuousClock.now + .seconds(2)
        while await !(canceled.isReleased), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await canceled.isReleased)
    }

    @Test
    func `replacement renewal waits for old teardown before starting`() async throws {
        let coordinator = CodexNativeCredentialRefreshCoordinator()
        let oldStarted = Gate()
        let teardownEntered = Gate()
        let allowExit = Gate()
        let oldExited = Gate()
        let replacementStarted = Gate()
        let first = Task {
            try await coordinator.refresh(home: "home") {
                await oldStarted.release()
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    await teardownEntered.release()
                    await allowExit.wait()
                    await oldExited.release()
                    throw error
                }
            }
        }
        defer { first.cancel() }
        await oldStarted.wait()
        try await self.waitForCount(1, coordinator: coordinator)
        #expect(await coordinator.homeIsOccupied(home: "home"))
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        await teardownEntered.wait()
        #expect(await oldExited.isReleased == false)
        // The home stays occupied while the old operation is still tearing down.
        #expect(await coordinator.homeIsOccupied(home: "home"))
        let second = Task {
            try await coordinator.refresh(home: "home") {
                await replacementStarted.release()
            }
        }
        defer { second.cancel() }
        try await self.waitForCount(1, coordinator: coordinator)
        // A coordinator that drops the home entry on cancel would have started
        // the replacement operation already.
        try await Task.sleep(for: .milliseconds(200))
        #expect(await replacementStarted.isReleased == false)
        #expect(await coordinator.homeIsOccupied(home: "home"))
        await allowExit.release()
        try await second.value
        #expect(await replacementStarted.isReleased)
        #expect(await oldExited.isReleased)
        #expect(await coordinator.waiterCount(home: "home") == 0)
        #expect(await coordinator.homeIsOccupied(home: "home") == false)
    }

    @Test
    func `queued waiter cancellation removes only itself`() async throws {
        let coordinator = CodexNativeCredentialRefreshCoordinator()
        let oldStarted = Gate()
        let teardownEntered = Gate()
        let allowExit = Gate()
        let firstUsed = Gate()
        let secondUsed = Gate()
        let first = Task {
            try await coordinator.refresh(home: "home") {
                await oldStarted.release()
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    await teardownEntered.release()
                    await allowExit.wait()
                    throw error
                }
            }
        }
        defer { first.cancel() }
        await oldStarted.wait()
        try await self.waitForCount(1, coordinator: coordinator)
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        await teardownEntered.wait()
        let queuedFirst = Task {
            try await coordinator.refresh(home: "home") {
                await firstUsed.release()
            }
        }
        defer { queuedFirst.cancel() }
        let queuedSecond = Task {
            try await coordinator.refresh(home: "home") {
                await secondUsed.release()
            }
        }
        defer { queuedSecond.cancel() }
        try await self.waitForCount(2, coordinator: coordinator)
        queuedFirst.cancel()
        await #expect(throws: CancellationError.self) { try await queuedFirst.value }
        try await self.waitForCount(1, coordinator: coordinator)
        await allowExit.release()
        try await queuedSecond.value
        // The canceled queued caller must not contribute its operation.
        #expect(await firstUsed.isReleased == false)
        #expect(await secondUsed.isReleased)
        #expect(await coordinator.homeIsOccupied(home: "home") == false)
    }

    @Test
    func `all queued waiters canceling starts no new renewal`() async throws {
        let coordinator = CodexNativeCredentialRefreshCoordinator()
        let oldStarted = Gate()
        let teardownEntered = Gate()
        let allowExit = Gate()
        let operationRuns = Counter()
        let first = Task {
            try await coordinator.refresh(home: "home") {
                await oldStarted.release()
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    await teardownEntered.release()
                    await allowExit.wait()
                    throw error
                }
            }
        }
        defer { first.cancel() }
        await oldStarted.wait()
        try await self.waitForCount(1, coordinator: coordinator)
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        await teardownEntered.wait()
        let queued = Task {
            try await coordinator.refresh(home: "home") {
                await operationRuns.increment()
            }
        }
        defer { queued.cancel() }
        try await self.waitForCount(1, coordinator: coordinator)
        queued.cancel()
        await #expect(throws: CancellationError.self) { try await queued.value }
        try await self.waitForCount(0, coordinator: coordinator)
        await allowExit.release()
        // Give a canceled-then-released old generation a chance to incorrectly start I/O.
        try await Task.sleep(for: .milliseconds(200))
        #expect(await operationRuns.isEmpty)
        #expect(await coordinator.homeIsOccupied(home: "home") == false)
    }

    @Test
    func `cleanup-unconfirmed failure starts no new renewal`() async throws {
        let coordinator = CodexNativeCredentialRefreshCoordinator()
        let oldStarted = Gate()
        let teardownEntered = Gate()
        let allowExit = Gate()
        let operationRuns = Counter()
        let first = Task {
            try await coordinator.refresh(home: "home") {
                await oldStarted.release()
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    await teardownEntered.release()
                    await allowExit.wait()
                    throw CodexCredentialRenewalError.previousProcessExitUnconfirmed
                }
            }
        }
        defer { first.cancel() }
        await oldStarted.wait()
        try await self.waitForCount(1, coordinator: coordinator)
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        await teardownEntered.wait()
        let queued = Task {
            try await coordinator.refresh(home: "home") {
                await operationRuns.increment()
            }
        }
        defer { queued.cancel() }
        try await self.waitForCount(1, coordinator: coordinator)
        await allowExit.release()
        await #expect(throws: CodexCredentialRenewalError.self) { try await queued.value }
        #expect(await operationRuns.isEmpty)
        #expect(await coordinator.homeIsOccupied(home: "home") == false)
    }

    @Test
    func `different homes drain independently`() async throws {
        let coordinator = CodexNativeCredentialRefreshCoordinator()
        let oldStarted = Gate()
        let teardownEntered = Gate()
        let allowExit = Gate()
        let otherRan = Gate()
        let first = Task {
            try await coordinator.refresh(home: "home-a") {
                await oldStarted.release()
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    await teardownEntered.release()
                    await allowExit.wait()
                    throw error
                }
            }
        }
        defer { first.cancel() }
        await oldStarted.wait()
        try await self.waitForCount(1, home: "home-a", coordinator: coordinator)
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        await teardownEntered.wait()
        #expect(await coordinator.homeIsOccupied(home: "home-a"))
        // A draining home must not block an unrelated home.
        try await coordinator.refresh(home: "home-b") {
            await otherRan.release()
        }
        #expect(await otherRan.isReleased)
        #expect(await coordinator.homeIsOccupied(home: "home-a"))
        await allowExit.release()
        let deadline = ContinuousClock.now + .seconds(2)
        while await coordinator.homeIsOccupied(home: "home-a"), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await coordinator.homeIsOccupied(home: "home-a") == false)
    }

    private func waitForCount(
        _ count: Int,
        home: String = "home",
        coordinator: CodexNativeCredentialRefreshCoordinator) async throws
    {
        let deadline = ContinuousClock.now + .seconds(2)
        while await coordinator.waiterCount(home: home) != count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(await coordinator.waiterCount(home: home) == count)
    }

    private actor Gate {
        private(set) var isReleased = false
        private var continuation: CheckedContinuation<Void, Never>?

        func wait() async {
            guard !self.isReleased else { return }
            await withCheckedContinuation { self.continuation = $0 }
        }

        func release() {
            self.isReleased = true
            self.continuation?.resume()
            self.continuation = nil
        }
    }

    private actor Counter {
        private(set) var didRun = false

        var isEmpty: Bool {
            !self.didRun
        }

        func increment() {
            self.didRun = true
        }
    }
}
