import CodexBarCore
import Foundation
import Testing
@testable import CodexBarCLI

struct PreferencesQueueTransactionTests {
    @Test
    func `preferences import cannot overwrite an acknowledged host add`() throws {
        try self.withFixture { defaults, lockURL in
            var portable = PreferencesDocument()
            try portable.set("hidePersonalInfo", true)
            let incoming = portable
            let writer = ConcurrentQueueWriter {
                try incoming.queueImport(in: defaults, lockURL: lockURL)
            }
            try PreferencesDocument.withImportLock(in: defaults, lockURL: lockURL) {
                // A preference import arriving after the host read must merge the host write.
                let added = try CodexBarCLI.addedConfigHost(
                    "mini", to: CodexBarCLI.configHostsState(in: defaults), cost: true)
                writer.startAndExpectBlocked()
                try CodexBarCLI.queueConfigHosts(added.state, in: defaults, lockURL: lockURL)
            }
            try writer.finish()
            #expect(try CodexBarCLI.configHostsState(in: defaults).manualHosts == ["devbox", "mini"])
            let pending = try PreferencesDocument(
                queueData: #require(defaults.data(forKey: PreferencesDocument.pendingImportKey)))
            #expect(try pending.value("hidePersonalInfo", as: Bool.self) == true)
        }
    }

    @Test
    func `app consume cannot delete a concurrently acknowledged host add`() throws {
        try self.withFixture { defaults, lockURL in
            try CodexBarCLI.queueConfigHosts(
                ConfigHostsState(manualHosts: ["devbox", "buildbox"], costUsageHosts: ["buildbox"]),
                in: defaults,
                lockURL: lockURL)
            let writer = self.hostWriter(defaults, lockURL: lockURL)
            try PreferencesDocument.consumePendingImport(in: defaults, lockURL: lockURL) { document in
                writer.startAndExpectBlocked()
                try defaults.set(
                    document.value("agentSessionsManualHosts", as: String.self),
                    forKey: "agentSessionsManualHosts")
                try defaults.set(document.value("costUsageHosts", as: [String].self), forKey: "costUsageHosts")
            }
            try writer.finish()
            // The add reads consumed defaults and leaves its newer queue for the next consume.
            #expect(defaults.data(forKey: PreferencesDocument.pendingImportKey) != nil)
            let state = try CodexBarCLI.configHostsState(in: defaults)
            #expect(state.manualHosts == ["devbox", "buildbox", "mini"])
            #expect(state.costUsageHosts == ["buildbox", "mini"])
        }
    }

    private func hostWriter(_ defaults: InMemoryUserDefaults, lockURL: URL) -> ConcurrentQueueWriter {
        ConcurrentQueueWriter {
            _ = try CodexBarCLI.configHostsMutation(.add, host: "mini", cost: true, in: defaults, lockURL: lockURL)
        }
    }

    private func withFixture(_ operation: (InMemoryUserDefaults, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = InMemoryUserDefaults(values: ["agentSessionsManualHosts": "devbox"])
        try operation(defaults, root.appendingPathComponent("queue.lock"))
    }
}

/// Dispatch, rather than a child Task, exercises real contention without inheriting reentrant TaskLocal state.
private final class ConcurrentQueueWriter: @unchecked Sendable {
    private let started = DispatchSemaphore(value: 0)
    private let finished = DispatchSemaphore(value: 0)
    private let operation: () throws -> Void
    private var result: Result<Void, Error>?

    init(operation: @escaping () throws -> Void) {
        self.operation = operation
    }

    func startAndExpectBlocked() {
        DispatchQueue.global().async {
            self.result = Result {
                self.started.signal()
                try self.operation()
            }
            self.finished.signal()
        }
        #expect(self.started.wait(timeout: .now() + 3) == .success)
        // Retry after dispatch to give an unlocked writer repeated opportunities to finish.
        for _ in 0..<3 {
            #expect(self.finished.wait(timeout: .now() + 0.05) == .timedOut)
        }
    }

    func finish() throws {
        try #require(self.finished.wait(timeout: .now() + 3) == .success)
        try #require(self.result).get()
    }
}
