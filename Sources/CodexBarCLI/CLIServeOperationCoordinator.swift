import Foundation

/// Owns at most one running source operation for each logical serve key.
///
/// Cancellation is advisory in Swift. Timed-out work therefore remains owned
/// until its source body actually exits. A config successor can wait behind it,
/// but can never overlap it.
actor CLIServeOperationCoordinator<Value: Sendable> {
    typealias Instant = ContinuousClock.Instant
    typealias Now = @Sendable () -> Instant
    typealias SleepUntil = @Sendable (Instant) async throws -> Void

    struct Snapshot: Equatable, Sendable {
        let operationCount: Int
        let waiterCount: Int
        let timerCount: Int
        let isShutDown: Bool
    }

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Value, Never>
        let timeoutValue: Value
    }

    private enum OperationPhase {
        case running
        case accepting
        case timedOut
    }

    private struct Operation {
        let generation: UInt64
        let fingerprint: String
        var deadline: Instant?
        let makeValue: @Sendable () async -> Value
        let acceptValue: @Sendable (Value) async -> Value
        var sourceTask: Task<Void, Never>?
        var deadlineTask: Task<Void, Never>?
        var waiters: [Waiter]
        var phase: OperationPhase
    }

    private struct Slot {
        var active: Operation?
        var pending: Operation?
    }

    private struct OperationRequest: Sendable {
        let key: String
        let fingerprint: String
        let deadline: Instant?
        let timeoutValue: Value
        let makeValue: @Sendable () async -> Value
        let acceptValue: @Sendable (Value) async -> Value
    }

    private enum WaitTarget {
        case active
        case pending
    }

    private let now: Now
    private let sleepUntil: SleepUntil
    // Callers validate route keys and provider keys come from UsageProvider, so
    // retained canceled work has a small, closed key space.
    private var slots: [String: Slot] = [:]
    private var nextGeneration: UInt64 = 0
    private var isShutDown = false

    init(
        now: @escaping Now = { ContinuousClock().now },
        sleepUntil: @escaping SleepUntil = { deadline in
            try await ContinuousClock().sleep(until: deadline)
        })
    {
        self.now = now
        self.sleepUntil = sleepUntil
    }

    func value(
        for key: String,
        fingerprint: String,
        deadline: Instant?,
        timeoutValue: Value,
        accept: @Sendable @escaping (Value) async -> Value = { $0 },
        operation makeValue: @Sendable @escaping () async -> Value) async -> Value
    {
        let request = OperationRequest(
            key: key,
            fingerprint: fingerprint,
            deadline: deadline,
            timeoutValue: timeoutValue,
            makeValue: makeValue,
            acceptValue: accept)
        guard !self.isShutDown, !self.isExpired(deadline) else { return timeoutValue }

        self.expireOverdueOperations(for: key)
        guard let slot = self.slots[key], let active = slot.active else {
            return await self.installActive(request)
        }

        if active.fingerprint == fingerprint, active.phase != .timedOut {
            guard self.deadlinesAreCompatible(active.deadline, deadline) else { return timeoutValue }
            guard self.canJoinAccepting(active, deadline: deadline) else { return timeoutValue }
            return await self.awaitValue(for: request, target: .active)
        }

        if let pending = slot.pending, pending.fingerprint == fingerprint {
            guard self.deadlinesAreCompatible(pending.deadline, deadline) else { return timeoutValue }
            return await self.awaitValue(for: request, target: .pending)
        }

        if let pending = self.slots[key]?.pending {
            self.timeoutPending(for: key, generation: pending.generation)
        }
        return await self.installPending(request)
    }

    func shutdown() {
        guard !self.isShutDown else { return }
        self.isShutDown = true

        let active = self.slots.compactMap { key, slot in
            slot.active.map { (key, $0.generation) }
        }
        let pending = self.slots.compactMap { key, slot in
            slot.pending.map { (key, $0.generation) }
        }
        for (key, generation) in pending {
            self.timeoutPending(for: key, generation: generation)
        }
        for (key, generation) in active {
            self.shutdownActive(for: key, generation: generation)
        }
    }

    func snapshot() -> Snapshot {
        let operations = self.slots.values.flatMap { slot in
            [slot.active, slot.pending].compactMap(\.self)
        }
        return Snapshot(
            operationCount: operations.count,
            waiterCount: operations.reduce(0) { $0 + $1.waiters.count },
            timerCount: operations.reduce(0) { $0 + ($1.deadlineTask == nil ? 0 : 1) },
            isShutDown: self.isShutDown)
    }

    private func allocateGeneration() -> UInt64 {
        self.nextGeneration &+= 1
        return self.nextGeneration
    }

    private func installActive(_ request: OperationRequest) async -> Value {
        let generation = self.allocateGeneration()
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled, !self.isShutDown, !self.isExpired(request.deadline) else {
                    continuation.resume(returning: request.timeoutValue)
                    return
                }

                var operation = self.makeOperation(
                    request,
                    generation: generation,
                    waiter: Waiter(
                        id: waiterID,
                        continuation: continuation,
                        timeoutValue: request.timeoutValue))
                operation.sourceTask = self.makeSourceTask(
                    key: request.key,
                    generation: generation,
                    makeValue: request.makeValue)
                operation.deadlineTask = self.makeDeadlineTask(
                    key: request.key,
                    generation: generation,
                    deadline: request.deadline)
                self.slots[request.key] = Slot(active: operation, pending: nil)
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: waiterID, for: request.key) }
        }
    }

    private func installPending(_ request: OperationRequest) async -> Value {
        guard self.slots[request.key]?.active != nil else {
            return await self.installActive(request)
        }

        let generation = self.allocateGeneration()
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled, !self.isShutDown, !self.isExpired(request.deadline) else {
                    continuation.resume(returning: request.timeoutValue)
                    return
                }
                guard var slot = self.slots[request.key], slot.active != nil else {
                    continuation.resume(returning: request.timeoutValue)
                    return
                }

                var operation = self.makeOperation(
                    request,
                    generation: generation,
                    waiter: Waiter(
                        id: waiterID,
                        continuation: continuation,
                        timeoutValue: request.timeoutValue))
                operation.deadlineTask = self.makeDeadlineTask(
                    key: request.key,
                    generation: generation,
                    deadline: request.deadline)
                slot.pending = operation
                self.slots[request.key] = slot
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: waiterID, for: request.key) }
        }
    }

    private func awaitValue(for request: OperationRequest, target: WaitTarget) async -> Value {
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled, !self.isShutDown, !self.isExpired(request.deadline),
                      var slot = self.slots[request.key]
                else {
                    continuation.resume(returning: request.timeoutValue)
                    return
                }

                let waiter = Waiter(
                    id: waiterID,
                    continuation: continuation,
                    timeoutValue: request.timeoutValue)
                switch target {
                case .active:
                    guard var operation = slot.active,
                          operation.fingerprint == request.fingerprint,
                          operation.phase != .timedOut
                    else {
                        continuation.resume(returning: request.timeoutValue)
                        return
                    }
                    guard self.canJoinAccepting(operation, deadline: request.deadline) else {
                        continuation.resume(returning: request.timeoutValue)
                        return
                    }
                    self.tightenDeadline(&operation, to: request.deadline, for: request.key)
                    operation.waiters.append(waiter)
                    slot.active = operation
                case .pending:
                    guard var operation = slot.pending,
                          operation.fingerprint == request.fingerprint
                    else {
                        continuation.resume(returning: request.timeoutValue)
                        return
                    }
                    self.tightenDeadline(&operation, to: request.deadline, for: request.key)
                    operation.waiters.append(waiter)
                    slot.pending = operation
                }
                self.slots[request.key] = slot
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: waiterID, for: request.key) }
        }
    }

    private func makeOperation(
        _ request: OperationRequest,
        generation: UInt64,
        waiter: Waiter) -> Operation
    {
        Operation(
            generation: generation,
            fingerprint: request.fingerprint,
            deadline: request.deadline,
            makeValue: request.makeValue,
            acceptValue: request.acceptValue,
            sourceTask: nil,
            deadlineTask: nil,
            waiters: [waiter],
            phase: .running)
    }

    private func makeSourceTask(
        key: String,
        generation: UInt64,
        makeValue: @Sendable @escaping () async -> Value) -> Task<Void, Never>
    {
        Task.detached { [self] in
            let value = await makeValue()
            await self.sourceProduced(value, for: key, generation: generation)
        }
    }

    private func makeDeadlineTask(
        key: String,
        generation: UInt64,
        deadline: Instant?) -> Task<Void, Never>?
    {
        guard let deadline else { return nil }
        let sleepUntil = self.sleepUntil
        return Task.detached { [self] in
            do {
                try await sleepUntil(deadline)
            } catch {
                return
            }
            await self.deadlineReached(for: key, generation: generation)
        }
    }

    private func cancelWaiter(id: UUID, for key: String) {
        guard var slot = self.slots[key] else { return }
        if var active = slot.active,
           let index = active.waiters.firstIndex(where: { $0.id == id })
        {
            let waiter = active.waiters.remove(at: index)
            slot.active = active
            self.slots[key] = slot
            waiter.continuation.resume(returning: waiter.timeoutValue)
            if active.waiters.isEmpty, active.phase == .running {
                self.timeoutActive(for: key, generation: active.generation)
            }
            return
        }

        guard var pending = slot.pending,
              let index = pending.waiters.firstIndex(where: { $0.id == id })
        else {
            return
        }
        let waiter = pending.waiters.remove(at: index)
        waiter.continuation.resume(returning: waiter.timeoutValue)
        if pending.waiters.isEmpty {
            pending.deadlineTask?.cancel()
            slot.pending = nil
        } else {
            slot.pending = pending
        }
        self.store(slot, for: key)
    }

    private func deadlineReached(for key: String, generation: UInt64) {
        if self.slots[key]?.active?.generation == generation {
            self.timeoutActive(for: key, generation: generation)
        } else if self.slots[key]?.pending?.generation == generation {
            self.timeoutPending(for: key, generation: generation)
        }
    }

    private func expireOverdueOperations(for key: String) {
        if let active = self.slots[key]?.active,
           active.phase == .running,
           self.isExpired(active.deadline)
        {
            self.timeoutActive(for: key, generation: active.generation)
        }
        if let pending = self.slots[key]?.pending,
           self.isExpired(pending.deadline)
        {
            self.timeoutPending(for: key, generation: pending.generation)
        }
    }

    private func timeoutActive(for key: String, generation: UInt64) {
        guard var slot = self.slots[key],
              var operation = slot.active,
              operation.generation == generation,
              operation.phase == .running
        else {
            return
        }

        operation.phase = .timedOut
        operation.sourceTask?.cancel()
        operation.deadlineTask?.cancel()
        operation.deadlineTask = nil
        let waiters = operation.waiters
        operation.waiters.removeAll()
        slot.active = operation
        self.slots[key] = slot

        for waiter in waiters {
            waiter.continuation.resume(returning: waiter.timeoutValue)
        }
    }

    private func shutdownActive(for key: String, generation: UInt64) {
        guard var slot = self.slots[key],
              var operation = slot.active,
              operation.generation == generation
        else {
            return
        }
        if operation.phase == .running {
            self.timeoutActive(for: key, generation: generation)
            return
        }
        guard operation.phase == .accepting else { return }

        operation.phase = .timedOut
        operation.sourceTask?.cancel()
        let waiters = operation.waiters
        operation.waiters.removeAll()
        slot.active = operation
        self.slots[key] = slot
        for waiter in waiters {
            waiter.continuation.resume(returning: waiter.timeoutValue)
        }
    }

    private func timeoutPending(for key: String, generation: UInt64) {
        guard var slot = self.slots[key],
              let operation = slot.pending,
              operation.generation == generation
        else {
            return
        }

        operation.deadlineTask?.cancel()
        slot.pending = nil
        self.store(slot, for: key)
        for waiter in operation.waiters {
            waiter.continuation.resume(returning: waiter.timeoutValue)
        }
    }

    private func sourceProduced(_ value: Value, for key: String, generation: UInt64) async {
        guard var slot = self.slots[key],
              let observed = slot.active,
              observed.generation == generation
        else {
            return
        }

        if observed.phase == .running, self.isExpired(observed.deadline) {
            self.timeoutActive(for: key, generation: generation)
            guard let refreshed = self.slots[key] else { return }
            slot = refreshed
        }
        guard var operation = slot.active, operation.generation == generation else { return }

        if operation.phase == .timedOut {
            slot.active = nil
            self.store(slot, for: key)
            self.promotePending(for: key)
            return
        }

        // Source completion wins the deadline only on this actor turn. `accept`
        // is restricted to bounded in-process projection/cache work: keep the
        // slot owned through that commit so a newer generation cannot start and
        // then be overwritten by this older result. Shutdown still releases the
        // waiters even if a commit is briefly queued on another actor.
        operation.phase = .accepting
        operation.deadlineTask?.cancel()
        operation.deadlineTask = nil
        slot.active = operation
        self.slots[key] = slot
        let acceptedValue = await operation.acceptValue(value)

        guard var refreshed = self.slots[key],
              let completed = refreshed.active,
              completed.generation == generation
        else {
            return
        }

        refreshed.active = nil
        self.store(refreshed, for: key)
        if completed.phase == .accepting {
            for waiter in completed.waiters {
                waiter.continuation.resume(returning: acceptedValue)
            }
        }
        self.promotePending(for: key)
    }

    private func promotePending(for key: String) {
        guard !self.isShutDown,
              var slot = self.slots[key],
              slot.active == nil,
              var pending = slot.pending
        else {
            return
        }
        if self.isExpired(pending.deadline) {
            self.timeoutPending(for: key, generation: pending.generation)
            return
        }

        pending.sourceTask = self.makeSourceTask(
            key: key,
            generation: pending.generation,
            makeValue: pending.makeValue)
        slot.active = pending
        slot.pending = nil
        self.slots[key] = slot
    }

    private func tightenDeadline(_ operation: inout Operation, to requested: Instant?, for key: String) {
        guard operation.phase == .running,
              let current = operation.deadline,
              let requested,
              requested < current
        else {
            return
        }
        operation.deadlineTask?.cancel()
        operation.deadline = requested
        operation.deadlineTask = self.makeDeadlineTask(
            key: key,
            generation: operation.generation,
            deadline: requested)
    }

    private func deadlinesAreCompatible(_ active: Instant?, _ requested: Instant?) -> Bool {
        (active == nil) == (requested == nil)
    }

    private func canJoinAccepting(_ operation: Operation, deadline: Instant?) -> Bool {
        guard operation.phase == .accepting,
              let activeDeadline = operation.deadline,
              let deadline
        else {
            return true
        }
        // Source acceptance already canceled the shared timer. An older-budget
        // follower cannot safely shorten that completed arbitration while the
        // bounded cache commit is in progress, so fail it closed.
        return deadline >= activeDeadline
    }

    private func isExpired(_ deadline: Instant?) -> Bool {
        guard let deadline else { return false }
        return deadline <= self.now()
    }

    private func store(_ slot: Slot, for key: String) {
        if slot.active == nil, slot.pending == nil {
            self.slots[key] = nil
        } else {
            self.slots[key] = slot
        }
    }
}
