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
    func `stale delivery waits for removal before completing`() async throws {
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let delivery = Task { @MainActor in
            var current = true
            var removed = false
            let delivered = try await AppNotifications.deliverIfCurrent(
                authorize: { true },
                submit: { current = false },
                remove: {
                    started.continuation.yield(())
                    for await _ in release.stream {
                        break
                    }
                    removed = true
                },
                isCurrent: { current })
            return (delivered, removed)
        }
        for await _ in started.stream {
            break
        }
        release.continuation.yield(())
        let (delivered, removed) = try await delivery.value
        started.continuation.finish()
        release.continuation.finish()
        #expect(!delivered)
        #expect(removed)
    }
}
