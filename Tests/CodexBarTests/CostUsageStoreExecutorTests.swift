import Dispatch
import Foundation
import Testing
@testable import CodexBarCore

#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

struct CostUsageStoreExecutorTests {
    @Test(.timeLimit(.minutes(2)))
    func `another database completes while a store is inside SQLite busy handling`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cost-executors-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let blocked = CostUsageStore(cacheRoot: root.appendingPathComponent("a"), busyTimeoutMilliseconds: 60000)
        let independent = CostUsageStore(cacheRoot: root.appendingPathComponent("b"))
        #expect(await blocked.configuration() != nil)
        #expect(await independent.configuration() != nil)

        var holder: OpaquePointer?
        try #require(sqlite3_open_v2(blocked.databaseURL.path, &holder, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
        defer { sqlite3_close_v2(holder) }
        try #require(sqlite3_exec(holder, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)
        let gate = StoreBusyGate()
        let writer = Task {
            await blocked.withDatabase(default: SQLITE_ERROR) { database in
                // Replace SQLite's sleeps with a controlled wait at the actual lock conflict.
                sqlite3_busy_handler(
                    database,
                    { context, _ in
                        let gate = Unmanaged<StoreBusyGate>.fromOpaque(context!).takeUnretainedValue()
                        gate.entered.signal()
                        let resumed = gate.resume.wait(timeout: .now() + .seconds(60)) == .success
                        gate.exited.increment()
                        return resumed ? 1 : 0
                    },
                    Unmanaged.passUnretained(gate).toOpaque())
                defer { sqlite3_busy_timeout(database, 60000) }
                return withExtendedLifetime(gate) {
                    let result = sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil)
                    if result == SQLITE_OK {
                        #expect(sqlite3_exec(database, "COMMIT", nil, nil, nil) == SQLITE_OK)
                    }
                    return result
                }
            }
        }
        let entered = await Self.wait(gate.entered)
        #expect(entered)
        let completed = DispatchSemaphore(value: 0)
        let reader = Task {
            let result = await independent.configuration()
            completed.signal()
            return result
        }
        let completedWhileBlocked = await Self.wait(completed)
        #expect(completedWhileBlocked)
        #expect(gate.exited.value == 0)
        // Always unblock and join both jobs, including on the old shared-executor failure path.
        #expect(sqlite3_exec(holder, "COMMIT", nil, nil, nil) == SQLITE_OK)
        gate.resume.signal()
        #expect(await writer.value == SQLITE_OK)
        #expect(await reader.value != nil)
        #expect(gate.exited.value == 1)
    }

    private static func wait(_ signal: DispatchSemaphore) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: signal.wait(timeout: .now() + .seconds(30)) == .success)
            }
        }
    }
}

extension CostUsageStoreExecutorTests {
    @Test
    func `case aliases follow the volume semantics before and after database creation`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cost-executor-case-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = CostUsageStore(cacheRoot: root.appendingPathComponent("Cache"))
        let second = CostUsageStore(cacheRoot: root.appendingPathComponent("cache"))
        let volume = try root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        let caseSensitive = try #require(volume.volumeSupportsCaseSensitiveNames as Bool?)
        let sameExecutor = ObjectIdentifier(first.executorForTesting) == ObjectIdentifier(second.executorForTesting)
        #expect(sameExecutor == !caseSensitive)
        #expect(await first.configuration() != nil)
        #expect(await second.configuration() != nil)
        let reopened = CostUsageStore(cacheRoot: root.appendingPathComponent("cache"))
        #expect(ObjectIdentifier(reopened.executorForTesting) == ObjectIdentifier(second.executorForTesting))
    }

    @Test(arguments: [false, true], [false, true])
    func `database file links preserve target identity before and after creation`(
        _ alreadyExists: Bool,
        _ uppercaseTarget: Bool) async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cost-executor-file-alias-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let original = CostUsageStore(cacheRoot: root.appendingPathComponent("real"))
        if alreadyExists { #expect(await original.configuration() != nil) }
        let aliasRoot = root.appendingPathComponent("alias")
        let aliasDirectory = aliasRoot.appendingPathComponent("cost-usage")
        try FileManager.default.createDirectory(at: aliasDirectory, withIntermediateDirectories: true)
        let volume = try root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        let caseSensitive = try #require(volume.volumeSupportsCaseSensitiveNames as Bool?)
        let targetName = uppercaseTarget ? CostUsageStore.databaseFilename.uppercased() : CostUsageStore
            .databaseFilename
        try FileManager.default.createSymbolicLink(
            atPath: aliasDirectory.appendingPathComponent(CostUsageStore.databaseFilename).path,
            withDestinationPath: "../../real/cost-usage/\(targetName)")
        let alias = CostUsageStore(cacheRoot: aliasRoot)
        let sameExecutor = ObjectIdentifier(alias.executorForTesting) == ObjectIdentifier(original.executorForTesting)
        #expect(sameExecutor == (!uppercaseTarget || !caseSensitive))
        #expect(await alias.configuration() != nil)
        #expect(await original.configuration() != nil)
        #expect(ObjectIdentifier(CostUsageStore(cacheRoot: aliasRoot).executorForTesting)
            == ObjectIdentifier(alias.executorForTesting))
    }

    @Test
    func `concurrent aliases share an executor before and after the database exists`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cost-executor-aliases-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("real")
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createDirectory(
            at: real.appendingPathComponent("child"),
            withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
        let aliases: [URL] = {
            var paths = [real, alias, alias.appendingPathComponent("child/.."), real.resolvingSymlinksInPath()]
            #if canImport(Darwin)
            if real.path.hasPrefix("/private/var/") {
                paths.append(URL(fileURLWithPath: String(real.path.dropFirst("/private".count))))
            } else if real.path.hasPrefix("/var/") {
                paths.append(URL(fileURLWithPath: "/private" + real.path))
            }
            #endif
            return paths
        }()
        let stores = await withTaskGroup(of: CostUsageStore.self) { group in
            for index in 0..<64 {
                group.addTask { CostUsageStore(cacheRoot: aliases[index % aliases.count]) }
            }
            var stores: [CostUsageStore] = []
            for await store in group {
                stores.append(store)
            }
            return stores
        }
        let first = try #require(stores.first)
        #expect(!FileManager.default.fileExists(atPath: first.databaseURL.path))
        for store in stores {
            #expect(ObjectIdentifier(store.executorForTesting) == ObjectIdentifier(first.executorForTesting))
        }
        #expect(await first.configuration() != nil)
        for path in aliases {
            let reopened = CostUsageStore(cacheRoot: path)
            #expect(ObjectIdentifier(reopened.executorForTesting) == ObjectIdentifier(first.executorForTesting))
            #expect(await reopened.configuration() != nil)
            #expect(await reopened.rebuildCount == 0)
        }
        let other = CostUsageStore(cacheRoot: root.appendingPathComponent("other"))
        #expect(ObjectIdentifier(other.executorForTesting) != ObjectIdentifier(first.executorForTesting))
    }

    @Test
    func `registry releases executors after their last store is released`() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cost-executor-lifetime-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func makeReference() -> WeakExecutorReference {
            let store = CostUsageStore(cacheRoot: root)
            return WeakExecutorReference(value: store.executorForTesting)
        }
        let reference = makeReference()
        #expect(reference.value == nil)
        let replacement = CostUsageStore(cacheRoot: root)
        let second = CostUsageStore(cacheRoot: root)
        #expect(ObjectIdentifier(replacement.executorForTesting) == ObjectIdentifier(second.executorForTesting))
    }
}

private struct WeakExecutorReference {
    weak var value: AnyObject?
}

private final class StoreBusyGate: Sendable {
    let entered = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)
    let exited = CostUsageTestCounter()
}
