import Foundation
import Testing
@testable import CodexBarCore

extension CodexArchivedRolloutMirrorTests {
    @Test
    func `forks in the window decode their archived parent from before the window`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let parentDay = try env.makeLocalNoon(year: 2026, month: 8, day: 1)
        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 17)
        let parentId = Self.uuid(10)
        let childId = Self.uuid(11)
        try Self.writeArchive(
            env: env,
            day: parentDay,
            name: "rollout-2026-08-01T12-00-00-\(parentId).jsonl",
            contents: Data(Self.forkParentRollout(env: env, id: parentId, at: parentDay).utf8),
            modified: parentDay)
        _ = try env.writeCodexSessionFile(
            day: day,
            filename: "rollout-2026-09-17T12-00-00-\(childId).jsonl",
            contents: Self.forkChildRollout(env: env, id: childId, parent: parentId, at: day))
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"))
        options.refreshMinIntervalSeconds = 0

        var total: Int?
        for _ in 0..<4 {
            total = CostUsageScanner.loadDailyReport(
                provider: .codex,
                since: day,
                until: day,
                now: day,
                options: options)
                .summary?.totalTokens
        }

        // Only the child's own 20 tokens fall in the window; the parent's 1000 are inherited, not billed again.
        #expect(total == 20)
        let cache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        let child = try #require(cache.files.values.first { $0.sessionId == childId })
        #expect(!CostUsageScanner.isUnresolvedMissingParentFork(child))
        #expect(cache.codexScanCatchUpPending == false)
    }

    @Test
    func `a fork resolves a parent archived after its plain rollout was cached`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let parentDay = try env.makeLocalNoon(year: 2026, month: 8, day: 1)
        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 17)
        let parentId = Self.uuid(20)
        let childId = Self.uuid(21)
        let parentName = "rollout-2026-08-01T12-00-00-\(parentId).jsonl"
        let parentContents = Self.forkParentRollout(env: env, id: parentId, at: parentDay)
        // An unrelated archive keeps the mirror root in place, so archiving the parent changes no root.
        try Self.writeArchive(
            env: env,
            day: parentDay,
            name: "rollout-2026-08-01T10-00-00-\(Self.uuid(22)).jsonl",
            contents: Data(Self.rollout(stamp: env.isoString(for: parentDay)).utf8),
            modified: parentDay)
        _ = try env.writeCodexSessionFile(day: parentDay, filename: parentName, contents: parentContents)
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"))
        options.refreshMinIntervalSeconds = 0
        func refresh(on date: Date) -> Int? {
            CostUsageScanner.loadDailyReport(provider: .codex, since: date, until: date, now: date, options: options)
                .summary?.totalTokens
        }
        for _ in 0..<3 {
            _ = refresh(on: parentDay)
        }
        #expect(CostUsageStoreAccess.read(cacheRoot: env.cacheRoot).files.values.contains { $0.sessionId == parentId })

        // Codex archives the parent; a fork of it is scanned later, with the parent outside the window.
        try Self.writeArchive(
            env: env,
            day: parentDay,
            name: parentName,
            contents: Data(parentContents.utf8),
            modified: parentDay)
        _ = try env.writeCodexSessionFile(
            day: day,
            filename: "rollout-2026-09-17T12-00-00-\(childId).jsonl",
            contents: Self.forkChildRollout(env: env, id: childId, parent: parentId, at: day))
        var total: Int?
        for _ in 0..<4 {
            total = refresh(on: day)
        }

        #expect(total == 20)
        let child = try #require(CostUsageStoreAccess.read(cacheRoot: env.cacheRoot).files.values.first {
            $0.sessionId == childId
        })
        #expect(!CostUsageScanner.isUnresolvedMissingParentFork(child))
    }

    private static func forkMetadata(
        env: CostUsageTestEnvironment,
        id: String,
        parent: String?,
        at date: Date) -> String
    {
        let fork = parent.map { #","forked_from_id":"\#($0)""# } ?? ""
        return #"{"type":"session_meta","payload":{"id":"\#(id)","source":"vscode","#
            + #""thread_source":"user","timestamp":"\#(env.isoString(for: date))"\#(fork)}}"#
    }

    private static func forkTokens(env: CostUsageTestEnvironment, _ input: Int, last: Int, at date: Date) -> String {
        #"{"type":"event_msg","timestamp":"\#(env.isoString(for: date))","payload":{"type":"token_count","#
            + #""info":{"model":"gpt-5.4","total_token_usage":{"input_tokens":\#(input),"output_tokens":0},"#
            + #""last_token_usage":{"input_tokens":\#(last),"output_tokens":0}}}}"#
    }

    /// A parent session that used 1,000 tokens.
    private static func forkParentRollout(env: CostUsageTestEnvironment, id: String, at date: Date) -> String {
        [
            self.forkMetadata(env: env, id: id, parent: nil, at: date),
            self.forkTokens(env: env, 1000, last: 1000, at: date),
        ].joined(separator: "\n") + "\n"
    }

    /// A fork that inherits its parent's 1,000 tokens and adds 20 of its own.
    private static func forkChildRollout(env: CostUsageTestEnvironment, id: String, parent: String, at date: Date)
        -> String
    {
        [
            self.forkMetadata(env: env, id: id, parent: parent, at: date),
            self.forkTokens(env: env, 1000, last: 1000, at: date.addingTimeInterval(1)),
            self.forkTokens(env: env, 1020, last: 20, at: date.addingTimeInterval(2)),
        ].joined(separator: "\n") + "\n"
    }
}
