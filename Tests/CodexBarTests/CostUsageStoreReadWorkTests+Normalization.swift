import Foundation
import Testing
@testable import CodexBarCore

extension CostUsageStoreReadWorkTests {
    @Test
    func `unchanged saves normalize incoming scan completion without copying the decoded baseline`() throws {
        for completion in [nil, true] as [Bool?] {
            let fixture = try ReadWorkFixture(fileCount: 2, rowsPerFile: 4)
            defer { fixture.remove() }
            let loaded = fixture.store.syncLoadCodexScan(calendar: fixture.calendar)
            defer { loaded.release() }
            #expect(loaded.cache.files.values.allSatisfy { $0.codexScanComplete == true })
            var incoming = loaded.cache
            incoming.lastScanUnixMs += 1000
            for path in incoming.files.keys {
                incoming.files[path]?.codexScanComplete = completion
            }
            let normalizations = CostUsageTestCounter()
            var hooks = CostUsageStoreTestHooks.current
            hooks.codexScanCompleteNormalizationVisit = { normalizations.increment() }
            let result = CostUsageStoreTestHooks.$current.withValue(hooks) {
                fixture.save(incoming, load: loaded)
            }
            #expect(!result.catchUpRequired)
            // One incoming normalization per file for each optimistic and locked comparison.
            #expect(normalizations.value == fixture.fileCount * 2)
            var expected = fixture.canonical
            expected.lastScanUnixMs = incoming.lastScanUnixMs
            #expect(fixture.store.syncLoadCodexCache(calendar: fixture.calendar) == expected)
        }
    }

    @Test
    func `unchanged saves still reject an archive transition before the writer lock`() async throws {
        let fixture = try ReadWorkFixture(fileCount: 2, rowsPerFile: 4)
        defer { fixture.remove() }
        let loaded = fixture.store.syncLoadCodexScan(calendar: fixture.calendar)
        defer { loaded.release() }
        let path = try #require(loaded.cache.files.keys.min())
        var incoming = loaded.cache
        incoming.lastScanUnixMs += 1000
        var hooks = CostUsageStoreTestHooks.current
        hooks.identicalContentPreLockCheckpoint = (fixture.store.databaseURL, {
            do {
                try Data("synthetic archive".utf8).write(to: URL(fileURLWithPath: path + ".zst"))
                try FileManager.default.removeItem(atPath: path)
            } catch {
                Issue.record(error)
            }
        })
        let result = CostUsageStoreTestHooks.$current.withValue(hooks) {
            fixture.save(incoming, load: loaded)
        }
        #expect(result.catchUpRequired)
        #expect(await fixture.store.fetchMetadata().lastScanUnixMs == fixture.canonical.lastScanUnixMs)
        #expect(await fixture.store.readSnapshot().files.count == fixture.fileCount)
    }
}
