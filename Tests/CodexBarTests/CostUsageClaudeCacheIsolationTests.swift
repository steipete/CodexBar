import Foundation
import Testing
@testable import CodexBarCore

struct CostUsageClaudeCacheFixtures: TestTrait, SuiteTrait, TestScoping {
    var isRecursive: Bool {
        true
    }

    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void) async throws
    {
        try await CostUsageClaudeCacheIO.withIsolatedCachesForTesting(operation: function)
    }
}

@Suite(CostUsageClaudeCacheFixtures())
struct CostUsageClaudeCacheIsolationTests {
    private typealias Fixture = CostUsageClaudeWriteAmplificationTests.Fixture

    @Test
    func `isolated cache scopes retain warm entries across competing cache pressure`() async throws {
        let fixture = try Fixture(rowCount: 2)
        defer { fixture.env.cleanup() }
        let initial = try fixture.load(context: .regular)
        let cache = CostUsageClaudeCacheIO.load(provider: .claude, cacheRoot: fixture.env.cacheRoot)
        let before = try fixture.stamps(context: .regular)
        let reportMemo = CostUsageClaudeReportMemo.shared
        let fragments = CostUsageClaudeFragments.shared

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<2 {
                group.addTask {
                    #expect(CostUsageClaudeReportMemo.shared === reportMemo)
                    #expect(CostUsageClaudeFragments.shared === fragments)
                    try await CostUsageClaudeCacheIO.withIsolatedCachesForTesting {
                        #expect(CostUsageClaudeReportMemo.shared !== reportMemo)
                        #expect(CostUsageClaudeFragments.shared !== fragments)
                        // Exceed every memo's capacity before resuming the parent's warm-cache assertions.
                        var competing: [Fixture] = []
                        defer { competing.forEach { $0.env.cleanup() } }
                        for _ in 0..<9 {
                            let other = try Fixture(rowCount: 2)
                            competing.append(other)
                            _ = try other.load(context: .regular)
                        }
                    }
                }
            }
            try await group.waitForAll()
        }

        #expect(CostUsageClaudeReportMemo.shared === reportMemo)
        #expect(CostUsageClaudeFragments.shared === fragments)
        let warm = CostUsageScanner.ClaudeScanWorkRecorder()
        try CostUsageScanner.withClaudeScanWorkRecorderForTesting(warm) {
            #expect(try fixture.load(context: .regular).data == initial.data)
            let loaded = CostUsageClaudeCacheIO.load(provider: .claude, cacheRoot: fixture.env.cacheRoot)
            #expect(loaded.usage == cache.usage)
            _ = try CostUsageClaudeCacheIO.save(provider: .claude, cache: cache, cacheRoot: fixture.env.cacheRoot)
        }
        #expect(warm.snapshot() == CostUsageScanner.ClaudeScanWorkMetrics())
        #expect(warm.persistenceSnapshot().reads == 0)
        #expect(warm.persistenceSnapshot().writes == 0)
        #expect(try fixture.stamps(context: .regular) == before)

        // Changing only the header must encode the artifact while reusing every file fragment.
        var changed = cache
        changed.usage.lastScanUnixMs += 1
        let encoded = CostUsageScanner.ClaudeScanWorkRecorder()
        try CostUsageScanner.withClaudeScanWorkRecorderForTesting(encoded) {
            _ = try CostUsageClaudeCacheIO.save(provider: .claude, cache: changed, cacheRoot: fixture.env.cacheRoot)
        }
        #expect(encoded.snapshot().cacheEncodes == 1)
        #expect(encoded.snapshot().fragmentEncodes == 0)
        #expect(encoded.snapshot().fragmentFallbacks == 0)
        #expect(encoded.persistenceSnapshot().writes == 1)
    }
}
