import Foundation
import Testing
@testable import CodexBarCore

/// The source discriminator and the OpenCode adapter checkpoint must round-trip through
/// the existing store without disturbing native Codex records — the structural seam the
/// #4752 checkpoint asked for. A legacy payload (no `source` key) must keep decoding as
/// native Codex so existing stores upgrade without a table rebuild.
struct OpenCodeSourceCheckpointTests {
    @Test
    func `in memory OpenCode selection never resolves to a disk source`() {
        #expect(OpenCodeLocalHistoryAdapter.resolvedDatabaseURL(
            homeDirectory: URL(fileURLWithPath: "/synthetic"),
            environment: ["OPENCODE_DB": ":memory:"]) == nil)
    }

    @Test
    func `legacy scan state without a source decodes as native codex`() throws {
        // Written by any build before the source seam: no `source` key at all.
        let legacyJSON = Data(#"{"isComplete":true,"targetSize":1200}"#.utf8)
        let decoded = try JSONDecoder().decode(
            CostUsageStoreScanState.self,
            from: legacyJSON)
        #expect(decoded.source == nil)
        #expect(decoded.resolvedSource == .nativeCodexSessionLogs)
        #expect(decoded.isComplete)
        #expect(decoded.targetSize == 1200)
    }

    @Test
    func `source discriminator round trips through scan state json`() throws {
        var state = CostUsageStoreScanState(isComplete: true)
        #expect(state.resolvedSource == .nativeCodexSessionLogs)

        state.source = .opencodeLocalHistory
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(
            CostUsageStoreScanState.self,
            from: data)
        #expect(decoded.source == .opencodeLocalHistory)
        #expect(decoded.resolvedSource == .opencodeLocalHistory)
    }

    @Test
    func `open code checkpoint encodes decodes and rejects newer versions`() throws {
        let fingerprint = OpenCodeSourceCheckpoint.Fingerprint(
            path: "/data/opencode.db",
            size: 4096,
            modifiedUnixMs: 1_772_798_400_000,
            walSize: 1024,
            walModifiedUnixMs: 1_772_798_500_000)
        var checkpoint = OpenCodeSourceCheckpoint.fresh(
            sourcePath: "/data/opencode.db",
            fingerprint: fingerprint)
        checkpoint.phase = .reconciliation
        checkpoint.position = .init(
            timestamp: 1_772_798_100_000,
            rowID: 42)
        checkpoint.pendingParentCheck = .init(
            rowIndex: 33,
            parentID: "parent")
        let data = try JSONEncoder().encode(checkpoint)
        let decoded = try #require(OpenCodeSourceCheckpoint.decode(data))
        #expect(decoded == checkpoint)
        #expect(decoded.position.rowID == 42)
        #expect(decoded.pendingParentCheck?.rowIndex == 33)

        // A checkpoint written by a newer build is never mistaken for progress this build
        // can trust (the adapter simply starts a fresh, honest pass).
        var future = checkpoint
        future.version = OpenCodeSourceCheckpoint.currentVersion + 1
        #expect(try OpenCodeSourceCheckpoint.decode(JSONEncoder().encode(future)) == nil)
        // Absent payload (e.g. a native Codex record's JSONL resume state shape) never
        // decodes as adapter progress.
        #expect(OpenCodeSourceCheckpoint.decode(nil) == nil)
    }

    @Test
    func `discriminated file survives a store round trip`() async throws {
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "OpenCodeSourceCheckpointTests-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: cacheRoot,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cacheRoot) }

        let checkpoint = OpenCodeSourceCheckpoint.fresh(
            sourcePath: "/data/opencode.db",
            fingerprint: .init(
                path: "/data/opencode.db",
                size: 4096,
                modifiedUnixMs: 1,
                walSize: nil,
                walModifiedUnixMs: nil))
        let checkpointPayload = try JSONEncoder().encode(checkpoint)

        let store = CostUsageStore(cacheRoot: cacheRoot)
        let nativeFile = CostUsageStoreFile(
            path: "/codex/sessions/a.jsonl",
            inode: 1,
            mtimeUnixMs: 1,
            size: 100,
            parsedBytes: 100,
            anchor: nil,
            scanState: CostUsageStoreScanState(
                source: nil,
                targetSize: 100,
                isComplete: true),
            sessionID: "a",
            coverageSinceDay: "2026-01-01",
            coverageUntilDay: "2026-01-01",
            updatedAtUnixMs: 1)
        var openCodeState = CostUsageStoreScanState(isComplete: true)
        openCodeState.source = .opencodeLocalHistory
        openCodeState.resumePayload = checkpointPayload
        let openCodeFile = CostUsageStoreFile(
            path: "/data/opencode.db",
            inode: 2,
            mtimeUnixMs: 2,
            size: 4096,
            parsedBytes: nil,
            anchor: nil,
            scanState: openCodeState,
            sessionID: nil,
            coverageSinceDay: nil,
            coverageUntilDay: nil,
            updatedAtUnixMs: 2)

        #expect(await store.upsertFile(nativeFile))
        #expect(await store.upsertFile(openCodeFile))

        let snapshot = await store.readSnapshot()
        let storedNative = snapshot.files.first { $0.path == nativeFile.path }
        let storedOpenCode = snapshot.files.first { $0.path == openCodeFile.path }

        #expect(storedNative?.belongsToOpenCodeLocalHistory == false)
        #expect(storedNative?.scanState.resolvedSource == .nativeCodexSessionLogs)
        #expect(storedOpenCode?.belongsToOpenCodeLocalHistory == true)

        // The adapter checkpoint travels the store payload intact; the native record's
        // JSONL-oriented fields are untouched.
        let restoredCheckpoint = try #require(
            OpenCodeSourceCheckpoint.decode(storedOpenCode?.scanState.resumePayload))
        #expect(restoredCheckpoint.sourcePath == "/data/opencode.db")
        #expect(storedOpenCode?.scanState.resumePayload == checkpointPayload)
    }
}
