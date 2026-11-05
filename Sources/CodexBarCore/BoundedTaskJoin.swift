import Foundation

package enum BoundedTaskJoinTiming {
    @TaskLocal package static var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
}

package enum BoundedTaskJoinOutcome<Value: Sendable> {
    case value(Value)
    case failure(any Error)
    case timedOut
}

package final class BoundedTaskJoin<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private let sourceTask: Task<Value, Error>
    private var outcome: BoundedTaskJoinOutcome<Value>?
    private var continuation: CheckedContinuation<BoundedTaskJoinOutcome<Value>, Never>?
    private var observerTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    package init(sourceTask: Task<Value, Error>) {
        self.sourceTask = sourceTask
    }

    package func value(joinGrace: Duration?) async -> BoundedTaskJoinOutcome<Value> {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.lock.lock()
                if let outcome = self.outcome {
                    self.lock.unlock()
                    continuation.resume(returning: outcome)
                    return
                }

                self.continuation = continuation
                let sourceTask = self.sourceTask
                self.observerTask = Task { [weak self] in
                    do {
                        let value = try await sourceTask.value
                        self?.resolve(.value(value), cancelSource: false)
                    } catch {
                        self?.resolve(.failure(error), cancelSource: false)
                    }
                }
                if let joinGrace {
                    self.timeoutTask = Task { [weak self] in
                        do {
                            if joinGrace > .zero {
                                try await BoundedTaskJoinTiming.sleep(joinGrace)
                            }
                            self?.resolve(.timedOut, cancelSource: true)
                        } catch {
                            // The source completed or the caller canceled the race.
                        }
                    }
                }
                self.lock.unlock()
            }
        } onCancel: {
            self.resolve(.failure(CancellationError()), cancelSource: true)
        }
    }

    private func resolve(_ outcome: BoundedTaskJoinOutcome<Value>, cancelSource: Bool) {
        self.lock.lock()
        guard self.outcome == nil else {
            self.lock.unlock()
            return
        }

        self.outcome = outcome
        let continuation = self.continuation
        self.continuation = nil
        let observerTask = self.observerTask
        let timeoutTask = self.timeoutTask
        self.observerTask = nil
        self.timeoutTask = nil
        self.lock.unlock()

        // Cancellation handlers can block. Publish the result and request source
        // cancellation off the caller's thread, including before registration.
        continuation?.resume(returning: outcome)
        if cancelSource {
            let sourceTask = self.sourceTask
            DispatchQueue.global().async { sourceTask.cancel() }
        }
        observerTask?.cancel()
        timeoutTask?.cancel()
    }
}
