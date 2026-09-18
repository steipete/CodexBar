import Foundation

/// FIFO ownership shared by asynchronous operations; each resource keeps its own gate instance.
actor AsyncOperationGate {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var ownerID: UUID?
    private var waiters: [Waiter] = []

    func acquire(id: UUID, rejectIfCancelled: Bool = true) async -> Bool {
        if rejectIfCancelled, Task.isCancelled {
            return false
        }
        guard self.ownerID != nil else {
            self.ownerID = id
            return true
        }
        return await withCheckedContinuation { continuation in
            self.waiters.append(Waiter(id: id, continuation: continuation))
        }
    }

    func cancel(id: UUID) {
        if self.ownerID == id {
            return
        }
        guard let index = self.waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = self.waiters.remove(at: index)
        waiter.continuation.resume(returning: false)
    }

    func release(id: UUID) {
        guard self.ownerID == id else { return }
        guard !self.waiters.isEmpty else {
            self.ownerID = nil
            return
        }
        let waiter = self.waiters.removeFirst()
        self.ownerID = waiter.id
        waiter.continuation.resume(returning: true)
    }
}
