import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized, CostUsageClaudeCacheFixtures())
struct CostUsageClaudeBlockTests {
    @Test
    func `billable updates retain exact reports through eviction and a full replay`() throws {
        let fixture = try CostUsageClaudeWriteAmplificationTests.Fixture(rowCount: 1800, identityLength: 48)
        defer { fixture.env.cleanup() }
        let source = fixture.env.claudeProjectsRoot.appendingPathComponent("session.jsonl")
        func report(force: Bool = false) throws -> ClaudeReportProjections {
            var options = CostUsageScanner.Options(
                claudeProjectsRoots: [fixture.env.claudeProjectsRoot], cacheRoot: fixture.env.cacheRoot)
            options.refreshMinIntervalSeconds = 0
            options.forceRescan = force
            return try CostUsageScanner.loadClaudeReportProjectionsCancellable(
                since: fixture.day,
                until: fixture.day,
                now: fixture.day,
                options: options,
                reportContext: .regular,
                checkCancellation: nil)
        }
        _ = try report()
        let writer = try FileHandle(forWritingTo: source)
        defer { try? writer.close() }
        try writer.seekToEnd()
        try writer.write(contentsOf: Data(fixture.event(index: 1800).utf8))
        let result = try report()
        #expect(result.daily.summary?.totalInputTokens == 18010)
        #expect((result.daily.summary?.totalCostUSD ?? 0) > 0)
        try CostUsageClaudeReportMemo.$shared.withValue(CostUsageClaudeReportMemo()) {
            try CostUsageClaudeFragments.$shared.withValue(CostUsageClaudeFragments()) {
                let cold = try report()
                let saved = CostUsageClaudeCacheIO.load(provider: .claude, cacheRoot: fixture.env.cacheRoot)
                #expect(saved.usage.files.values.first?.claudeRows?.count == 1801)
                let replay = try report(force: true)
                for observed in [cold, replay] {
                    #expect(observed.daily.data == result.daily.data)
                    #expect(observed.daily.summary == result.daily.summary)
                    #expect(observed.daily.hourly == result.daily.hourly)
                    #expect(observed.daily.quotaSlices == result.daily.quotaSlices)
                    #expect(observed.projects == result.projects)
                    #expect(observed.sessions == result.sessions)
                }
            }
        }
    }

    @Test
    func `large payloads publish atomically and cold readers verify every block`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let url = env.root.appendingPathComponent("manifest")
        let directory = url.appendingPathExtension("fragments")
        // Vary the byte stream so a middle insertion moves ordinary fixed-offset block boundaries.
        let header = (0..<30000).map { "session-\($0)-event-\($0 * 53)" }.joined(separator: ",")
        var changed = header
        changed.insert(contentsOf: "-new-usage-", at: changed.index(changed.startIndex, offsetBy: header.count / 2))
        let store = CostUsageClaudeFragments()
        let files = ["synthetic": header]
        _ = try store.save(header: header, values: files, at: url)
        func blocks() throws -> Set<String> {
            try Set(FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".block") })
        }
        func coldLoad() throws -> (String, [String: String]) {
            try CostUsageClaudeFragments().load(at: url) { _ in throw CocoaError(.fileReadCorruptFile) }
        }
        let original = try blocks()
        #expect(original.count > 5)
        let interrupt: @Sendable () throws -> Void = { throw CancellationError() }
        #expect(throws: CancellationError.self) {
            try CostUsageClaudeFragments.$beforeManifestForTesting.withValue(interrupt) {
                _ = try store.save(header: changed, values: ["synthetic": changed], at: url)
            }
        }
        let afterInterruption = try coldLoad()
        #expect(afterInterruption.0 == header)
        #expect(afterInterruption.1 == files)
        _ = try store.save(header: changed, values: ["synthetic": changed], at: url)
        let restored = try coldLoad()
        #expect(restored.0 == changed)
        #expect(restored.1["synthetic"] == changed)
        let current = try blocks()
        #expect(original.intersection(current).count > original.count / 2)
        let member = try directory.appendingPathComponent(#require(current.first))
        var damaged = try Data(contentsOf: member)
        damaged[0] ^= 1
        try damaged.write(to: member, options: .atomic)
        #expect(throws: (any Error).self) { try coldLoad() }
        _ = try store.save(header: "small", values: ["synthetic": "small"], at: url)
        #expect(try blocks().isEmpty)
        #expect(try coldLoad().0 == "small")
    }
}
