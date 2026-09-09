import Foundation

package final class ProcessTermination: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32?
    private var continuation: CheckedContinuation<Int32, Never>?

    package init() {}

    package func resolve(_ status: Int32) {
        let continuation: CheckedContinuation<Int32, Never>?
        self.lock.lock()
        self.status = status
        continuation = self.continuation
        self.continuation = nil
        self.lock.unlock()
        continuation?.resume(returning: status)
    }

    package func wait() async -> Int32 {
        await withCheckedContinuation { continuation in
            let status: Int32?
            self.lock.lock()
            status = self.status
            if status == nil {
                self.continuation = continuation
            }
            self.lock.unlock()

            if let status {
                continuation.resume(returning: status)
            }
        }
    }
}
