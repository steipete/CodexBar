import Foundation

extension UsageStore {
    private nonisolated static let probeTimeoutQueue = DispatchQueue(
        label: "com.steipete.codexbar.probe-timeouts",
        qos: .userInitiated)

    private final class ProbeTimeoutRace: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<String, Never>?
        private var result: String?
        private var cancellations: [() -> Void] = []

        func install(_ continuation: CheckedContinuation<String, Never>) {
            let result: String? = self.lock.withLock {
                if let result = self.result {
                    return result
                }
                self.continuation = continuation
                return nil
            }
            if let result {
                continuation.resume(returning: result)
            }
        }

        func install(_ task: Task<Void, Never>) {
            self.installCancellation {
                task.cancel()
            }
        }

        func install(_ workItem: DispatchWorkItem) {
            self.installCancellation {
                workItem.cancel()
            }
        }

        private func installCancellation(_ cancellation: @escaping () -> Void) {
            let shouldCancel = self.lock.withLock {
                guard self.result == nil else { return true }
                self.cancellations.append(cancellation)
                return false
            }
            if shouldCancel {
                cancellation()
            }
        }

        func complete(with result: String) {
            let completion = self.lock.withLock {
                guard self.result == nil else {
                    return (nil as CheckedContinuation<String, Never>?, [] as [() -> Void])
                }
                self.result = result
                let continuation = self.continuation
                self.continuation = nil
                let cancellations = self.cancellations
                self.cancellations.removeAll()
                return (continuation, cancellations)
            }
            completion.1.forEach { $0() }
            completion.0?.resume(returning: result)
        }
    }

    nonisolated static func runWithTimeout(
        seconds: Double,
        operation: @escaping @Sendable () async -> String) async -> String
    {
        let timeoutMessage = "Probe timed out after \(Int(seconds))s"
        let race = ProbeTimeoutRace()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                race.install(continuation)

                race.install(Task {
                    let result = await operation()
                    race.complete(with: result)
                })

                // A Swift task-based timer can be delayed when the cooperative pool is
                // saturated by blocking probes. Dispatch keeps the timeout wall-clock bounded.
                let timeoutWorkItem = DispatchWorkItem {
                    race.complete(with: timeoutMessage)
                }
                race.install(timeoutWorkItem)
                Self.probeTimeoutQueue.asyncAfter(
                    deadline: .now() + max(seconds, 0),
                    execute: timeoutWorkItem)
            }
        } onCancel: {
            race.complete(with: timeoutMessage)
        }
    }
}
