import Foundation
import Testing
@testable import CodexBarCore

struct CostUsageScanExecutorTests {
    @Test
    func `runs work on the dedicated scan queue and returns its value`() async throws {
        let queue = self.makeQueue()
        let label = try await CostUsageScanExecutor.run(on: queue) { _ in
            String(cString: __dispatch_queue_get_label(nil))
        }
        #expect(label == queue.label)
    }

    @Test
    func `propagates thrown errors`() async {
        struct ScanFailure: Error {}
        let queue = self.makeQueue()
        await #expect(throws: ScanFailure.self) {
            try await CostUsageScanExecutor.run(on: queue) { _ -> Int in
                throw ScanFailure()
            }
        }
    }

    @Test
    func `serializes overlapping scans`() async throws {
        let queue = self.makeQueue()
        let state = LockedValue((active: 0, maxActive: 0))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    try await CostUsageScanExecutor.run(on: queue) { _ in
                        state.update {
                            $0.active += 1
                            $0.maxActive = max($0.maxActive, $0.active)
                        }
                        Thread.sleep(forTimeInterval: 0.02)
                        state.update { $0.active -= 1 }
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(state.read { $0.maxActive } == 1)
    }

    @Test
    func `cancellation reaches in-flight work through checkCancellation`() async {
        let queue = self.makeQueue()
        let workStarted = LockedValue(false)
        let task = Task {
            try await CostUsageScanExecutor.run(on: queue) { checkCancellation in
                workStarted.set(true)
                while true {
                    try checkCancellation()
                    Thread.sleep(forTimeInterval: 0.005)
                }
            }
        }
        #expect(await self.waitUntil { workStarted.value })
        task.cancel()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    @Test
    func `work cancelled while queued resumes with CancellationError`() async {
        let queue = self.makeQueue()
        let blockerStarted = LockedValue(false)
        let releaseBlocker = LockedValue(false)
        let blocker = Task {
            try await CostUsageScanExecutor.run(on: queue) { _ in
                blockerStarted.set(true)
                while !releaseBlocker.value {
                    Thread.sleep(forTimeInterval: 0.002)
                }
            }
        }
        #expect(await self.waitUntil { blockerStarted.value })

        let queuedWorkStarted = LockedValue(false)
        let queued = Task {
            try await CostUsageScanExecutor.run(on: queue) { _ in
                queuedWorkStarted.set(true)
                Issue.record("queued work should not run after cancellation")
            }
        }
        try? await Task.sleep(for: .milliseconds(50))

        let cancellationObserved = LockedValue<Bool?>(nil)
        let observer = Task {
            do {
                try await queued.value
                cancellationObserved.set(false)
            } catch is CancellationError {
                cancellationObserved.set(true)
            } catch {
                cancellationObserved.set(false)
            }
        }
        queued.cancel()

        #expect(await self.waitUntil { cancellationObserved.value != nil })
        #expect(cancellationObserved.value == true)
        #expect(!queuedWorkStarted.value)
        #expect(!releaseBlocker.value)

        releaseBlocker.set(true)
        await observer.value
        _ = try? await blocker.value
    }

    private func makeQueue() -> DispatchQueue {
        DispatchQueue(label: "\(CostUsageScanExecutor.queueLabel).tests.\(UUID().uuidString)")
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @Sendable () -> Bool) async -> Bool
    {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }
}

private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        self.storage = value
    }

    var value: Value {
        self.lock.withLock { self.storage }
    }

    func read<Result>(_ body: (Value) -> Result) -> Result {
        self.lock.withLock { body(self.storage) }
    }

    func set(_ value: Value) {
        self.lock.withLock { self.storage = value }
    }

    func update(_ body: (inout Value) -> Void) {
        self.lock.withLock { body(&self.storage) }
    }
}
