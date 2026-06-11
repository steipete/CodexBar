import Foundation
#if canImport(os)
import os
#endif

#if canImport(SQLite3)
/// On-disk snapshot of the per-database priority-turns memos. The memo is what lets live
/// refreshes scan only rows appended since the last cursor; without persistence every app
/// launch and every CLI invocation pays one full trace-database scan (tens of seconds on
/// large `logs_2.sqlite` files) before incremental refreshes resume. The artifact follows
/// the cost-usage cache conventions: versioned filename, parser-hash producer key so stale
/// parsers fall back to a rescan, and atomic replace-on-write.
struct CodexPriorityTurnsMemoArtifact: Codable {
    var version: Int = 1
    var producerKey: String?
    var states: [String: CostUsageScanner.CodexPriorityTurnsMemoState]
}

enum CodexPriorityTurnsMemoIO {
    static let artifactVersion = 1

    static func artifactURL(cacheRoot: URL? = nil) -> URL {
        let root = cacheRoot
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("CodexBar", isDirectory: true)
        return root
            .appendingPathComponent("cost-usage", isDirectory: true)
            .appendingPathComponent(
                "codex-priority-turns-v\(self.artifactVersion).json",
                isDirectory: false)
    }

    static func currentProducerKey(parserHash: String = CodexParserHash.priorityTurns) -> String {
        "codex:pt:p\(parserHash)"
    }

    static func load(
        cacheRoot: URL? = nil,
        producerKey: String? = nil) -> [String: CostUsageScanner.CodexPriorityTurnsMemoState]?
    {
        let url = self.artifactURL(cacheRoot: cacheRoot)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let decoded = try? JSONDecoder().decode(CodexPriorityTurnsMemoArtifact.self, from: data)
        else { return nil }
        guard decoded.version == self.artifactVersion else { return nil }
        guard decoded.producerKey == (producerKey ?? self.currentProducerKey()) else { return nil }
        return decoded.states
    }

    static func save(
        states: [String: CostUsageScanner.CodexPriorityTurnsMemoState],
        cacheRoot: URL? = nil,
        producerKey: String? = nil)
    {
        let url = self.artifactURL(cacheRoot: cacheRoot)
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let artifact = CodexPriorityTurnsMemoArtifact(
            producerKey: producerKey ?? self.currentProducerKey(),
            states: states)
        guard let data = try? JSONEncoder().encode(artifact) else { return }

        let tmp = dir.appendingPathComponent(".tmp-\(UUID().uuidString).json", isDirectory: false)
        do {
            try data.write(to: tmp, options: [.atomic])
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
        }
    }
}

extension CostUsageScanner {
    private static let codexPriorityTurnsMemoDiskState =
        OSAllocatedUnfairLock<(loaded: Bool, dirty: Bool)>(initialState: (loaded: false, dirty: false))

    /// Seeds the in-process memo from the persisted artifact once per process, before the
    /// first priority-turns scan. Seeding goes through the monotonic store, so a scan that
    /// somehow completed first can never be regressed by older on-disk state.
    static func loadCodexPriorityTurnsMemoFromDiskIfNeeded(cacheRoot: URL? = nil) {
        let shouldLoad = self.codexPriorityTurnsMemoDiskState.withLock { state in
            if state.loaded { return false }
            state.loaded = true
            return true
        }
        guard shouldLoad, let persisted = CodexPriorityTurnsMemoIO.load(cacheRoot: cacheRoot)
        else { return }
        for (path, state) in persisted {
            self.storeCodexPriorityTurnsMemoIfNewer(state, forPath: path)
        }
        // Seeding marks the memo dirty through the store; the disk already holds this state.
        self.codexPriorityTurnsMemoDiskState.withLock { $0.dirty = false }
    }

    /// Persists the memo after a scan advanced it. Callers run on the cost-usage scan
    /// executor, so the synchronous write stays off the cooperative pool and the main actor.
    static func persistCodexPriorityTurnsMemoIfDirty(cacheRoot: URL? = nil) {
        let shouldPersist = self.codexPriorityTurnsMemoDiskState.withLock { state in
            if !state.dirty { return false }
            state.dirty = false
            return true
        }
        guard shouldPersist else { return }
        let snapshot = self.codexPriorityTurnsMemo.withLock { $0 }
        CodexPriorityTurnsMemoIO.save(states: snapshot, cacheRoot: cacheRoot)
    }

    static func markCodexPriorityTurnsMemoDirty() {
        self.codexPriorityTurnsMemoDiskState.withLock { $0.dirty = true }
    }

    static func _test_resetCodexPriorityTurnsMemoDiskState() {
        self.codexPriorityTurnsMemoDiskState.withLock { $0 = (loaded: false, dirty: false) }
    }
}
#else
extension CostUsageScanner {
    static func loadCodexPriorityTurnsMemoFromDiskIfNeeded(cacheRoot: URL? = nil) {}
    static func persistCodexPriorityTurnsMemoIfDirty(cacheRoot: URL? = nil) {}
}
#endif
