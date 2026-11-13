import Foundation
import Testing
@testable import CodexBar

@MainActor
struct NotificationRemovalTests {
    @Test
    func `removal runs off the main thread with the requested identifiers`() async {
        let result: (onMain: Bool, identifiers: [String]) = await withCheckedContinuation { continuation in
            AppNotifications.scheduleRemoval(identifiers: ["codexbar-test-1"]) { identifiers in
                continuation.resume(returning: (Thread.isMainThread, identifiers))
            }
        }
        #expect(result.onMain == false)
        #expect(result.identifiers == ["codexbar-test-1"])
    }

    @Test
    func `a removal that never returns does not block the caller`() async {
        let queue = DispatchQueue(label: "codexbar.test.notification-removal")
        let release = DispatchSemaphore(value: 0)
        let completed = CompletedRemovals()

        // Stands in for usernotificationsd never replying to the synchronous XPC removal.
        await withCheckedContinuation { (started: CheckedContinuation<Void, Never>) in
            AppNotifications.scheduleRemoval(identifiers: ["stuck"], queue: queue) { identifiers in
                started.resume()
                _ = release.wait(timeout: .now() + 5)
                completed.append(identifiers)
            }
        }

        // An inline removal would have finished before scheduling returned.
        #expect(completed.snapshot.isEmpty)

        let order: [String] = await withCheckedContinuation { continuation in
            AppNotifications.scheduleRemoval(identifiers: ["next"], queue: queue) { identifiers in
                completed.append(identifiers)
                continuation.resume(returning: completed.snapshot)
            }
            release.signal()
        }
        #expect(order == ["stuck", "next"])
    }
}

private final class CompletedRemovals: @unchecked Sendable {
    private let lock = NSLock()
    private var identifiers: [String] = []

    var snapshot: [String] {
        self.lock.withLock { self.identifiers }
    }

    func append(_ newIdentifiers: [String]) {
        self.lock.withLock { self.identifiers.append(contentsOf: newIdentifiers) }
    }
}
