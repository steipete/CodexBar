import Foundation
import Testing
@testable import CodexBarCore

struct CLIProxyAPIUsageCacheLockTests {
    @Test
    func `pruning waits for the custom root interprocess lock`() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cliproxy-pruning-lock-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        let timestamp = try #require(CostUsageDateParser.parse("2026-07-16T12:00:00Z"))
        let record = CLIProxyAPIUsageRecord(
            timestamp: timestamp,
            provider: "codex",
            model: "gpt-5.5",
            alias: "gpt-5.5",
            endpoint: "POST /v1/messages",
            authType: "oauth",
            requestID: "expired",
            tokens: .init(input: 10, output: 20, total: 30))
        #expect(CLIProxyAPIUsageCacheIO.merge(
            [record],
            cacheRoot: root,
            now: timestamp) == 1)
        let lockAcquired = DispatchSemaphore(value: 0)
        let releaseLock = DispatchSemaphore(value: 0)
        let loadStarted = DispatchSemaphore(value: 0)
        let loadFinished = DispatchSemaphore(value: 0)
        let lockHolder = Task.detached {
            try CostUsageCacheLocations.withCLIProxyAPIInterprocessLock(stateRoot: root) {
                lockAcquired.signal()
                releaseLock.wait()
            }
        }
        #expect(await Self.waitForSignal(lockAcquired, timeout: .now() + 1))

        let loadTask = Task.detached {
            loadStarted.signal()
            let records = CLIProxyAPIUsageCacheIO.load(
                cacheRoot: root,
                now: timestamp.addingTimeInterval(367 * 24 * 60 * 60))
            loadFinished.signal()
            return records
        }
        #expect(await Self.waitForSignal(loadStarted, timeout: .now() + 1))
        let loadFinishedBeforeRelease = await Self.waitForSignal(
            loadFinished,
            timeout: .now() + .milliseconds(50))
        #expect(!loadFinishedBeforeRelease)

        releaseLock.signal()
        try await lockHolder.value
        #expect(await loadTask.value.isEmpty)
    }

    private static func waitForSignal(
        _ semaphore: DispatchSemaphore,
        timeout: DispatchTime) async -> Bool
    {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: semaphore.wait(timeout: timeout) == .success)
            }
        }
    }
}
