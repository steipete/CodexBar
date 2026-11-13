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
        let started = DispatchSemaphore(value: 0)

        // Stands in for usernotificationsd never replying to the synchronous XPC removal.
        AppNotifications.scheduleRemoval(identifiers: ["stuck"], queue: queue) { _ in
            started.signal()
            release.wait()
        }

        // Reaching this line on the main actor proves scheduling returned while the removal is still blocked.
        let removalStarted = await Task.detached { started.wait(timeout: .now() + 5) == .success }.value
        #expect(removalStarted)

        let order: [String] = await withCheckedContinuation { continuation in
            AppNotifications.scheduleRemoval(identifiers: ["next"], queue: queue) { identifiers in
                continuation.resume(returning: identifiers)
            }
            release.signal()
        }
        #expect(order == ["next"])
    }
}
