import Foundation

/// Cost-usage scans read and parse the full local session corpus synchronously and can run for
/// minutes on large archives. Executing that work inline on Swift's cooperative thread pool
/// starves every other async task in the process — menus freeze while the main thread sits idle —
/// and overlapping provider scans multiply both the pool pressure and the disk load. This
/// executor pins all corpus scans to a single serial utility queue off the cooperative pool, so
/// long scans cost one dedicated thread instead of the app's async runtime.
public enum CostUsageScanExecutor {
    public static let queueLabel = "com.steipete.codexbar.cost-usage-scan"

    private static let queue = DispatchQueue(label: queueLabel, qos: .utility)

    private final class RunState<Value: Sendable>: @unchecked Sendable {
        private enum Phase {
            case initial
            case queued
            case running
            case completed
        }

        private let lock = NSLock()
        private var phase: Phase = .initial
        private var cancellationRequested = false
        private var continuation: CheckedContinuation<Value, Error>?

        func install(_ continuation: CheckedContinuation<Value, Error>) -> Bool {
            let shouldEnqueue: Bool
            let shouldResumeCancellation: Bool
            self.lock.lock()
            if self.cancellationRequested {
                self.phase = .completed
                shouldEnqueue = false
                shouldResumeCancellation = true
            } else {
                self.phase = .queued
                self.continuation = continuation
                shouldEnqueue = true
                shouldResumeCancellation = false
            }
            self.lock.unlock()

            if shouldResumeCancellation {
                continuation.resume(throwing: CancellationError())
            }
            return shouldEnqueue
        }

        func begin() -> Bool {
            self.lock.lock()
            defer { self.lock.unlock() }
            guard self.phase == .queued else { return false }
            self.phase = .running
            return true
        }

        func cancel() {
            let continuation: CheckedContinuation<Value, Error>?
            self.lock.lock()
            self.cancellationRequested = true
            if self.phase == .queued {
                self.phase = .completed
                continuation = self.continuation
                self.continuation = nil
            } else {
                continuation = nil
            }
            self.lock.unlock()
            continuation?.resume(throwing: CancellationError())
        }

        func checkCancellation() throws {
            self.lock.lock()
            let cancellationRequested = self.cancellationRequested
            self.lock.unlock()
            if cancellationRequested {
                throw CancellationError()
            }
        }

        func complete(with result: Result<Value, Error>) {
            let continuation: CheckedContinuation<Value, Error>?
            let resolvedResult: Result<Value, Error>
            self.lock.lock()
            guard self.phase == .running else {
                self.lock.unlock()
                return
            }
            self.phase = .completed
            continuation = self.continuation
            self.continuation = nil
            resolvedResult = self.cancellationRequested ? .failure(CancellationError()) : result
            self.lock.unlock()
            continuation?.resume(with: resolvedResult)
        }
    }

    /// Runs `work` on the serial scan queue and bridges Swift task cancellation into the
    /// scanner's cooperative `checkCancellation` callbacks. Work that is still queued when the
    /// awaiting task is cancelled resumes immediately with `CancellationError` instead of
    /// waiting behind an in-flight scan.
    public static func run<T: Sendable>(
        _ work: @escaping @Sendable (_ checkCancellation: @escaping @Sendable () throws -> Void) throws -> T)
        async throws -> T
    {
        try await self.run(on: self.queue, work)
    }

    static func run<T: Sendable>(
        on queue: DispatchQueue,
        _ work: @escaping @Sendable (_ checkCancellation: @escaping @Sendable () throws -> Void) throws -> T)
        async throws -> T
    {
        let state = RunState<T>()
        let checkCancellation: @Sendable () throws -> Void = {
            try state.checkCancellation()
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard state.install(continuation) else { return }
                queue.async {
                    guard state.begin() else { return }
                    state.complete(with: Result { try work(checkCancellation) })
                }
            }
        } onCancel: {
            state.cancel()
        }
    }
}
