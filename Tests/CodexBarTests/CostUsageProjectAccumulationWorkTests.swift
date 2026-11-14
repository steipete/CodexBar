import Foundation
import Testing
@testable import CodexBarCore

struct CostUsageProjectAccumulationWorkTests {
    @Test
    func `project accumulation grows report storage without copying it for every session`() throws {
        let fileCount = 128
        let fixture = try CostUsageCodexReportPricingWorkTests.fixture(fileCount: fileCount, rowsPerFile: 4)
        let changes = CostUsageScanExecutor.LockedState(0)
        var hooks = CostUsageStoreTestHooks.current
        hooks.projectSourceReportStorageChanged = { changes.withLock { $0 += 1 } }
        let reports = CostUsageStoreTestHooks.$current.withValue(hooks) {
            CostUsageScanner.buildCodexReportProjectionsFromCache(
                cache: fixture.cache,
                range: fixture.range,
                modelsDevCatalog: ModelsDevCatalog(providers: [:]))
        }
        // Allow normal capacity growth; replacing nearly every buffer is quadratic copy-on-write.
        let replacements = changes.withLock { $0 }
        #expect(replacements < fileCount / 2)
        #expect(reports.daily.summary?.totalTokens == fileCount * 4 * 13)
        #expect(reports.projects.count == 1)
        #expect(reports.projects.first?.totalTokens == fileCount * 4 * 13)
        #expect(reports.projects.first?.sources.count == 1)
        #expect(reports.projects.first?.sources.first?.totalTokens == fileCount * 4 * 13)
        #expect(reports.sessions.count == fileCount)
        #expect(reports.sessions.allSatisfy { $0.totalTokens == 4 * 13 })
        print("[project-accumulation] files=\(fileCount) reportBufferReplacements=\(replacements)")
    }
}
