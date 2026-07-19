import Foundation
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

struct CLIServeTimeoutTests {
    @Test
    func `serve cost keeps pricing refresh outside the request deadline`() {
        #expect(CodexBarCLI.serveCostRefreshesPricingInBackground)
    }

    @Test
    func `serve deadlines clamp once from request entry`() throws {
        #expect(CodexBarCLI.clampedServeRequestTimeout(.greatestFiniteMagnitude) == 86400)
        #expect(CodexBarCLI.clampedServeRequestTimeout(1e308) == 86400)
        #expect(CodexBarCLI.clampedServeRequestTimeout(-5) == 0)

        let startedAt = ContinuousClock().now
        let deadline = try #require(CodexBarCLI.serveRequestDeadline(
            startedAt: startedAt,
            requestTimeout: .greatestFiniteMagnitude))
        #expect(startedAt.duration(to: deadline) == .seconds(86400))
        #expect(CodexBarCLI.serveRequestDeadline(startedAt: startedAt, requestTimeout: 0) == nil)

        let requestDeadline = startedAt.advanced(by: .seconds(40))
        #expect(CodexBarCLI.serveCostProviderDeadline(
            startedAt: startedAt,
            providerTimeout: 30,
            requestDeadline: requestDeadline) == startedAt.advanced(by: .seconds(30)))
        #expect(CodexBarCLI.serveCostProviderDeadline(
            startedAt: startedAt.advanced(by: .seconds(20)),
            providerTimeout: 30,
            requestDeadline: requestDeadline) == requestDeadline)
        #expect(CodexBarCLI.serveCostProviderDeadline(
            startedAt: startedAt,
            providerTimeout: nil,
            requestDeadline: nil) == nil)
    }

    @Test
    func `timed out source stays owned and later requests never overlap`() async {
        let clock = ServeManualDeadlineClock()
        let gate = ServeFetchGate<Int>()
        let coordinator: CLIServeOperationCoordinator<Int> = self.makeCoordinator(clock: clock)
        let deadline = clock.now().advanced(by: .seconds(30))

        let first = Task {
            await coordinator.value(
                for: "usage:",
                fingerprint: "config-a",
                deadline: deadline,
                timeoutValue: -1)
            {
                await gate.run(1)
            }
        }
        await gate.waitForStarts(1)
        await clock.waitForPendingSleeps(1)
        await clock.fireAll()

        #expect(await first.value == -1)
        #expect(await coordinator.snapshot().operationCount == 1)
        #expect(await coordinator.snapshot().timerCount == 0)

        let later = (0..<4).map { _ in
            Task {
                await coordinator.value(
                    for: "usage:",
                    fingerprint: "config-a",
                    deadline: deadline.advanced(by: .seconds(30)),
                    timeoutValue: -1)
                {
                    await gate.run(2)
                }
            }
        }
        await self.waitForOperationCount(2, coordinator: coordinator)
        await clock.waitForPendingSleeps(1)
        await clock.fireAll()
        for task in later {
            #expect(await task.value == -1)
        }
        #expect(await gate.startCount() == 1)
        #expect(await gate.peakCount() == 1)

        await gate.releaseAll()
        await gate.waitForActive(0)
        await self.waitForOperationCount(0, coordinator: coordinator)
    }

    @Test
    func `earlier follower tightens the shared absolute budget`() async {
        let clock = ServeManualDeadlineClock()
        let gate = ServeFetchGate<Int>()
        let coordinator: CLIServeOperationCoordinator<Int> = self.makeCoordinator(clock: clock)
        let firstDeadline = clock.now().advanced(by: .seconds(30))

        let first = Task {
            await coordinator.value(
                for: "cost:",
                fingerprint: "config-a",
                deadline: firstDeadline,
                timeoutValue: -1)
            {
                await gate.run(1)
            }
        }
        await gate.waitForStarts(1)
        await clock.waitForPendingSleeps(1)

        let shorterFollower = Task {
            await coordinator.value(
                for: "cost:",
                fingerprint: "config-a",
                deadline: firstDeadline.advanced(by: .seconds(-1)),
                timeoutValue: -2)
            {
                await gate.run(2)
            }
        }
        await self.waitForWaiterCount(2, coordinator: coordinator)
        await clock.waitForCancellations(1)
        await clock.waitForPendingSleeps(1)
        clock.advance(by: .seconds(29))
        await clock.fireAll()

        #expect(await first.value == -1)
        #expect(await shorterFollower.value == -2)
        #expect(await gate.startCount() == 1)

        await gate.releaseAll()
        await gate.waitForActive(0)
        await self.waitForOperationCount(0, coordinator: coordinator)
        #expect(await coordinator.snapshot().operationCount == 0)
    }

    @Test
    func `source completing at an overdue deadline cannot beat a delayed timer`() async {
        let clock = ServeManualDeadlineClock()
        let gate = ServeFetchGate<Int>()
        let acceptance = ServeAcceptanceProbe<Int>()
        let coordinator: CLIServeOperationCoordinator<Int> = self.makeCoordinator(clock: clock)

        let result = Task {
            await coordinator.value(
                for: "usage:",
                fingerprint: "config-a",
                deadline: clock.now().advanced(by: .seconds(30)),
                timeoutValue: -1,
                accept: { await acceptance.accept($0) },
                operation: { await gate.run(7) })
        }
        await gate.waitForStarts(1)
        await clock.waitForPendingSleeps(1)
        clock.advance(by: .seconds(30))
        await gate.releaseAll()

        #expect(await result.value == -1)
        #expect(await acceptance.callCount() == 0)
        await clock.waitForCancellations(1)
        await self.waitForOperationCount(0, coordinator: coordinator)
    }

    @Test
    func `shared deadline returns each waiters own timeout value`() async {
        let clock = ServeManualDeadlineClock()
        let gate = ServeFetchGate<Int>()
        let coordinator: CLIServeOperationCoordinator<Int> = self.makeCoordinator(clock: clock)
        let deadline = clock.now().advanced(by: .seconds(30))

        let leader = Task {
            await coordinator.value(
                for: "usage:",
                fingerprint: "config-a",
                deadline: deadline,
                timeoutValue: -1)
            {
                await gate.run(1)
            }
        }
        await gate.waitForStarts(1)
        await clock.waitForPendingSleeps(1)
        let follower = Task {
            await coordinator.value(
                for: "usage:",
                fingerprint: "config-a",
                deadline: deadline.advanced(by: .seconds(1)),
                timeoutValue: -2)
            {
                await gate.run(2)
            }
        }
        await self.waitForWaiterCount(2, coordinator: coordinator)
        await clock.fireAll()

        #expect(await leader.value == -1)
        #expect(await follower.value == -2)
        await gate.releaseAll()
        await gate.waitForActive(0)
        await self.waitForOperationCount(0, coordinator: coordinator)
    }

    @Test
    func `finite follower fails closed behind deadline free source`() async {
        let gate = ServeFetchGate<Int>()
        let coordinator = CLIServeOperationCoordinator<Int>()

        let first = Task {
            await coordinator.value(
                for: "usage:",
                fingerprint: "config-a",
                deadline: nil,
                timeoutValue: -1)
            {
                await gate.run(1)
            }
        }
        await gate.waitForStarts(1)

        let follower = await coordinator.value(
            for: "usage:",
            fingerprint: "config-a",
            deadline: ContinuousClock().now.advanced(by: .seconds(30)),
            timeoutValue: -2)
        {
            await gate.run(2)
        }
        #expect(follower == -2)
        #expect(await gate.startCount() == 1)

        await gate.releaseAll()
        #expect(await first.value == 1)
    }

    @Test
    func `waiter cancellation unregisters and last waiter cancels source`() async {
        let clock = ServeManualDeadlineClock()
        let gate = ServeFetchGate<Int>()
        let coordinator: CLIServeOperationCoordinator<Int> = self.makeCoordinator(clock: clock)
        let deadline = clock.now().advanced(by: .seconds(30))

        let leader = Task {
            await coordinator.value(
                for: "usage:",
                fingerprint: "config-a",
                deadline: deadline,
                timeoutValue: -1)
            {
                await gate.run(1)
            }
        }
        await gate.waitForStarts(1)
        await clock.waitForPendingSleeps(1)
        let follower = Task {
            await coordinator.value(
                for: "usage:",
                fingerprint: "config-a",
                deadline: deadline.advanced(by: .seconds(1)),
                timeoutValue: -2)
            {
                await gate.run(2)
            }
        }
        await self.waitForWaiterCount(2, coordinator: coordinator)
        follower.cancel()
        #expect(await follower.value == -2)
        await self.waitForWaiterCount(1, coordinator: coordinator)
        #expect(await coordinator.snapshot().operationCount == 1)

        leader.cancel()
        #expect(await leader.value == -1)
        await clock.waitForCancellations(1)
        let retained = await coordinator.snapshot()
        #expect(retained.operationCount == 1)
        #expect(retained.waiterCount == 0)
        #expect(retained.timerCount == 0)

        await gate.releaseAll()
        await gate.waitForActive(0)
        await self.waitForOperationCount(0, coordinator: coordinator)
    }

    @Test
    func `source completion cancels the operation timer`() async {
        let clock = ServeManualDeadlineClock()
        let gate = ServeFetchGate<Int>()
        let coordinator: CLIServeOperationCoordinator<Int> = self.makeCoordinator(clock: clock)

        let result = Task {
            await coordinator.value(
                for: "usage:",
                fingerprint: "config-a",
                deadline: clock.now().advanced(by: .seconds(30)),
                timeoutValue: -1)
            {
                await gate.run(7)
            }
        }
        await gate.waitForStarts(1)
        await clock.waitForPendingSleeps(1)
        await gate.releaseAll()

        #expect(await result.value == 7)
        await clock.waitForCancellations(1)
        #expect(await clock.pendingSleepCount() == 0)
        #expect(await coordinator.snapshot() == .init(
            operationCount: 0,
            waiterCount: 0,
            timerCount: 0,
            isShutDown: false))
    }

    @Test
    func `accepted value stays owned through asynchronous commit`() async {
        let source = ServeFetchGate<Int>()
        let commit = ServeFetchGate<Int>()
        let coordinator = CLIServeOperationCoordinator<Int>()
        await source.releaseAll()

        let first = Task {
            await coordinator.value(
                for: "usage:",
                fingerprint: "config-a",
                deadline: nil,
                timeoutValue: -1,
                accept: { await commit.run($0) },
                operation: { await source.run(1) })
        }
        await commit.waitForStarts(1)
        let follower = Task {
            await coordinator.value(
                for: "usage:",
                fingerprint: "config-a",
                deadline: nil,
                timeoutValue: -2,
                accept: { await commit.run($0) },
                operation: { await source.run(2) })
        }
        await self.waitForWaiterCount(2, coordinator: coordinator)

        #expect(await source.startCount() == 1)
        #expect(await coordinator.snapshot().operationCount == 1)
        await commit.releaseAll()
        #expect(await first.value == 1)
        #expect(await follower.value == 1)
        #expect(await source.startCount() == 1)
        await self.waitForOperationCount(0, coordinator: coordinator)
    }

    @Test
    func `earlier finite follower fails closed during accepted commit`() async {
        let source = ServeFetchGate<Int>()
        let commit = ServeFetchGate<Int>()
        let coordinator = CLIServeOperationCoordinator<Int>()
        let leaderDeadline = ContinuousClock().now.advanced(by: .seconds(30))
        await source.releaseAll()

        let leader = Task {
            await coordinator.value(
                for: "usage:",
                fingerprint: "config-a",
                deadline: leaderDeadline,
                timeoutValue: -1,
                accept: { await commit.run($0) },
                operation: { await source.run(1) })
        }
        await commit.waitForStarts(1)
        let follower = await coordinator.value(
            for: "usage:",
            fingerprint: "config-a",
            deadline: leaderDeadline.advanced(by: .seconds(-1)),
            timeoutValue: -2)
        {
            await source.run(2)
        }

        #expect(follower == -2)
        #expect(await source.startCount() == 1)
        let accepting = await coordinator.snapshot()
        #expect(accepting.waiterCount == 1)
        #expect(accepting.timerCount == 0)
        await commit.releaseAll()
        #expect(await leader.value == 1)
        await self.waitForOperationCount(0, coordinator: coordinator)
    }

    @Test
    func `config change queues a nonoverlapping successor without a deadline`() async {
        let gate = ServeFetchGate<Int>()
        let coordinator = CLIServeOperationCoordinator<Int>()

        let old = Task {
            await coordinator.value(
                for: "usage:",
                fingerprint: "config-a",
                deadline: nil,
                timeoutValue: -1)
            {
                await gate.run(1)
            }
        }
        await gate.waitForStarts(1)

        let successor = Task {
            await coordinator.value(
                for: "usage:",
                fingerprint: "config-b",
                deadline: nil,
                timeoutValue: -2)
            {
                await gate.run(2)
            }
        }
        await self.waitForOperationCount(2, coordinator: coordinator)
        #expect(await gate.startCount() == 1)
        #expect(await gate.peakCount() == 1)

        await gate.releaseAll()
        #expect(await old.value == 1)
        #expect(await successor.value == 2)
        await gate.waitForActive(0)
        await self.waitForOperationCount(0, coordinator: coordinator)
        #expect(await gate.startCount() == 2)
        #expect(await gate.peakCount() == 1)
    }

    @Test
    func `shutdown cancels owned work and rejects new operations`() async {
        let clock = ServeManualDeadlineClock()
        let gate = ServeFetchGate<Int>()
        let coordinator: CLIServeOperationCoordinator<Int> = self.makeCoordinator(clock: clock)

        let active = Task {
            await coordinator.value(
                for: "usage:",
                fingerprint: "config-a",
                deadline: clock.now().advanced(by: .seconds(30)),
                timeoutValue: -1)
            {
                await gate.run(1)
            }
        }
        await gate.waitForStarts(1)
        await clock.waitForPendingSleeps(1)
        await coordinator.shutdown()

        #expect(await active.value == -1)
        await clock.waitForCancellations(1)
        let rejected = await coordinator.value(
            for: "cost:",
            fingerprint: "config-a",
            deadline: nil,
            timeoutValue: -2)
        {
            2
        }
        #expect(rejected == -2)
        let retained = await coordinator.snapshot()
        #expect(retained.operationCount == 1)
        #expect(retained.isShutDown)

        await gate.releaseAll()
        await gate.waitForActive(0)
        await self.waitForOperationCount(0, coordinator: coordinator)
    }

    @Test
    func `provider timeout preserves healthy rows and cannot stack provider work`() async {
        let clock = ServeManualDeadlineClock()
        let blocked = ServeFetchGate<UsageCommandOutput>()
        let healthy = ServeFetchGate<UsageCommandOutput>()
        let operations: CLIServeOperationCoordinator<UsageCommandOutput> = self.makeCoordinator(clock: clock)
        let deadline = clock.now().advanced(by: .seconds(30))
        await healthy.releaseAll()

        let first = Task {
            await CodexBarCLI.serveCollectUsageOutputs(
                providers: [.claude, .gemini],
                configFingerprint: "config-a",
                deadline: deadline,
                operations: operations)
            { provider in
                if provider == .claude {
                    return await blocked.run(UsageCommandOutput(sections: ["late:claude"]))
                }
                return await healthy.run(UsageCommandOutput(sections: ["ok:gemini"]))
            }
        }
        await blocked.waitForStarts(1)
        await healthy.waitForStarts(1)
        await self.waitForOperationCount(1, coordinator: operations)
        await clock.waitForPendingSleeps(1)
        clock.advance(by: .seconds(30))
        await clock.fireAll()
        let firstOutput = await first.value
        #expect(firstOutput.sections == ["ok:gemini"])
        #expect(firstOutput.payload.count == 1)
        #expect(firstOutput.payload.first?.provider == UsageProvider.claude.rawValue)
        #expect(firstOutput.payload.first?.error?.kind == .provider)

        let second = Task {
            await CodexBarCLI.serveCollectUsageOutputs(
                providers: [.claude],
                configFingerprint: "config-a",
                deadline: deadline.advanced(by: .seconds(30)),
                operations: operations)
            { _ in
                await blocked.run(UsageCommandOutput(sections: ["overlap"]))
            }
        }
        await self.waitForOperationCount(2, coordinator: operations)
        await clock.waitForPendingSleeps(1)
        clock.advance(by: .seconds(30))
        await clock.fireAll()
        let secondOutput = await second.value
        #expect(secondOutput.payload.first?.error?.kind == .provider)
        #expect(await blocked.startCount() == 1)
        #expect(await blocked.peakCount() == 1)

        await blocked.releaseAll()
        await blocked.waitForActive(0)
        await self.waitForOperationCount(0, coordinator: operations)
    }

    @Test
    func `cost route variants cannot stack the same provider scan`() async {
        let clock = ServeManualDeadlineClock()
        let late = CodexBarCLI.makeCostPayload(provider: .claude, snapshot: nil, error: nil)
        let blocked = ServeFetchGate<CostPayload>()
        let operations: CLIServeOperationCoordinator<CostPayload> = self.makeCoordinator(clock: clock)
        let requestDeadline = clock.now().advanced(by: .seconds(40))
        let firstContext = ServeCostCollectionContext(
            configFingerprint: "config-a",
            providerTimeout: 30,
            requestDeadline: requestDeadline,
            now: { clock.now() },
            providerOperations: operations)

        let first = Task {
            await CodexBarCLI.serveCollectCostPayloads(
                providers: [.claude, .codex],
                context: firstContext)
            { provider in
                if provider == .claude {
                    return await blocked.run(late)
                }
                return CodexBarCLI.makeCostPayload(provider: provider, snapshot: nil, error: nil)
            }
        }
        await blocked.waitForStarts(1)
        await clock.waitForPendingSleeps(1)
        clock.advance(by: .seconds(30))
        await clock.fireAll()
        let firstPayload = await first.value

        #expect(firstPayload.map(\.provider) == ["claude", "codex"])
        #expect(firstPayload[0].error?.message == "claude cost refresh timed out")
        #expect(firstPayload[1].error == nil)

        let overlappingContext = ServeCostCollectionContext(
            configFingerprint: "config-a",
            providerTimeout: 30,
            requestDeadline: requestDeadline.advanced(by: .seconds(20)),
            now: { clock.now() },
            providerOperations: operations)
        let overlappingVariant = Task {
            await CodexBarCLI.serveCollectCostPayloads(
                providers: [.claude],
                context: overlappingContext)
            { _ in
                await blocked.run(late)
            }
        }
        await self.waitForOperationCount(2, coordinator: operations)
        await clock.waitForPendingSleeps(1)
        clock.advance(by: .seconds(30))
        await clock.fireAll()
        let secondPayload = await overlappingVariant.value

        #expect(secondPayload.first?.error?.message == "claude cost refresh timed out")
        #expect(await blocked.startCount() == 1)
        #expect(await blocked.peakCount() == 1)

        await blocked.releaseAll()
        await blocked.waitForActive(0)
        await self.waitForOperationCount(0, coordinator: operations)
    }

    private func makeCoordinator<Value: Sendable>(
        clock: ServeManualDeadlineClock) -> CLIServeOperationCoordinator<Value>
    {
        CLIServeOperationCoordinator(
            now: { clock.now() },
            sleepUntil: { deadline in try await clock.sleep(until: deadline) })
    }

    private func waitForOperationCount(
        _ expected: Int,
        coordinator: CLIServeOperationCoordinator<some Sendable>) async
    {
        for _ in 0..<1000 {
            if await coordinator.snapshot().operationCount == expected {
                return
            }
            await Task.yield()
        }
        Issue.record("operation count did not reach \(expected)")
    }

    private func waitForWaiterCount(
        _ expected: Int,
        coordinator: CLIServeOperationCoordinator<some Sendable>) async
    {
        for _ in 0..<1000 {
            if await coordinator.snapshot().waiterCount == expected {
                return
            }
            await Task.yield()
        }
        Issue.record("waiter count did not reach \(expected)")
    }
}

private actor ServeAcceptanceProbe<Value: Sendable> {
    private var calls = 0

    func accept(_ value: Value) -> Value {
        self.calls += 1
        return value
    }

    func callCount() -> Int {
        self.calls
    }
}

private actor ServeFetchGate<Value: Sendable> {
    private var starts = 0
    private var active = 0
    private var peak = 0
    private var released = false
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []
    private var startWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var activeWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func run(_ value: Value) async -> Value {
        self.starts += 1
        self.active += 1
        self.peak = max(self.peak, self.active)
        self.resumeStartWaiters()

        if !self.released {
            await withCheckedContinuation { continuation in
                self.releaseContinuations.append(continuation)
            }
        }
        self.active -= 1
        self.resumeActiveWaiters()
        return value
    }

    func waitForStarts(_ expected: Int) async {
        guard self.starts < expected else { return }
        await withCheckedContinuation { continuation in
            self.startWaiters.append((expected, continuation))
        }
    }

    func waitForActive(_ expected: Int) async {
        guard self.active != expected else { return }
        await withCheckedContinuation { continuation in
            self.activeWaiters.append((expected, continuation))
        }
    }

    func releaseAll() {
        self.released = true
        let continuations = self.releaseContinuations
        self.releaseContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    func startCount() -> Int {
        self.starts
    }

    func peakCount() -> Int {
        self.peak
    }

    private func resumeStartWaiters() {
        let ready = self.startWaiters.filter { self.starts >= $0.0 }
        self.startWaiters.removeAll { self.starts >= $0.0 }
        for (_, continuation) in ready {
            continuation.resume()
        }
    }

    private func resumeActiveWaiters() {
        let ready = self.activeWaiters.filter { self.active == $0.0 }
        self.activeWaiters.removeAll { self.active == $0.0 }
        for (_, continuation) in ready {
            continuation.resume()
        }
    }
}

private final class ServeManualDeadlineClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock().now
    private let sleeper = ServeManualSleeper()

    func now() -> ContinuousClock.Instant {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.instant
    }

    func advance(by duration: Duration) {
        self.lock.lock()
        self.instant = self.instant.advanced(by: duration)
        self.lock.unlock()
    }

    func sleep(until deadline: ContinuousClock.Instant) async throws {
        try await self.sleeper.sleep(until: deadline)
    }

    func waitForPendingSleeps(_ expected: Int) async {
        await self.sleeper.waitForPendingCount(expected)
    }

    func waitForCancellations(_ expected: Int) async {
        await self.sleeper.waitForCancellationCount(expected)
    }

    func pendingSleepCount() async -> Int {
        await self.sleeper.pendingCount()
    }

    func fireAll() async {
        await self.sleeper.fireAll()
    }
}

private actor ServeManualSleeper {
    private typealias SleepContinuation = CheckedContinuation<Void, any Error>

    private struct Pending {
        let id: UUID
        let continuation: SleepContinuation
    }

    private var pending: [Pending] = []
    private var cancellationCount = 0
    private var pendingWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var cancellationWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func sleep(until _: ContinuousClock.Instant) async throws {
        let id = UUID()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: SleepContinuation) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.pending.append(Pending(id: id, continuation: continuation))
                self.resumePendingWaiters()
            }
        }, onCancel: {
            Task { await self.cancel(id: id) }
        })
    }

    func waitForPendingCount(_ expected: Int) async {
        guard self.pending.count < expected else { return }
        await withCheckedContinuation { continuation in
            self.pendingWaiters.append((expected, continuation))
        }
    }

    func waitForCancellationCount(_ expected: Int) async {
        guard self.cancellationCount < expected else { return }
        await withCheckedContinuation { continuation in
            self.cancellationWaiters.append((expected, continuation))
        }
    }

    func pendingCount() -> Int {
        self.pending.count
    }

    func fireAll() {
        let pending = self.pending
        self.pending.removeAll()
        for item in pending {
            item.continuation.resume()
        }
    }

    private func cancel(id: UUID) {
        guard let index = self.pending.firstIndex(where: { $0.id == id }) else { return }
        let item = self.pending.remove(at: index)
        self.cancellationCount += 1
        item.continuation.resume(throwing: CancellationError())
        self.resumeCancellationWaiters()
    }

    private func resumePendingWaiters() {
        let ready = self.pendingWaiters.filter { self.pending.count >= $0.0 }
        self.pendingWaiters.removeAll { self.pending.count >= $0.0 }
        for (_, continuation) in ready {
            continuation.resume()
        }
    }

    private func resumeCancellationWaiters() {
        let ready = self.cancellationWaiters.filter { self.cancellationCount >= $0.0 }
        self.cancellationWaiters.removeAll { self.cancellationCount >= $0.0 }
        for (_, continuation) in ready {
            continuation.resume()
        }
    }
}
