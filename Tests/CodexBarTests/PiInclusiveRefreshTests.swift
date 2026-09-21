import Foundation
import Testing
@testable import CodexBarCore

struct PiInclusiveRefreshTests {
    @Test(arguments: [UsageProvider.codex, .claude, .pi])
    func `forced refresh reparses Pi history with unchanged file metadata`(provider: UsageProvider) async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 9)
        var nativeOptions = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot)
        nativeOptions.refreshMinIntervalSeconds = 0
        let piOptions = PiSessionCostScanner.Options(
            piSessionsRoot: env.piSessionsRoot,
            cacheRoot: env.cacheRoot,
            refreshMinIntervalSeconds: 0,
            environment: ["HOME": env.root.path])
        func contents(input: Int) throws -> String {
            try env.jsonl([["type": "message", "id": "turn", "timestamp": env.isoString(for: day), "message": [
                "role": "assistant",
                "provider": provider == .claude ? "anthropic" : "openai-codex",
                "model": provider == .claude ? "claude-sonnet-4-6" : "openai/gpt-5.4",
                "usage": ["input": input, "output": 5, "totalTokens": input + 5],
            ]]])
        }
        func refresh(force: Bool) async throws -> CostUsageTokenSnapshot {
            try await CostUsageFetcher.loadTokenSnapshot(
                provider: provider,
                environment: ["HOME": env.root.path],
                now: day,
                forceRefresh: force,
                historyDays: 1,
                allowPricingRefresh: false,
                includePiSessions: true,
                scannerOptions: nativeOptions,
                piScannerOptions: piOptions)
        }
        let original = try contents(input: 10)
        let replacement = try contents(input: 20)
        #expect(original.utf8.count == replacement.utf8.count)
        let file = try env.writePiSessionFile(relativePath: "same-metadata.jsonl", contents: original)
        try FileManager.default.setAttributes([.modificationDate: day], ofItemAtPath: file.path)
        let initial = try await refresh(force: false)
        #expect(initial.last30DaysTokens == 15)
        #expect(initial.historyCoverageIsEstablished)

        // Overwrite the same inode; an ordinary metadata check cannot detect this edit.
        let handle = try FileHandle(forWritingTo: file)
        try handle.write(contentsOf: Data(replacement.utf8))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: day], ofItemAtPath: file.path)
        #expect(try await refresh(force: false).last30DaysTokens == 15)

        let forced = try await refresh(force: true)
        #expect(forced.last30DaysTokens == 25)
        #expect(forced.historyCoverageIsEstablished)
    }
}
