import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CostUsageStoreWriteAmplificationTests {
    @Test(arguments: [2, 16], [false, true])
    func `refresh writes do not scale with unchanged retained files`(fileCount: Int, metadataOnly: Bool) async throws {
        let fixture = try ReadWorkFixture(fileCount: fileCount, rowsPerFile: 4)
        defer { fixture.remove() }
        var expected = fixture.canonical
        let changedPath = try #require(expected.files.keys.min())

        for cycle in 1...3 {
            let loaded = fixture.store.syncLoadCodexScan(calendar: fixture.calendar)
            defer { loaded.release() }
            var candidate = loaded.cache
            candidate.lastScanUnixMs += 1000
            expected.lastScanUnixMs = candidate.lastScanUnixMs
            if metadataOnly {
                candidate.codexProjectMetadataVersion = cycle + 100
                expected.codexProjectMetadataVersion = candidate.codexProjectMetadataVersion
            } else {
                candidate.files[changedPath]?.lastModel = "fixture-model-\(cycle)"
                expected.files[changedPath]?.lastModel = "fixture-model-\(cycle)"
            }
            let before = await fixture.store.persistenceWriteMetricsForTesting()
            let result = fixture.save(candidate, load: loaded)
            let after = await fixture.store.persistenceWriteMetricsForTesting()
            let writes = after.rows - before.rows
            #expect(!result.catchUpRequired)
            #expect(writes <= (metadataOnly ? 4 : 9))
            #expect(fixture.store.syncLoadCodexCache(calendar: fixture.calendar) == expected)
            print("[cost-write-amplification] files=\(fileCount) metadata_only=\(metadataOnly) " +
                "cycle=\(cycle) rows=\(writes) pages=\(after.pages - before.pages)")
        }
    }

    @Test(arguments: [2, 16])
    func `refresh writes do not scale with unchanged archived rollouts`(fileCount: Int) async throws {
        let fixture = try ReadWorkFixture(fileCount: fileCount, rowsPerFile: 4)
        defer { fixture.remove() }
        var expected = fixture.canonical
        let paths = expected.files.keys.sorted()
        let changedPath = try #require(paths.first)
        // Codex compresses finished rollouts in place: the `.jsonl` goes away and a `.jsonl.zst` sibling stays.
        for path in paths.dropFirst() {
            try FileManager.default.moveItem(atPath: path, toPath: path + ".zst")
            #expect(CostUsageScanner.isArchivedCodexRollout(path))
            expected.files[path]?.codexArchived = true
        }

        for cycle in 1...3 {
            let loaded = fixture.store.syncLoadCodexScan(calendar: fixture.calendar)
            defer { loaded.release() }
            var candidate = loaded.cache
            #expect(candidate.files.values.count(where: { $0.codexArchived == true }) == fileCount - 1)
            candidate.lastScanUnixMs += 1000
            expected.lastScanUnixMs = candidate.lastScanUnixMs
            candidate.files[changedPath]?.lastModel = "fixture-model-\(cycle)"
            expected.files[changedPath]?.lastModel = "fixture-model-\(cycle)"
            let before = await fixture.store.persistenceWriteMetricsForTesting()
            let result = fixture.save(candidate, load: loaded)
            let after = await fixture.store.persistenceWriteMetricsForTesting()
            let writes = after.rows - before.rows
            #expect(!result.catchUpRequired)
            #expect(writes <= 9)
            #expect(fixture.store.syncLoadCodexCache(calendar: fixture.calendar) == expected)
            print("[cost-write-amplification] archived files=\(fileCount) " +
                "cycle=\(cycle) rows=\(writes) pages=\(after.pages - before.pages)")
        }
    }

    @Test
    func `changed archived rollout still persists`() throws {
        let fixture = try ReadWorkFixture(fileCount: 2, rowsPerFile: 4)
        defer { fixture.remove() }
        var expected = fixture.canonical
        let archivedPath = try #require(expected.files.keys.max())
        try FileManager.default.moveItem(atPath: archivedPath, toPath: archivedPath + ".zst")
        expected.files[archivedPath]?.codexArchived = true

        let loaded = fixture.store.syncLoadCodexScan(calendar: fixture.calendar)
        defer { loaded.release() }
        var candidate = loaded.cache
        #expect(candidate.files[archivedPath]?.codexArchived == true)
        candidate.files[archivedPath]?.lastModel = "fixture-model-archived"
        expected.files[archivedPath]?.lastModel = "fixture-model-archived"
        #expect(!fixture.save(candidate, load: loaded).catchUpRequired)
        #expect(fixture.store.syncLoadCodexCache(calendar: fixture.calendar) == expected)
    }
}
