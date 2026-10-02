import Foundation
import Testing
@testable import CodexBarCore

struct CostUsageStoreHookIsolationTests {
    enum Route: CaseIterable, Sendable {
        case synchronous, actorCall, scanQueue
    }

    @Test(arguments: Route.allCases)
    func `overlapping hook scopes survive store and scan executor hops`(_ route: Route) async throws {
        let roots = (0..<2).map { _ in
            FileManager.default.temporaryDirectory.appendingPathComponent("cost-hook-\(UUID().uuidString)")
        }
        defer { roots.forEach { try? FileManager.default.removeItem(at: $0) } }
        let rendezvous = HookRendezvous()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for root in roots {
                group.addTask {
                    let store = CostUsageStore(cacheRoot: root)
                    let cache = CostUsageStoreCrashHarness.seededCache()
                    let calendar = CostUsageStoreCrashHarness.fixtureCalendar
                    let window = CostUsageStoreCrashHarness.scanWindow
                    let counter = CostUsageTestCounter()
                    var hooks = CostUsageStoreTestHooks.current
                    hooks.saveCycleCheckpoint = { _ in counter.increment() }
                    try await CostUsageStoreTestHooks.$current.withValue(hooks) {
                        // Both observers are installed before either test performs a store operation.
                        await rendezvous.arrive()
                        let saved: CostUsageStoreBudgetResult = switch route {
                        case .synchronous:
                            store.syncSaveCodexCache(cache, calendar: calendar, requestedScanWindow: window)
                        case .actorCall:
                            await store.saveCodexCache(cache, calendar: calendar, requestedScanWindow: window)
                        case .scanQueue:
                            try await CostUsageScanExecutor.run { _ in
                                store.syncSaveCodexCache(cache, calendar: calendar, requestedScanWindow: window)
                            }
                        }
                        #expect(!saved.catchUpRequired)
                    }
                    #expect(counter.value == cache.files.count)
                    _ = store.syncSaveCodexCache(cache, calendar: calendar, requestedScanWindow: window)
                    #expect(counter.value == cache.files.count)
                }
            }
            try await group.waitForAll()
        }
    }
}

extension CostUsageStoreHookIsolationTests {
    @Test
    func `overlapping read recorders keep their database ownership across executor hops`() async throws {
        let roots = (0..<2).map { _ in
            FileManager.default.temporaryDirectory.appendingPathComponent("cost-read-hook-\(UUID().uuidString)")
        }
        defer { roots.forEach { try? FileManager.default.removeItem(at: $0) } }
        let stores = roots.map { CostUsageStore(cacheRoot: $0) }
        let cache = CostUsageStoreCrashHarness.seededCache()
        let calendar = CostUsageStoreCrashHarness.fixtureCalendar
        for store in stores {
            _ = store.syncSaveCodexCache(
                cache, calendar: calendar, requestedScanWindow: CostUsageStoreCrashHarness.scanWindow)
        }
        let rendezvous = HookRendezvous()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (index, store) in stores.enumerated() {
                let other = stores[1 - index]
                group.addTask {
                    let recorder = CostUsageStoreReadWorkRecorder(databaseURL: store.databaseURL)
                    var hooks = CostUsageStoreTestHooks.current
                    hooks.readWorkRecorder = recorder
                    try await CostUsageStoreTestHooks.$current.withValue(hooks) {
                        await rendezvous.arrive()
                        #expect(await store.readSnapshot().files.count == cache.files.count)
                        #expect(recorder.snapshot().fullSnapshotReads == 1)
                        #expect(recorder.snapshot().fileRows == cache.files.count)
                        let loaded = try await CostUsageScanExecutor.run { _ in
                            store.syncLoadCodexCache(calendar: calendar)
                        }
                        #expect(loaded.files.count == cache.files.count)
                        let work = recorder.snapshot()
                        #expect(work.fullSnapshotReads == 2)
                        #expect(work.fileRows == cache.files.count * 2)
                        _ = await other.readSnapshot()
                        #expect(recorder.snapshot() == work)
                    }
                    let work = recorder.snapshot()
                    _ = await store.readSnapshot()
                    #expect(recorder.snapshot() == work)
                }
            }
            try await group.waitForAll()
        }
    }
}

private actor HookRendezvous {
    private var first: CheckedContinuation<Void, Never>?

    func arrive() async {
        await withCheckedContinuation { continuation in
            if let first = self.first {
                self.first = nil
                first.resume()
                continuation.resume()
            } else {
                self.first = continuation
            }
        }
    }
}

final class CostUsageTestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        self.lock.withLock { self.count }
    }

    func increment() {
        self.lock.withLock { self.count += 1 }
    }
}
